#!/usr/bin/env python3
"""
smoke_test_unix.py
OpenCvSharpExtern 冒烟测试（Linux / macOS）

用法：
  python3 smoke_test_unix.py <库文件路径>

测试内容：
  1. 静态检查：用 nm 验证关键导出符号存在
  2. 运行时：用 ctypes 加载库并实际调用 core_Mat_sizeof()
             返回值应为正整数（cv::Mat 的 sizeof，通常 96~200 字节）
"""

import ctypes
import re
import subprocess
import sys
import os

REQUIRED_SYMBOLS = [
    "core_Mat_sizeof",  # core 模块基础验证
    "core_Mat_new1",  # Mat 构造
    "imgproc_resize",  # imgproc 模块验证
    "videoio_VideoCapture_new1",  # videoio 模块验证
]


def check_symbols(lib_path: str) -> bool:
    """检查导出符号是否存在。
    Linux .so  → nm -D（动态符号表）
    macOS .dylib → nm -gU（全局已定义符号；.dylib 无动态符号表，-D 会报错）
    """
    is_macos = sys.platform == "darwin"
    nm_args = ["nm", "-gU", lib_path] if is_macos else ["nm", "-D", lib_path]
    flag_desc = "-gU" if is_macos else "-D"
    print(f"── 符号检查 (nm {flag_desc}) ──────────────────────────────")
    try:
        result = subprocess.run(nm_args, capture_output=True, text=True, check=True)
        symbols = result.stdout
    except subprocess.CalledProcessError as e:
        print(f"  nm 执行失败: {e.stderr.strip()}")
        return False

    all_ok = True
    for sym in REQUIRED_SYMBOLS:
        if sym in symbols:
            print(f"  ✓  {sym}")
        else:
            print(f"  ✗  {sym}  ← 缺失！")
            all_ok = False
    return all_ok


def runtime_test(lib_path: str) -> bool:
    """用 ctypes 实际加载并调用库函数"""
    print("── 运行时测试 (ctypes) ───────────────────────────")
    try:
        lib = ctypes.CDLL(lib_path)
    except OSError as e:
        print(f"  加载失败: {e}")
        return False

    # core_Mat_sizeof() → size_t，无参数，返回 cv::Mat 的内存大小
    lib.core_Mat_sizeof.restype = ctypes.c_size_t
    lib.core_Mat_sizeof.argtypes = []
    mat_size = lib.core_Mat_sizeof()
    print(f"  core_Mat_sizeof()  = {mat_size} bytes")
    if mat_size <= 0:
        print("  ✗  返回值应为正整数")
        return False
    print(f"  ✓  core_Mat_sizeof 调用成功")

    # core_Mat_new1() → ExceptionStatus，无参数，创建空 Mat
    # 仅验证可调用，不检查返回值语义
    lib.core_Mat_new1.restype = ctypes.c_void_p
    lib.core_Mat_new1.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    out = ctypes.c_void_p()
    lib.core_Mat_new1(ctypes.byref(out))
    print(f"  ✓  core_Mat_new1 调用成功（ptr={out.value}）")

    return True


def check_glibc_version(lib_path: str) -> None:
    """用 objdump -T 打印产物实际依赖的最低 glibc 版本（仅信息，不影响通过/失败）"""
    print("── glibc 最低版本检查 (objdump -T) ──────────────")
    try:
        result = subprocess.run(
            ["objdump", "-T", lib_path], capture_output=True, text=True
        )
        output = result.stdout + result.stderr
        # 提取所有 GLIBC_x.y 版本号
        versions = re.findall(r"GLIBC_(\d+\.\d+)", output)
        if versions:
            # 按版本号排序找最高（即最低系统要求）
            max_ver = max(versions, key=lambda v: tuple(int(x) for x in v.split(".")))
            print(f"  产物依赖的最低 glibc 版本：{max_ver}")
            # 给出兼容性提示
            major, minor = (int(x) for x in max_ver.split("."))
            if (major, minor) <= (2, 17):
                print("  ✓  兼容 CentOS 7 及以上所有主流 Linux")
            elif (major, minor) <= (2, 28):
                print("  ✓  兼容 统信 UOS V20 / Debian 10 及以上")
            elif (major, minor) <= (2, 31):
                print(
                    "  ⚠  需要 glibc >= 2.31（Ubuntu 20.04 / 麒麟 V10），统信 UOS V20 不兼容"
                )
            else:
                print(f"  ⚠  需要 glibc >= {max_ver}，兼容性较差")
        else:
            print("  （未找到 GLIBC 符号版本信息，可能是静态链接）")
    except FileNotFoundError:
        print("  （objdump 不可用，跳过此检查）")


def main():
    if len(sys.argv) != 2:
        print(f"用法: {sys.argv[0]} <库文件路径>")
        sys.exit(1)

    lib_path = os.path.abspath(sys.argv[1])
    if not os.path.exists(lib_path):
        print(f"错误：文件不存在: {lib_path}")
        sys.exit(1)

    print(f"\n{'=' * 52}")
    print(f"  OpenCvSharpExtern 冒烟测试")
    print(f"  文件: {lib_path}")
    print(f"  大小: {os.path.getsize(lib_path):,} bytes")
    print(f"{'=' * 52}\n")

    ok_sym = check_symbols(lib_path)
    print()
    ok_runtime = runtime_test(lib_path)
    print()
    # glibc 版本检查（仅 Linux，macOS 无此概念）
    if sys.platform != "darwin":
        check_glibc_version(lib_path)
        print()

    if ok_sym and ok_runtime:
        print("✅  所有测试通过")
        sys.exit(0)
    else:
        print("❌  测试失败")
        sys.exit(1)

    lib_path = os.path.abspath(sys.argv[1])
    if not os.path.exists(lib_path):
        print(f"错误：文件不存在: {lib_path}")
        sys.exit(1)

    print(f"\n{'=' * 52}")
    print(f"  OpenCvSharpExtern 冒烟测试")
    print(f"  文件: {lib_path}")
    print(f"  大小: {os.path.getsize(lib_path):,} bytes")
    print(f"{'=' * 52}\n")

    ok_sym = check_symbols(lib_path)
    print()
    ok_runtime = runtime_test(lib_path)
    print()

    if ok_sym and ok_runtime:
        print("✅  所有测试通过")
        sys.exit(0)
    else:
        print("❌  测试失败")
        sys.exit(1)


if __name__ == "__main__":
    main()
