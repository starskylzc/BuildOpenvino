$ErrorActionPreference = "Stop"

$OPENCV_VERSION = "4.7.0"
$OPENCVSHARP_TAG = "4.7.0.20230224"

$ROOT = (Get-Location).Path
$WORK = Join-Path $ROOT "_work"
$OUT  = Join-Path $ROOT "out\windows"
Remove-Item $WORK, $OUT -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $WORK, $OUT | Out-Null

Set-Location $WORK

git clone --depth 1 --branch $OPENCV_VERSION https://github.com/opencv/opencv.git
git clone --depth 1 --branch $OPENCVSHARP_TAG https://github.com/shimat/opencvsharp.git

# Patch cmake_minimum_required < 3.5
Get-ChildItem -Path ".\opencvsharp" -Filter "CMakeLists.txt" -Recurse | ForEach-Object {
  $txt = Get-Content $_.FullName -Raw
  $new = [regex]::Replace($txt, "cmake_minimum_required\s*\(\s*VERSION\s+[0-9.]+\s*\)", "cmake_minimum_required(VERSION 3.5)")
  if ($new -ne $txt) { Set-Content $_.FullName $new -Encoding UTF8 }
}

# 需要 MSVC 环境；windows-latest 默认有 VS 2022
$OPENCV_BUILD = Join-Path $WORK "build-opencv-x64"
$OPENCV_INSTALL = Join-Path $WORK "install-opencv-x64"
$EXTERN_BUILD = Join-Path $WORK "build-extern-x64"

cmake -S ".\opencv" -B $OPENCV_BUILD -G "Visual Studio 17 2022" -A x64 `
  -DCMAKE_BUILD_TYPE=Release `
  -DCMAKE_INSTALL_PREFIX="$OPENCV_INSTALL" `
  -DBUILD_SHARED_LIBS=OFF `
  -DBUILD_LIST=core,imgproc,videoio `
  -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOCS=OFF `
  -DWITH_OPENCL=OFF -DWITH_IPP=OFF -DWITH_TBB=OFF -DWITH_OPENMP=OFF

cmake --build $OPENCV_BUILD --config Release --target INSTALL

cmake -S ".\opencvsharp\src" -B $EXTERN_BUILD -G "Visual Studio 17 2022" -A x64 `
  -DCMAKE_BUILD_TYPE=Release `
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 `
  -DOpenCV_DIR="$OPENCV_INSTALL\build"

cmake --build $EXTERN_BUILD --config Release --target OpenCvSharpExtern

$dll = Get-ChildItem $EXTERN_BUILD -Recurse -Filter "OpenCvSharpExtern.dll" | Select-Object -First 1
if (-not $dll) { throw "OpenCvSharpExtern.dll not found" }

Copy-Item $dll.FullName (Join-Path $OUT "OpenCvSharpExtern.dll") -Force
