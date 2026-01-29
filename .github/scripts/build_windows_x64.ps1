# .github/scripts/build_windows_x64.ps1
#requires -Version 7.0
param(
  [string]$OpenCvVersion   = $env:OPENCV_VERSION,
  [string]$OpenCvSharpRef  = $env:OPENCVSHARP_REF,
  [string]$BuildList       = $env:BUILD_LIST
)

$ErrorActionPreference = "Stop"

function Info($msg) { Write-Host "==> $msg" }

function To-CMakePath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $p }
  $full = [System.IO.Path]::GetFullPath($p)
  return ($full -replace '\\','/')
}

function Assert-Exists([string]$p, [string]$msg) {
  if (!(Test-Path $p)) { throw $msg }
}

function Ensure-GeneratedOpenCvHeader([string]$OpenCvBuildDir, [string]$HeaderName) {
  $dstDir = Join-Path $OpenCvBuildDir "include\opencv2"
  New-Item -ItemType Directory -Force -Path $dstDir | Out-Null

  $found = Get-ChildItem -Path $OpenCvBuildDir -Recurse -File -Filter $HeaderName -ErrorAction SilentlyContinue |
           Select-Object -First 1

  if ($null -eq $found) {
    Info "DEBUG: Could not find '$HeaderName' under $OpenCvBuildDir"
    Get-ChildItem -Path $OpenCvBuildDir -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match 'opencv_modules\.hpp|cvconfig\.h' } |
      Select-Object -First 50 FullName |
      ForEach-Object { Write-Host $_.FullName }
    throw "Generated header '$HeaderName' not found under OpenCV build tree: $OpenCvBuildDir"
  }

  $dst = Join-Path $dstDir $HeaderName
  Copy-Item -Force $found.FullName $dst
  Info "Copied generated header: $($found.FullName) -> $dst"
}

function Write-MinimalIncludeOpenCv([string]$HdrPath) {
  # Minimal include_opencv.h for BUILD_LIST=core,imgproc,videoio
  # - NO opencv2/opencv.hpp
  # - NO highgui/imgcodecs/shape/stitching/video/superres/dnn/etc
  # - Keep C-API headers used by some OpenCvSharpExtern code paths (safe)
  $content = @'
#pragma once

#ifndef CV_EXPORTS
# if (defined _WIN32 || defined WINCE || defined __CYGWIN__)
#   define CV_EXPORTS __declspec(dllexport)
# elif defined(__GNUC__) && __GNUC__ >= 4 && defined(__APPLE__)
#   define CV_EXPORTS __attribute__ ((visibility ("default")))
# endif
#endif
#ifndef CV_EXPORTS
# define CV_EXPORTS
#endif

#ifdef _MSC_VER
#define NOMINMAX
#define _CRT_SECURE_NO_WARNINGS
#pragma warning(push)
#pragma warning(disable: 4244)
#pragma warning(disable: 4251)
#pragma warning(disable: 4819)
#pragma warning(disable: 4996)
#pragma warning(disable: 6294)
#include <codeanalysis/warnings.h>
#pragma warning(disable: ALL_CODE_ANALYSIS_WARNINGS)
#endif

#define OPENCV_TRAITS_ENABLE_DEPRECATED

// ===== Minimal OpenCV includes (core + imgproc + videoio) =====
// IMPORTANT: DO NOT include <opencv2/opencv.hpp> because it drags in headers from
// modules we purposely did not build (imgcodecs/highgui/video/stitching/...).
#include <opencv2/core.hpp>
#include <opencv2/core/base.hpp>
#include <opencv2/core/mat.hpp>
#include <opencv2/core/types.hpp>
#include <opencv2/core/utility.hpp>

#include <opencv2/imgproc.hpp>
#include <opencv2/imgproc/types_c.h>
#include <opencv2/imgproc/imgproc_c.h>  // legacy C API (OpenCvSharpExtern uses some C-APIs)

#include <opencv2/videoio.hpp>

// Some OpenCvSharpExtern code uses core_c in older branches; harmless if present.
#include <opencv2/core/core_c.h>

// ===== STL =====
#include <vector>
#include <algorithm>
#include <iterator>
#include <sstream>
#include <fstream>
#include <iostream>
#include <cstdio>
#include <cstring>
#include <cstdlib>

#ifdef _MSC_VER
#pragma warning(pop)
#endif

// Additional types/functions used by OpenCvSharpExtern
#include "my_types.h"
#include "my_functions.h"
'@

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $HdrPath) | Out-Null
  Set-Content -Path $HdrPath -Value $content -Encoding UTF8
  Info "Wrote minimal include_opencv.h -> $HdrPath"
}

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
New-Item -ItemType Directory -Force -Path $OpenCvB | Out-Null

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

# Ensure generated headers exist where our include paths already point
Info "Ensure generated OpenCV headers are under $OpenCvB/include/opencv2"
Ensure-GeneratedOpenCvHeader $OpenCvB "opencv_modules.hpp"
Ensure-GeneratedOpenCvHeader $OpenCvB "cvconfig.h"

# -----------------------------
# 2) Overwrite include_opencv.h to minimal version (core/imgproc/videoio only)
# -----------------------------
$ExternInclude = Join-Path $SharpSrc "src\OpenCvSharpExtern\include_opencv.h"
Assert-Exists (Split-Path -Parent $ExternInclude) "OpenCvSharpExtern dir missing: $(Split-Path -Parent $ExternInclude)"
Write-MinimalIncludeOpenCv $ExternInclude

# -----------------------------
# 3) Build OpenCvSharpExtern.dll with minimal CMake project (bypass upstream)
# -----------------------------
Info "Generate minimal CMake project for OpenCvSharpExtern (bypass upstream CMakeLists)"
$ExternSrc = Join-Path $SharpSrc "src\OpenCvSharpExtern"
Assert-Exists $ExternSrc "Extern src missing: $ExternSrc"

$MinProj   = Join-Path $Bld "opencvsharp_minproj"
$MinBuild  = Join-Path $Bld "opencvsharp_minbuild"
New-Item -ItemType Directory -Force -Path $MinProj,$MinBuild | Out-Null

$CoreCpp    = Join-Path $ExternSrc "core.cpp"
$ImgProcCpp = Join-Path $ExternSrc "imgproc.cpp"
$VideoIoCpp = Join-Path $ExternSrc "videoio.cpp"

foreach ($f in @($CoreCpp,$ImgProcCpp,$VideoIoCpp)) {
  Assert-Exists $f "Missing expected source: $f"
}

$OpenCvB_CMake     = To-CMakePath $OpenCvB
$OpenCvSrc_CMake   = To-CMakePath $OpenCvSrc
$ExternSrc_CMake   = To-CMakePath $ExternSrc
$CoreCpp_CMake     = To-CMakePath $CoreCpp
$ImgProcCpp_CMake  = To-CMakePath $ImgProcCpp
$VideoIoCpp_CMake  = To-CMakePath $VideoIoCpp

$OpenCvBuildInclude_CMake = "$OpenCvB_CMake/include"

$moduleIncludeLines = ""
foreach ($m in ($BuildList -split ",")) {
  $mm = $m.Trim()
  if ($mm.Length -gt 0) {
    $moduleIncludeLines += "  `"$OpenCvSrc_CMake/modules/$mm/include`"`n"
  }
}

$CMakeLists = @"
cmake_minimum_required(VERSION 3.18)
project(OpenCvSharpExternMin LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(OpenCV_DIR "$OpenCvB_CMake")
find_package(OpenCV REQUIRED CONFIG NO_DEFAULT_PATH)

add_library(OpenCvSharpExtern SHARED
  "$CoreCpp_CMake"
  "$ImgProcCpp_CMake"
  "$VideoIoCpp_CMake"
)

target_include_directories(OpenCvSharpExtern PRIVATE
  "$ExternSrc_CMake"
  "$ExternSrc_CMake/include"
  "$ExternSrc_CMake/.."
  "$OpenCvSrc_CMake/include"
  "$OpenCvBuildInclude_CMake"
$moduleIncludeLines
)

target_compile_definitions(OpenCvSharpExtern PRIVATE OpenCvSharpExtern_EXPORTS)
target_link_libraries(OpenCvSharpExtern PRIVATE ${OpenCV_LIBS})

set_target_properties(OpenCvSharpExtern PROPERTIES OUTPUT_NAME "OpenCvSharpExtern")
"@

Set-Content -Path (Join-Path $MinProj "CMakeLists.txt") -Value $CMakeLists -Encoding UTF8

Info "Configure OpenCvSharpExtern (win-x64, minimal project)"
cmake -S $MinProj -B $MinBuild -G Ninja `
  -D CMAKE_BUILD_TYPE=Release

Info "Build OpenCvSharpExtern"
try {
  cmake --build $MinBuild --config Release
}
catch {
  Info "Build failed. If you see unresolved headers/symbols from imgcodecs/highgui, you MUST add that module to BUILD_LIST."
  Info "Example: BUILD_LIST=core,imgproc,videoio,imgcodecs"
  throw
}

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
