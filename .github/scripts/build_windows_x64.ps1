# .github/scripts/build_windows_x64.ps1
#requires -Version 7.0
param(
  [string]$OpenCvVersion   = $env:OPENCV_VERSION,
  [string]$OpenCvSharpRef  = $env:OPENCVSHARP_REF,
  [string]$BuildList       = $env:BUILD_LIST
)

$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host "==> $msg" }

if ([string]::IsNullOrWhiteSpace($OpenCvVersion))  { $OpenCvVersion  = "4.11.0" }
if ([string]::IsNullOrWhiteSpace($OpenCvSharpRef)) { $OpenCvSharpRef = "main" }
if ([string]::IsNullOrWhiteSpace($BuildList))      { $BuildList      = "core,imgproc,videoio" }

$Workspace = ($env:GITHUB_WORKSPACE ?? (Get-Location).Path)

$Root = Join-Path $Workspace "_work"
$Src  = Join-Path $Root "src"
$Bld  = Join-Path $Root "build-win-x64"
$Out  = Join-Path $Root "out-win-x64"

New-Item -ItemType Directory -Force -Path $Src,$Bld,$Out | Out-Null

Write-Info "Tool versions"
cmake --version
python --version
git --version

function Clone-Or-Update([string]$Url, [string]$Dir, [string]$Ref) {
  if (!(Test-Path (Join-Path $Dir ".git"))) {
    git clone --depth 1 $Url $Dir
  }
  git -C $Dir fetch --all --tags --prune
  git -C $Dir checkout $Ref
}

Write-Info "Fetch sources"
Clone-Or-Update "https://github.com/opencv/opencv.git"         (Join-Path $Src "opencv")         $OpenCvVersion
Clone-Or-Update "https://github.com/opencv/opencv_contrib.git" (Join-Path $Src "opencv_contrib") $OpenCvVersion
Clone-Or-Update "https://github.com/shimat/opencvsharp.git"    (Join-Path $Src "opencvsharp")    $OpenCvSharpRef

# ------------------------------------------------------------
# Patch OpenCvSharpExtern:
#  1) Inject SAFE ocv_* shims (no guessing, handles empty args & missing scope)
#  2) Reduce sources to core/imgproc/videoio
# ------------------------------------------------------------
Write-Info "Patch OpenCvSharpExtern CMakeLists (SAFE ocv_* shim + minimal sources)"
$pyPatchCMake = @"
import pathlib, re, os

root = pathlib.Path(os.environ["GITHUB_WORKSPACE"]) / "_work"
src  = root / "src" / "opencvsharp"
cmake = src / "src" / "OpenCvSharpExtern" / "CMakeLists.txt"
text = cmake.read_text(encoding="utf-8", errors="ignore")

# ---- (A) SAFE shim for ocv_* helpers (robust, no-guess) ----
shim = r'''
# ------------------------------------------------------------
# [Injected by CI] OpenCV CMake macro shims (SAFE)
# Purpose:
#   OpenCvSharpExtern's CMake may call ocv_* helpers that exist only when building
#   inside OpenCV superbuild. When building standalone (find_package OpenCV),
#   those commands may be missing.
# Design:
#   - tolerate empty argument lists (no-op)
#   - tolerate missing PUBLIC/PRIVATE/INTERFACE keyword (default PRIVATE)
#   - map to standard target_* commands
# ------------------------------------------------------------

function(_ocv_safe_target_call _cmd _target)
  set(_args ${ARGN})
  if(NOT _args)
    return()
  endif()

  list(GET _args 0 _first)
  if(_first STREQUAL "PUBLIC" OR _first STREQUAL "PRIVATE" OR _first STREQUAL "INTERFACE")
    cmake_language(CALL ${_cmd} ${_target} ${_args})
  else()
    cmake_language(CALL ${_cmd} ${_target} PRIVATE ${_args})
  endif()
endfunction()

if(NOT COMMAND ocv_target_compile_definitions)
  function(ocv_target_compile_definitions target)
    _ocv_safe_target_call(target_compile_definitions ${target} ${ARGN})
  endfunction()
endif()

if(NOT COMMAND ocv_target_compile_options)
  function(ocv_target_compile_options target)
    _ocv_safe_target_call(target_compile_options ${target} ${ARGN})
  endfunction()
endif()

if(NOT COMMAND ocv_target_include_directories)
  function(ocv_target_include_directories target)
    _ocv_safe_target_call(target_include_directories ${target} ${ARGN})
  endfunction()
endif()

if(NOT COMMAND ocv_target_link_libraries)
  function(ocv_target_link_libraries target)
    _ocv_safe_target_call(target_link_libraries ${target} ${ARGN})
  endfunction()
endif()

if(NOT COMMAND ocv_add_dependencies)
  function(ocv_add_dependencies target)
    if(ARGN)
      add_dependencies(${target} ${ARGN})
    endif()
  endfunction()
endif()

# Rare helpers - keep config robust (no-op)
if(NOT COMMAND ocv_warnings_disable)
  function(ocv_warnings_disable) endfunction()
endif()
if(NOT COMMAND ocv_append_source_file_compile_definitions)
  function(ocv_append_source_file_compile_definitions) endfunction()
endif()
# ------------------------------------------------------------
'''

if "OpenCV CMake macro shims (SAFE)" not in text:
    # insert after project(...) if present; else after cmake_minimum_required(...)
    mproj = re.search(r"^\s*project\s*\(.*?\)\s*$", text, flags=re.M)
    if mproj:
        pos = mproj.end()
        text = text[:pos] + "\n" + shim + "\n" + text[pos:]
    else:
        mcm = re.search(r"^\s*cmake_minimum_required\s*\(.*?\)\s*$", text, flags=re.M)
        if mcm:
            pos = mcm.end()
            text = text[:pos] + "\n" + shim + "\n" + text[pos:]
        else:
            text = shim + "\n" + text

# ---- (B) Minimal sources: core/imgproc/videoio ----
pattern = re.compile(r"add_library\s*\(\s*OpenCvSharpExtern\s+SHARED\s+.*?\)\s*", re.S)
m = pattern.search(text)
if not m:
    raise SystemExit("Cannot find add_library(OpenCvSharpExtern SHARED ...) in OpenCvSharpExtern/CMakeLists.txt")

minimal = """add_library(OpenCvSharpExtern SHARED
    core.cpp
    imgproc.cpp
    videoio.cpp
)

"""
text = text[:m.start()] + minimal + text[m.end():]

cmake.write_text(text, encoding="utf-8")
print("Patched:", cmake)
"@
python -c $pyPatchCMake

# ------------------------------------------------------------
# Build OpenCV static (minimal modules, minimize deps)
# ------------------------------------------------------------
$OpenCvSrc = Join-Path $Src "opencv"
$Contrib   = Join-Path $Src "opencv_contrib"
$OpenCvB   = Join-Path $Bld "opencv"

Write-Info "Configure OpenCV (STATIC, minimal, no external deps)"
cmake -S $OpenCvSrc -B $OpenCvB -G Ninja `
  -D CMAKE_BUILD_TYPE=Release `
  -D OPENCV_EXTRA_MODULES_PATH="$Contrib\modules" `
  -D BUILD_SHARED_LIBS=OFF `
  -D BUILD_LIST="$BuildList" `
  -D BUILD_TESTS=OFF -D BUILD_PERF_TESTS=OFF -D BUILD_EXAMPLES=OFF -D BUILD_DOCS=OFF -D BUILD_opencv_apps=OFF `
  -D OPENCV_FORCE_3RDPARTY_BUILD=ON `
  -D WITH_FFMPEG=OFF `
  -D WITH_GSTREAMER=OFF `
  -D WITH_OPENCL=OFF `
  -D WITH_TBB=OFF `
  -D WITH_IPP=OFF `
  -D WITH_OPENMP=OFF `
  -D WITH_HDF5=OFF `
  -D WITH_FREETYPE=OFF `
  -D WITH_HARFBUZZ=OFF `
  -D WITH_WEBP=OFF `
  -D WITH_OPENJPEG=OFF `
  -D WITH_JASPER=OFF `
  -D WITH_GPHOTO2=OFF `
  -D WITH_1394=OFF `
  -D VIDEOIO_ENABLE_PLUGINS=OFF `
  -D WITH_MSMF=ON `
  -D WITH_DSHOW=ON

Write-Info "Build OpenCV"
cmake --build $OpenCvB --config Release

# ------------------------------------------------------------
# Auto-filter include_opencv.h based on actual include roots
# ------------------------------------------------------------
Write-Info "Auto-filter include_opencv.h based on compile include roots"
$env:BUILD_LIST = $BuildList
$pyFilter = @"
import pathlib, re, os

root = pathlib.Path(os.environ["GITHUB_WORKSPACE"]) / "_work"
opencv_root = root / "src" / "opencv"
opencv_include = opencv_root / "include"
modules_root = opencv_root / "modules"

build_list = os.environ.get("BUILD_LIST","core,imgproc,videoio").split(",")
module_includes = [modules_root / m / "include" for m in build_list if (modules_root / m / "include").exists()]
include_roots = [opencv_include] + module_includes

hdr = root / "src" / "opencvsharp" / "src" / "OpenCvSharpExtern" / "include_opencv.h"
lines = hdr.read_text(encoding="utf-8", errors="ignore").splitlines()

pat = re.compile(r'^\s*#\s*include\s*<([^>]+)>\s*$')

def visible_header_exists(rel: str) -> bool:
    for r in include_roots:
        if (r / rel).exists():
            return True
    return False

out = []
disabled = 0
for line in lines:
    m = pat.match(line)
    if not m:
        out.append(line); continue
    inc = m.group(1).strip()
    if inc.startswith("opencv2/") and not visible_header_exists(inc):
        out.append("// [auto-disabled not in include roots] " + line)
        disabled += 1
    else:
        out.append(line)

hdr.write_text("\n".join(out) + "\n", encoding="utf-8")
print(f"include_opencv.h filtered: disabled {disabled} includes")
"@
python -c $pyFilter

# ------------------------------------------------------------
# Build OpenCvSharpExtern (use OpenCV BUILD TREE)
# ------------------------------------------------------------
$SharpSrc = Join-Path $Src "opencvsharp"
$SharpB   = Join-Path $Bld "opencvsharp"

Write-Info "Configure OpenCvSharpExtern (win-x64)"
cmake -S (Join-Path $SharpSrc "src") -B $SharpB -G Ninja `
  -D CMAKE_BUILD_TYPE=Release `
  -D CMAKE_INSTALL_PREFIX="$Out" `
  -D OpenCV_DIR="$OpenCvB" `
  -D CMAKE_POLICY_VERSION_MINIMUM=3.5

Write-Info "Build & install OpenCvSharpExtern"
cmake --build $SharpB --config Release
cmake --install $SharpB --config Release

Write-Info "Collect artifact"
$dll = Get-ChildItem -Path $Out -Recurse -Filter "OpenCvSharpExtern.dll" | Select-Object -First 1
if (-not $dll) { throw "OpenCvSharpExtern.dll not found under $Out" }

$final = Join-Path $Out "final"
New-Item -ItemType Directory -Force -Path $final | Out-Null
Copy-Item -Force $dll.FullName (Join-Path $final "OpenCvSharpExtern.dll")

Write-Info "Done: $final\OpenCvSharpExtern.dll"
