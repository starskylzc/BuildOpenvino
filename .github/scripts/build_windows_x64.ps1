# .github/scripts/build_windows_x64.ps1
#requires -Version 7.0
param(
  [string]$OpenCvVersion  = $env:OPENCV_VERSION,
  [string]$OpenCvSharpRef = $env:OPENCVSHARP_REF,
  [string]$BuildList      = $env:BUILD_LIST
)

$ErrorActionPreference = "Stop"

function Info($msg) { Write-Host "==> $msg" }

if ([string]::IsNullOrWhiteSpace($OpenCvVersion))  { $OpenCvVersion  = "4.11.0" }
if ([string]::IsNullOrWhiteSpace($OpenCvSharpRef)) { $OpenCvSharpRef = "main" }
if ([string]::IsNullOrWhiteSpace($BuildList))      { $BuildList      = "core,imgproc,videoio" }

$Workspace = ($env:GITHUB_WORKSPACE ?? (Get-Location).Path)

$Root = Join-Path $Workspace "_work"
$Src  = Join-Path $Root "src"
$B    = Join-Path $Root "build-win-x64"
$Out  = Join-Path $Root "out-win-x64"

New-Item -ItemType Directory -Force -Path $Src,$B,$Out | Out-Null

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

Info "OpenCvSharp commit/tag"
git -C $SharpSrc rev-parse HEAD
git -C $SharpSrc describe --tags --always

# ------------------------------------------------------------
# Patch OpenCvSharpExtern to build only: core.cpp,imgproc.cpp,videoio.cpp
# ------------------------------------------------------------
Info "Patch OpenCvSharpExtern CMakeLists to minimal sources (core/imgproc/videoio)"
$pyPatchExtern = @"
import pathlib, re, os, sys

root = pathlib.Path(os.environ["GITHUB_WORKSPACE"]) / "_work"
sharp = root / "src" / "opencvsharp"
cmake = sharp / "src" / "OpenCvSharpExtern" / "CMakeLists.txt"

text = cmake.read_text(encoding="utf-8", errors="ignore")

pattern = re.compile(r"add_library\\s*\\(\\s*OpenCvSharpExtern\\s+SHARED\\s+.*?\\)\\s*", re.S)
m = pattern.search(text)
if not m:
    raise SystemExit("Cannot find add_library(OpenCvSharpExtern SHARED ...) in OpenCvSharpExtern/CMakeLists.txt")

minimal = \"\"\"add_library(OpenCvSharpExtern SHARED
    core.cpp
    imgproc.cpp
    videoio.cpp
)

\"\"\"
text2 = text[:m.start()] + minimal + text[m.end():]
cmake.write_text(text2, encoding="utf-8")
print("Patched:", cmake)
"@
python -c $pyPatchExtern

# ------------------------------------------------------------
# Build OpenCV static (minimal modules)
# ------------------------------------------------------------
$OpenCvB = Join-Path $B "opencv"
New-Item -ItemType Directory -Force -Path $OpenCvB | Out-Null

Info "Build OpenCV static (win-x64)"
cmake -S $OpenCvSrc -B $OpenCvB -G Ninja `
  -D CMAKE_BUILD_TYPE=Release `
  -D OPENCV_EXTRA_MODULES_PATH="$Contrib\modules" `
  -D BUILD_SHARED_LIBS=OFF `
  -D BUILD_LIST="$BuildList" `
  -D BUILD_TESTS=OFF -D BUILD_PERF_TESTS=OFF -D BUILD_EXAMPLES=OFF -D BUILD_DOCS=OFF -D BUILD_opencv_apps=OFF `
  -D OPENCV_FORCE_3RDPARTY_BUILD=ON `
  `
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

cmake --build $OpenCvB --config Release

# ------------------------------------------------------------
# Ensure generated headers are in <build>/include/opencv2/
# ------------------------------------------------------------
Info "Ensure generated OpenCV headers are under $OpenCvB/include/opencv2"
$dstDir = Join-Path $OpenCvB "include\opencv2"
New-Item -ItemType Directory -Force -Path $dstDir | Out-Null

$genModules = Join-Path $OpenCvB "opencv2\opencv_modules.hpp"
$genCvConfig = Join-Path $OpenCvB "cvconfig.h"

if (Test-Path $genModules) {
  Copy-Item -Force $genModules (Join-Path $dstDir "opencv_modules.hpp")
  Info "Copied generated header: $genModules -> $(Join-Path $dstDir 'opencv_modules.hpp')"
}
if (Test-Path $genCvConfig) {
  Copy-Item -Force $genCvConfig (Join-Path $dstDir "cvconfig.h")
  Info "Copied generated header: $genCvConfig -> $(Join-Path $dstDir 'cvconfig.h')"
}

# ------------------------------------------------------------
# Auto-filter include_opencv.h based on actual include roots
# (same idea as your mac script)
# ------------------------------------------------------------
Info "Auto-filter include_opencv.h based on compile include roots"
$env:BUILD_LIST = $BuildList

$pyFilter = @"
import pathlib, re, os

root = pathlib.Path(os.environ["GITHUB_WORKSPACE"]) / "_work"
opencv_src = root / "src" / "opencv"
opencv_build = root / "build-win-x64" / "opencv"

opencv_include = opencv_src / "include"
modules_root = opencv_src / "modules"
build_include = opencv_build / "include"

build_list = [x.strip() for x in os.environ.get("BUILD_LIST","core,imgproc,videoio").split(",") if x.strip()]

include_roots = [opencv_include]
for m in build_list:
    p = modules_root / m / "include"
    if p.exists():
        include_roots.append(p)

if build_include.exists():
    include_roots.append(build_include)

hdr = root / "src" / "opencvsharp" / "src" / "OpenCvSharpExtern" / "include_opencv.h"
lines = hdr.read_text(encoding="utf-8", errors="ignore").splitlines()

pat = re.compile(r'^\\s*#\\s*include\\s*<([^>]+)>\\s*$')

def visible(rel: str) -> bool:
    for r in include_roots:
        if (r / rel).exists():
            return True
    return False

out = []
disabled = 0
for line in lines:
    m = pat.match(line)
    if not m:
        out.append(line)
        continue
    inc = m.group(1).strip()
    if inc.startswith("opencv2/") and not visible(inc):
        out.append("// [auto-disabled not in include roots] " + line)
        disabled += 1
    else:
        out.append(line)

hdr.write_text("\\n".join(out) + "\\n", encoding="utf-8")
print(f"include_opencv.h filtered: disabled {disabled} includes")
print("Include roots:")
for r in include_roots:
    print("  -", r)
"@
python -c $pyFilter

# ------------------------------------------------------------
# Build OpenCvSharpExtern via opencvsharp/src (same as mac)
# ------------------------------------------------------------
Info "Build OpenCvSharpExtern (win-x64)"
$SharpBuild = Join-Path $B "opencvsharp"

cmake -S (Join-Path $SharpSrc "src") -B $SharpBuild -G Ninja `
  -D CMAKE_BUILD_TYPE=Release `
  -D CMAKE_INSTALL_PREFIX="$Out" `
  -D CMAKE_POLICY_VERSION_MINIMUM=3.5 `
  -D OpenCV_DIR="$OpenCvB"

cmake --build $SharpBuild --config Release
cmake --build $SharpBuild --config Release --target install

# ------------------------------------------------------------
# Collect artifact
# ------------------------------------------------------------
Info "Collect artifact"
$dll = Get-ChildItem -Path $Out -Recurse -Filter "OpenCvSharpExtern.dll" | Select-Object -First 1
if (-not $dll) {
  Info "Out tree listing (top 3 levels):"
  Get-ChildItem -Path $Out -Recurse -Depth 3 | Select-Object FullName | Out-Host
  throw "OpenCvSharpExtern.dll not found under $Out"
}

$final = Join-Path $Out "final"
New-Item -ItemType Directory -Force -Path $final | Out-Null
Copy-Item -Force $dll.FullName (Join-Path $final "OpenCvSharpExtern.dll")

Info "Done: $final\OpenCvSharpExtern.dll"
