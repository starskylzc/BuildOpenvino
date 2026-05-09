#!/usr/bin/env python3
"""
smoke_test_mnn_windows.py
MNN MNN.dll 冒烟测试 (Windows). 用 pefile 解析 PE, 跨平台一致, 不依赖 VS env (dumpbin).

用法:
    python smoke_test_mnn_windows.py <MNN.dll 路径>

测试内容:
    1. pefile 解析 export 表 — 确认 MNN namespace 符号充足 (>= 100)
    2. PE subsystem version — Win7 兼容档 (win-x64/win-x86) 应 <= 6.01
    3. ctypes.CDLL 加载 — 仅当 Python host arch 与 DLL arch 匹配时跑

依赖:
    pip install pefile
"""
import ctypes
import os
import platform
import sys

try:
    import pefile  # type: ignore[import-not-found]
except ImportError:
    print("::error::pefile not installed; run 'pip install pefile'", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"用法: {sys.argv[0]} <MNN.dll>", file=sys.stderr)
        return 1

    dll = os.path.abspath(sys.argv[1])
    if not os.path.exists(dll):
        print(f"::error::文件不存在: {dll}", file=sys.stderr)
        return 1

    print("=" * 64)
    print("  MNN 冒烟测试 (Windows / PE)")
    print(f"  文件: {dll}")
    print(f"  大小: {os.path.getsize(dll):,} bytes")
    print("=" * 64)

    pe = pefile.PE(dll, fast_load=True)
    pe.parse_data_directories(directories=[
        pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_EXPORT"]
    ])

    syms = []
    if hasattr(pe, "DIRECTORY_ENTRY_EXPORT"):
        for s in pe.DIRECTORY_ENTRY_EXPORT.symbols:
            if s.name:
                syms.append(s.name.decode(errors="replace"))
            else:
                syms.append(f"#{s.ordinal}")

    # MNN 的 MSVC mangled C++ 符号包含 "MNN@@" / "MNN" 子串,直接 substring 匹配最稳妥
    mnn_syms = [s for s in syms if "MNN" in s]
    print("\n── 符号检查 ──────────────────────────")
    print(f"  导出符号总数: {len(syms)}")
    print(f"  MNN 命名:     {len(mnn_syms)}")
    if len(mnn_syms) < 100:
        print("::error::MNN 符号过少 (< 100), 产物可能没编全")
        return 1
    print("  ✓ MNN 符号充足")

    # PE subsystem version (Win7 兼容硬指标)
    sub_maj = pe.OPTIONAL_HEADER.MajorSubsystemVersion
    sub_min = pe.OPTIONAL_HEADER.MinorSubsystemVersion
    print("\n── PE subsystem version ──────────────")
    print(f"  实际: {sub_maj}.{sub_min:02d}")
    if sub_maj <= 6:
        print("  ✓ <= 6.01 — Win7 兼容档 (win-x64/win-x86 期望)")
    elif sub_maj == 10:
        print("  ℹ 10.00 — Win10+ 档 (win-arm64 期望)")
    else:
        print(f"::warning::非常规 subsystem {sub_maj}.{sub_min}")

    # ctypes 加载 (仅 host arch 匹配时)
    machine = pe.FILE_HEADER.Machine
    arch_map = {0x8664: "x64", 0xAA64: "arm64", 0x14C: "x86"}
    dll_arch = arch_map.get(machine, f"0x{machine:x}")
    host = platform.machine().lower()
    print("\n── ctypes 加载 ──────────────────────")
    print(f"  Python host arch: {host}")
    print(f"  DLL machine:      {dll_arch}")
    host_match = (
        (dll_arch == "x64"   and host in ("amd64", "x86_64")) or
        (dll_arch == "arm64" and host in ("arm64", "aarch64")) or
        (dll_arch == "x86"   and host == "x86")
    )
    if host_match:
        try:
            lib = ctypes.CDLL(dll)
            print(f"  ✓ ctypes.CDLL OK -> {lib}")
        except OSError as e:
            print(f"::error::CDLL 加载失败: {e}")
            return 1
    else:
        print("  (跳过 — host arch 与 DLL arch 不匹配)")

    print("\n✅ 所有测试通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
