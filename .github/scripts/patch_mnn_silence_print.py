"""
YuYiNoPhotoLib patch -- redirect MNN_PRINT / MNN_ERROR through wrapper callback.

Upstream MNN macros (include/MNN/MNNDefine.h, desktop branch):
    #define MNN_PRINT(format, ...) printf(format, ##__VA_ARGS__)
    #define MNN_ERROR(format, ...) printf(format, ##__VA_ARGS__)

Both leak diagnostic strings to stdout that reveal engine internals + cause
cold-start spam. We route them to wrapper-controlled callback instead:

  MNN_PRINT  -> no-op (debug spam, never useful in production)
  MNN_ERROR  -> yuyi_backend_native_log(format, ...)

yuyi_backend_native_log lives in mnnwrap.cpp. If C# side registers a
callback via yuyi_backend_set_log_callback, errors flow into AsyncLogger
(file / debug sink). If no callback registered, default is silent — no
stdout/stderr pollution either way.

Patcher prepends a tiny declaration block to MNNDefine.h so the symbol is
visible to every MNN .cpp that includes it, then rewrites the macro
definitions. Idempotent (marker comment).

Usage:
    python patch_mnn_silence_print.py <MNN_SOURCE>
"""
import io
import sys
from pathlib import Path

# Force UTF-8 stdout for Windows GHA cp1252 runners.
if sys.stdout.encoding and sys.stdout.encoding.lower() not in ("utf-8", "utf8"):
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

target = Path(sys.argv[1]) / "include" / "MNN" / "MNNDefine.h"
if not target.exists():
    print(f"::error::{target} not found")
    sys.exit(1)

src = target.read_text(encoding="utf-8")

MARKER = "// YuYiNoPhotoLib: MNN_ERROR routed to yuyi_backend_native_log"
if MARKER in src:
    print("MNNDefine.h already patched (route to wrapper); skip")
    sys.exit(0)

# 新 block: 注入 extern 声明 + 重写两宏。
# MNN_PRINT 直接 no-op (调试 spam,生产无用);
# MNN_ERROR 路由到 wrapper 的 yuyi_backend_native_log。
# 没注册回调时 yuyi_backend_native_log 直接 return,format/vsnprintf 都不算
# (cb 检查在前),性能 ≈ 跟 do-while-0 一样。
new_block = (
    "// YuYiNoPhotoLib: MNN_ERROR routed to yuyi_backend_native_log (callback in mnnwrap)\n"
    "// MNN_PRINT 直接 no-op 不留任何字面量;MNN_ERROR 走 wrapper 的回调,\n"
    "// 上层 (C# AsyncLogger) 决定写文件 / 丢弃,native 不再直写 stdout/stderr.\n"
    "//\n"
    "// 跨 DLL 修饰:MNN.dll 主体 (BUILDING_MNN_DLL) 和 mnnwrap.cpp (MNNWRAP_BUILDING)\n"
    "// 看到 dllexport;MNN tools (MNNV2Basic.exe / GetMNNInfo.exe / 等) 链接 MNN.dll,\n"
    "// 看到 dllimport — 否则 LNK2019 unresolved external.\n"
    "#ifdef __cplusplus\n"
    "extern \"C\" {\n"
    "#endif\n"
    "#if defined(_MSC_VER)\n"
    "  #if defined(BUILDING_MNN_DLL) || defined(MNNWRAP_BUILDING)\n"
    "    __declspec(dllexport) void yuyi_backend_native_log(const char* fmt, ...);\n"
    "  #else\n"
    "    __declspec(dllimport) void yuyi_backend_native_log(const char* fmt, ...);\n"
    "  #endif\n"
    "#else\n"
    "  __attribute__((visibility(\"default\"))) void yuyi_backend_native_log(const char* fmt, ...);\n"
    "#endif\n"
    "#ifdef __cplusplus\n"
    "}\n"
    "#endif\n"
    "#define MNN_PRINT(format, ...) do {} while (0)\n"
    "#define MNN_ERROR(format, ...) yuyi_backend_native_log(format, ##__VA_ARGS__)"
)

# 三种已知输入形态:
#   A 全新 MNN 源 (两 macro 都 printf)
#   B 旧 silencer 半 patch (PRINT -> no-op, ERROR 还 printf)
#   C 旧 silencer 全 patch (两个都 do-while-0)

old_block_fresh = """#define MNN_PRINT(format, ...) printf(format, ##__VA_ARGS__)
#define MNN_ERROR(format, ...) printf(format, ##__VA_ARGS__)"""

old_block_legacy_print_only = (
    "// YuYiNoPhotoLib: MNN_PRINT silenced -- production binaries don't leak engine\n"
    "// internals via stdout printf. MNN_ERROR kept (real-error path, rare).\n"
    "#define MNN_PRINT(format, ...) do {} while (0)\n"
    "#define MNN_ERROR(format, ...) printf(format, ##__VA_ARGS__)"
)

old_block_legacy_both = (
    "// YuYiNoPhotoLib: MNN_PRINT/MNN_ERROR both silenced -- upstream MNN_ERROR\n"
    "// is mostly cold-start spam (Can't open file / Load Cache file error),\n"
    "// real faults come back through mnnwrap return codes to managed AsyncLogger.\n"
    "#define MNN_PRINT(format, ...) do {} while (0)\n"
    "#define MNN_ERROR(format, ...) do {} while (0)"
)

if old_block_fresh in src:
    src = src.replace(old_block_fresh, new_block, 1)
    print("Patched " + target.name + ": route from fresh upstream")
elif old_block_legacy_print_only in src:
    src = src.replace(old_block_legacy_print_only, new_block, 1)
    print("Patched " + target.name + ": upgraded legacy (print-only silence) -> route")
elif old_block_legacy_both in src:
    src = src.replace(old_block_legacy_both, new_block, 1)
    print("Patched " + target.name + ": upgraded legacy (full silence) -> route")
else:
    print("::error::Neither fresh nor any known legacy MNN_PRINT/MNN_ERROR block found")
    print("Expected fresh: " + repr(old_block_fresh[:80]))
    sys.exit(2)

target.write_text(src, encoding="utf-8")
