#!/usr/bin/env python3
"""
smoke_test_mnn_unix.py
MNN libMNN.so / libMNN.dylib 冒烟测试 (Linux / macOS)

用法:
    python3 smoke_test_mnn_unix.py <libMNN.so 或 .dylib 绝对路径>

测试内容:
    1. nm 静态检查 — 确认导出表里有大量 MNN namespace 符号 (mangled `_ZN3MNN...` 或 `MNN`)
    2. ctypes 加载 — 确认 .so/.dylib 能动态加载 (依赖项齐全, ABI 正常)
    3. (Linux) glibc 最低版本 — 提示客户机兼容性

通过条件:
    - MNN 相关符号 >= 100 个 (粗略门槛, MNN 实际有几千个)
    - dlopen 不报 OSError
"""
import ctypes
import os
import re
import subprocess
import sys

# 防御 Windows runner 中文 stdout codec 报错 (Linux/Mac 默认 UTF-8 但保险)
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")


def check_symbols(lib_path: str) -> bool:
    is_macos = sys.platform == "darwin"
    nm_args = ["nm", "-gU", lib_path] if is_macos else ["nm", "-D", lib_path]
    flag_desc = "-gU" if is_macos else "-D"
    print(f"── 符号检查 (nm {flag_desc}) ──────────────────────────────")
    try:
        r = subprocess.run(nm_args, capture_output=True, text=True, check=True)
        out = r.stdout
    except subprocess.CalledProcessError as e:
        print(f"  nm 失败: {e.stderr.strip()}")
        return False

    # MNN 名字空间符号在 Itanium ABI mangle 里都包含 "3MNN" (length-prefixed),
    # 在 demangled 形式包含 "MNN::". 直接 substring 'MNN' 最稳妥(系统库通常没有 MNN 字符)。
    mnn_count = sum(1 for line in out.splitlines() if "MNN" in line)
    total = sum(1 for line in out.splitlines() if line.strip())
    print(f"  导出符号总数:    {total}")
    print(f"  MNN namespace:  {mnn_count}")
    if mnn_count < 100:
        print("  ✗  MNN 符号过少,产物可能没编全 (期望 >= 100)")
        return False
    print(f"  ✓  MNN 符号充足")
    return True


def runtime_load(lib_path: str) -> bool:
    print("── 运行时加载 (ctypes.CDLL) ──────────────────────")
    try:
        lib = ctypes.CDLL(lib_path)
    except OSError as e:
        print(f"  ✗  加载失败: {e}")
        return False
    print(f"  ✓  CDLL handle = {lib}")
    return True


def check_glibc(lib_path: str) -> None:
    print("── glibc 最低版本 (objdump -T) ──────────────────")
    try:
        r = subprocess.run(
            ["objdump", "-T", lib_path], capture_output=True, text=True
        )
        versions = re.findall(r"GLIBC_(\d+\.\d+)", r.stdout + r.stderr)
        if not versions:
            print("  (静态链接 / 无 GLIBC 版本符号)")
            return
        max_v = max(versions, key=lambda v: tuple(int(x) for x in v.split(".")))
        print(f"  产物最低 glibc 依赖: {max_v}")
        major, minor = (int(x) for x in max_v.split("."))
        if (major, minor) <= (2, 17):
            print("  ✓  兼容 CentOS 7 + 全主流国产 Linux")
        elif (major, minor) <= (2, 27):
            print("  ✓  兼容 Ubuntu 18.04 / 麒麟 V10 / 统信 UOS V20 / 欧拉")
        elif (major, minor) <= (2, 31):
            print("  ⚠  需 glibc >= 2.31 (Ubuntu 20.04+);某些信创系统不兼容")
        else:
            print(f"  ⚠  需 glibc >= {max_v};兼容性差")
    except FileNotFoundError:
        print("  (objdump 不可用,跳过)")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"用法: {sys.argv[0]} <libMNN.so 或 .dylib>", file=sys.stderr)
        return 1

    lib_path = os.path.abspath(sys.argv[1])
    if not os.path.exists(lib_path):
        print(f"::error::文件不存在: {lib_path}", file=sys.stderr)
        return 1

    print("=" * 64)
    print(f"  MNN 冒烟测试")
    print(f"  文件: {lib_path}")
    print(f"  大小: {os.path.getsize(lib_path):,} bytes")
    print("=" * 64)

    ok_sym = check_symbols(lib_path)
    print()
    ok_load = runtime_load(lib_path)
    print()
    if sys.platform != "darwin":
        check_glibc(lib_path)
        print()

    if ok_sym and ok_load:
        print("✅  所有测试通过")
        return 0
    print("❌  测试失败")
    return 1


if __name__ == "__main__":
    sys.exit(main())
