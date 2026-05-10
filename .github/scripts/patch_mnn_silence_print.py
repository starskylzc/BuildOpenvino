"""
YuYiNoPhotoLib patch -- silence MNN_PRINT in MNNDefine.h.

Upstream MNN macros (include/MNN/MNNDefine.h, desktop branch):
    #define MNN_PRINT(format, ...) printf(format, ##__VA_ARGS__)
    #define MNN_ERROR(format, ...) printf(format, ##__VA_ARGS__)

These leak diagnostic strings to stdout that reveal the inference engine
identity and internals (e.g. "Can't open file:...", "Update cache to ...",
"The device supports: i8sdot:0, fp16:0, ..."), bypassing our managed
AsyncLogger. Replace both with a do-while-0 no-op so production binaries
stay quiet.

Idempotent: skips if already patched (via marker comment).

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

MARKER = "// YuYiNoPhotoLib: MNN_PRINT silenced"
if MARKER in src:
    print("MNNDefine.h already patched (silenced); skip")
    sys.exit(0)

old_block = """#define MNN_PRINT(format, ...) printf(format, ##__VA_ARGS__)
#define MNN_ERROR(format, ...) printf(format, ##__VA_ARGS__)"""

new_block = (
    "// YuYiNoPhotoLib: MNN_PRINT silenced -- production binaries don't leak engine\n"
    "// internals via stdout printf. MNN_ERROR kept (real-error path, rare).\n"
    "#define MNN_PRINT(format, ...) do {} while (0)\n"
    "#define MNN_ERROR(format, ...) printf(format, ##__VA_ARGS__)"
)

if old_block not in src:
    print("::error::MNN_PRINT desktop block not found verbatim (MNN version drift?)")
    print("Looking for: " + repr(old_block[:60]))
    sys.exit(2)

src = src.replace(old_block, new_block, 1)
target.write_text(src, encoding="utf-8")
print("Patched " + target.name + ": MNN_PRINT -> no-op (MNN_ERROR retained)")
