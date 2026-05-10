"""
YuYiNoPhotoLib patch -- silence MNN_PRINT and MNN_ERROR in MNNDefine.h.

Upstream MNN macros (include/MNN/MNNDefine.h, desktop branch):
    #define MNN_PRINT(format, ...) printf(format, ##__VA_ARGS__)
    #define MNN_ERROR(format, ...) printf(format, ##__VA_ARGS__)

Both leak diagnostic strings to stdout that reveal the inference engine
identity and internals, bypassing our managed AsyncLogger:

  MNN_PRINT  -> "Update cache to ...", "The device supports: i8sdot:0, ..."
  MNN_ERROR  -> "Can't open file:..." (every GPU cold-start cache miss),
                "Load Cache file error." (cache header parse expected miss)

MNN_ERROR upstream fires on cold-start cache miss (NOT real errors), so
silencing both is safe for production. Real fault reporting comes from our
managed AsyncLogger via mnnwrap return codes.

Replace both with a do-while-0 no-op. Idempotent (marker comment).

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

MARKER = "// YuYiNoPhotoLib: MNN_PRINT/MNN_ERROR both silenced"
LEGACY_MARKER = "// YuYiNoPhotoLib: MNN_PRINT silenced"  # earlier patch that only nuked MNN_PRINT
if MARKER in src:
    print("MNNDefine.h already patched (full silence); skip")
    sys.exit(0)

new_block = (
    "// YuYiNoPhotoLib: MNN_PRINT/MNN_ERROR both silenced -- upstream MNN_ERROR\n"
    "// is mostly cold-start spam (Can't open file / Load Cache file error),\n"
    "// real faults come back through mnnwrap return codes to managed AsyncLogger.\n"
    "#define MNN_PRINT(format, ...) do {} while (0)\n"
    "#define MNN_ERROR(format, ...) do {} while (0)"
)

# Path A: fresh MNN source — both macros use printf as upstream
old_block_fresh = """#define MNN_PRINT(format, ...) printf(format, ##__VA_ARGS__)
#define MNN_ERROR(format, ...) printf(format, ##__VA_ARGS__)"""

# Path B: previously patched (PRINT -> no-op, ERROR still printf) — upgrade in place
old_block_legacy = (
    "// YuYiNoPhotoLib: MNN_PRINT silenced -- production binaries don't leak engine\n"
    "// internals via stdout printf. MNN_ERROR kept (real-error path, rare).\n"
    "#define MNN_PRINT(format, ...) do {} while (0)\n"
    "#define MNN_ERROR(format, ...) printf(format, ##__VA_ARGS__)"
)

if old_block_fresh in src:
    src = src.replace(old_block_fresh, new_block, 1)
    print("Patched " + target.name + ": MNN_PRINT + MNN_ERROR -> no-op (fresh source)")
elif old_block_legacy in src:
    src = src.replace(old_block_legacy, new_block, 1)
    print("Patched " + target.name + ": upgraded legacy patch to also silence MNN_ERROR")
else:
    print("::error::Neither fresh nor legacy MNN_PRINT/MNN_ERROR block found")
    print("Expected (fresh): " + repr(old_block_fresh[:80]))
    sys.exit(2)

target.write_text(src, encoding="utf-8")
