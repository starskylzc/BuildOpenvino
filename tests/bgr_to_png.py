"""把 C# verify 输出的 annotated-<platform>.bgr 转回 PNG 给人肉眼看。

CI-only — 客户端 production 不需要这个,只是为了 GitHub Actions 上传 artifact 时
能直接看到 OpenCvSharp 画框的可视化结果 (.bgr 二进制看不出来)。

用 Pillow (无 numpy 依赖,所有平台都有 wheel)。
用法: python bgr_to_png.py <input.bgr> <output.png>
"""
import struct
import sys
from pathlib import Path
from PIL import Image

if len(sys.argv) < 3:
    print("Usage: bgr_to_png.py <input.bgr> <output.png>")
    sys.exit(1)
src = Path(sys.argv[1])
dst = Path(sys.argv[2])

with src.open("rb") as f:
    w = struct.unpack("<I", f.read(4))[0]
    h = struct.unpack("<I", f.read(4))[0]
    c = struct.unpack("<B", f.read(1))[0]
    assert c == 3, f"expected 3 channels, got {c}"
    raw = f.read()
    assert len(raw) == w * h * c, f"size mismatch: hdr says {w}x{h}x{c}={w*h*c}, got {len(raw)}"

# raw 是 BGR,Pillow 需要 RGB
buf = bytearray(raw)
for i in range(0, len(buf), 3):
    buf[i], buf[i + 2] = buf[i + 2], buf[i]

img = Image.frombytes("RGB", (w, h), bytes(buf))
img.save(dst, "PNG")
print(f"Wrote {dst} ({w}x{h})")
