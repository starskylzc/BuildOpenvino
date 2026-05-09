# smoke_test_windows.ps1
# OpenCvSharpExtern 冒烟测试 (Windows) — 用 Python pefile 解析 PE,
# 不依赖 dumpbin (后者要 VS env, smoke step 没有). 跟 MNN smoke test 同套路.
#
# 用法:
#   pwsh -File smoke_test_windows.ps1 -LibPath "C:\path\to\OpenCvSharpExtern.dll" [-Arch x64]

param(
    [Parameter(Mandatory=$true)] [string]$LibPath,
    [string]$Arch = "x64"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $LibPath)) {
    Write-Host "::error::文件不存在: $LibPath"
    exit 1
}

# 用 pip pefile (无 VS env 依赖, 跨 host arch 工作)
python -m pip install --quiet pefile

# 内联 Python 跑符号检查 + ctypes 加载
$LibPath = [System.IO.Path]::GetFullPath($LibPath)
$env:PYTHONIOENCODING = "utf-8"
& python -c @"
import os, sys, ctypes, platform
sys.stdout.reconfigure(encoding='utf-8') if hasattr(sys.stdout,'reconfigure') else None

import pefile
dll = r'$LibPath'
arch = '$Arch'

print('=' * 64)
print('  OpenCvSharpExtern Smoke Test')
print(f'  File: {dll}')
print(f'  Arch: {arch}')
print(f'  Size: {os.path.getsize(dll):,} bytes')
print('=' * 64)

pe = pefile.PE(dll, fast_load=True)
pe.parse_data_directories(directories=[
    pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_EXPORT']
])
syms = []
if hasattr(pe, 'DIRECTORY_ENTRY_EXPORT'):
    for s in pe.DIRECTORY_ENTRY_EXPORT.symbols:
        syms.append(s.name.decode(errors='replace') if s.name else f'#{s.ordinal}')

REQUIRED = ['core_Mat_sizeof', 'core_Mat_new1', 'imgproc_resize', 'videoio_VideoCapture_new1']
print()
print('-- Required symbols --')
missing = []
for r in REQUIRED:
    if r in syms:
        print(f'  + {r}')
    else:
        print(f'  - {r}  MISSING')
        missing.append(r)
if missing:
    print(f'::error::missing symbols: {missing}')
    sys.exit(1)

# Subsystem
sub_maj = pe.OPTIONAL_HEADER.MajorSubsystemVersion
sub_min = pe.OPTIONAL_HEADER.MinorSubsystemVersion
print(f'-- PE subsystem: {sub_maj}.{sub_min:02d} --')
if arch in ('x64','x86'):
    expected = (6,1) if arch == 'x64' else (5,1)
    if (sub_maj, sub_min) > expected:
        print(f'::error::subsystem {sub_maj}.{sub_min:02d} > expected {expected[0]}.{expected[1]:02d} (Win7 fail)')
        sys.exit(1)
    print(f'  + Win7 compatible (<= {expected[0]}.{expected[1]:02d})')

# ctypes load (host arch matches)
machine_map = {0x8664: 'x64', 0xAA64: 'arm64', 0x14C: 'x86'}
dll_arch = machine_map.get(pe.FILE_HEADER.Machine, 'unknown')
host = platform.machine().lower()
print(f'-- ctypes load (host={host}, dll={dll_arch}) --')
match = (
    (dll_arch == 'x64'   and host in ('amd64','x86_64')) or
    (dll_arch == 'arm64' and host in ('arm64','aarch64')) or
    (dll_arch == 'x86'   and host == 'x86')
)
if match:
    try:
        lib = ctypes.CDLL(dll)
        lib.core_Mat_sizeof.restype = ctypes.c_size_t
        sz = lib.core_Mat_sizeof()
        print(f'  + core_Mat_sizeof() = {sz}')
        if sz <= 0:
            print('::error::core_Mat_sizeof returned <= 0')
            sys.exit(1)
    except OSError as e:
        print(f'::error::CDLL load failed: {e}')
        sys.exit(1)
else:
    print('  (skip - host arch mismatch)')

print()
print('+ All smoke tests passed')
"@

if ($LASTEXITCODE -ne 0) {
    Write-Host "::error::smoke test exit $LASTEXITCODE"
    exit 1
}
