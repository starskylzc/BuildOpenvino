# .github/scripts/build_windows_x64.ps1
#requires -Version 7.0
param(
  [string]$OpenCvVersion   = $env:OPENCV_VERSION,
  [string]$OpenCvSharpRef  = $env:OPENCVSHARP_REF,
  [string]$BuildList       = $env:BUILD_LIST
)

$ErrorActionPreference = "Stop"

function Info($msg) { Write-Host "==> $msg" }

if ([string]::IsNullOrWhiteSpace($OpenCvVersion))  { $OpenCvVersion  = "4.11.0" }
if ([string]::IsNullOrWhiteSpace($OpenCvSharpRef)) { $OpenCvSharpRef = "main" }
if ([string]::IsNullOrWhiteSpace($BuildList))      { $BuildList      = "core,imgproc,videoio" }

$Workspace = ($env:GITHUB_WORKSPACE ?? (Get-Location).Path)

$Root = Join-Path $Workspace "_work"
$Src  = Join-Path $Root "src"
$Bld  = Join-Path $Root "build-win-x64"
$Out  = Join-Path $Root "out-win-x64"

New-Item -ItemType Directory -Force -Path $Src,$Bld,$Out | Out-Null

Info "Tool versions"
cmake --version
git --version
python --version

function Clone-Or-Update([string]$Url, [string]$Dir, [string]$Ref) {
  if (!(Test-Path (Join-Path $Dir ".git"))) {
    git clone --depth 1 $Url $Dir
  }
  git -C $Dir fetch --all --tags --prune
  git -C $Dir checkout $Ref
}

Info "Fetch sources"
$OpenCvSrc = Join-Path $Src "opencv"
$Contrib   = Join-Path $Src "opencv_contrib"
$SharpSrc  = Join-Path $Src "opencvsharp"

Clone-Or-Update "https://github.com/opencv/opencv.git"         $OpenCvSrc $OpenCvVersion
Clone-Or-Update "https://github.com/opencv/opencv_contrib.git" $Contrib   $OpenCvVersion
Clone-Or-Update "https://github.com/shimat/opencvsharp.git"    $SharpSrc  $OpenCvSharpRef

# -----------------------------
# 1) Build OpenCV (STATIC, minimal modules, minimal external deps)
# -----------------------------
$OpenCvB = Join-Path $Bld "opencv"

Info "Configure OpenCV (STATIC, minimal, minimal external deps)"
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

Info "Build OpenCV"
cmake --build $OpenCvB --config Release

# -----------------------------
# 2) Auto-filter include_opencv.h (optional but recommended)
#    Only keep includes that exist in:
#      opencv/include + modules/<build_list>/include
# -----------------------------
Info "Auto-filter include_opencv.h based on existing OpenCV headers"
$env:BUILD_LIST = $BuildList

$pyFilter = @"
import pathlib, re, os

root = pathlib.Path(os.environ["GITHUB_WORKSPACE"]) / "_work"
opencv_root = root / "src" / "opencv"
opencv_include = opencv_root / "include"
modules_root = opencv_root / "modules"

build_list = [x.strip() for x in os.environ.get("BUILD_LIST","core,imgproc,videoio").split(",") if x.strip()]
include_roots = [opencv_include]
for m in build_list:
    p = modules_root / m / "include"
    if p.exists():
        include_roots.append(p)

hdr = root / "src" / "opencvsharp" / "src" / "OpenCvSharpExtern" / "include_opencv.h"
text = hdr.read_text(encoding="utf-8", errors="ignore").splitlines()

pat = re.compile(r'^\s*#\s*include\s*<([^>]+)>\s*$')

def exists(rel: str) -> bool:
    for r in include_roots:
        if (r / rel).exists():
            return True
    return False

out = []
disabled = 0
for line in text:
    m = pat.match(line)
    if not m:
        out.append(line)
        continue
    inc = m.group(1).strip()
    if inc.startswith("opencv2/") and not exists(inc):
        out.append("// [auto-disabled missing header] " + line)
        disabled += 1
    else:
        out.append(line)

hdr.write_text("\n".join(out) + "\n", encoding="utf-8")
print(f"Filtered include_opencv.h: disabled {disabled} missing includes")
"@

python -c $pyFilter

# -----------------------------
# 3) Build OpenCvSharpExtern.dll WITHOUT parsing opencvsharp CMakeLists
#    We create a minimal CMake project ourselves.
# -----------------------------
Info "Generate minimal CMake project for OpenCvSharpExtern (bypass upstream CMakeLists)"
$ExternSrc = Join-Path $SharpSrc "src\OpenCvSharpExtern"
$MinProj   = Join-Path $Bld "opencvsharp_minproj"
New-Item -ItemType Directory -Force -Path $MinProj | Out-Null

# Minimal sources strictly matching your need
$CoreCpp    = Join-Path $ExternSrc "core.cpp"
$ImgProcCpp = Join-Path $ExternSrc "imgproc.cpp"
$VideoIoCpp = Join-Path $ExternSrc "videoio.cpp"

foreach ($f in @($CoreCpp,$ImgProcCpp,$VideoIoCpp)) {
  if (!(Test-Path $f)) { throw "Missing expected source: $f" }
}

$CMakeLists = @"
cmake_minimum_required(VERSION 3.18)
project(OpenCvSharpExternMin LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Point this to OpenCV build tree
# (OpenCVConfig.cmake exists there after configure)
set(OpenCV_DIR "${OpenCvB}")

find_package(OpenCV REQUIRED)

add_library(OpenCvSharpExtern SHARED
  "${CoreCpp}"
  "${ImgProcCpp}"
  "${VideoIoCpp}"
)

target_include_directories(OpenCvSharpExtern PRIVATE
  "${ExternSrc}"
  "${ExternSrc}\..\OpenCvSharpExtern"
  "${ExternSrc}\include"
  "${ExternSrc}\.."
  ${OpenCV_INCLUDE_DIRS}
)

# OpenCvSharpExtern code expects this export define
target_compile_definitions(OpenCvSharpExtern PRIVATE OpenCvSharpExtern_EXPORTS)

target_link_libraries(OpenCvSharpExtern PRIVATE ${OpenCV_LIBS})

# Make output name match expected "OpenCvSharpExtern.dll"
set_target_properties(OpenCvSharpExtern PROPERTIES
  OUTPUT_NAME "OpenCvSharpExtern"
)
"@

Set-Content -Path (Join-Path $MinProj "CMakeLists.txt") -Value $CMakeLists -Encoding UTF8

Info "Configure OpenCvSharpExtern (win-x64, minimal project)"
$MinBuild = Join-Path $Bld "opencvsharp_minbuild"
New-Item -ItemType Directory -Force -Path $MinBuild | Out-Null

cmake -S $MinProj -B $MinBuild -G Ninja `
  -D CMAKE_BUILD_TYPE=Release

Info "Build OpenCvSharpExtern"
cmake --build $MinBuild --config Release

# -----------------------------
# 4) Collect artifact
# -----------------------------
Info "Collect artifact"
$dll = Get-ChildItem -Path $MinBuild -Recurse -Filter "OpenCvSharpExtern.dll" | Select-Object -First 1
if (-not $dll) { throw "OpenCvSharpExtern.dll not found under $MinBuild" }

$final = Join-Path $Out "final"
New-Item -ItemType Directory -Force -Path $final | Out-Null
Copy-Item -Force $dll.FullName (Join-Path $final "OpenCvSharpExtern.dll")

Info "Done: $final\OpenCvSharpExtern.dll"
