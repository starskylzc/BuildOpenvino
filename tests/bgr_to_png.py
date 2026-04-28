"""把 C# verify 输出的 annotated-<platform>.bgr 转回 PNG 给人肉眼看。

CI-only — 客户端 production 不需要这个,只是为了 GitHub Actions 上传 artifact 时
能直接看到 OpenCvSharp 画框的可视化结果 (.bgr 二进制看不出来)。

用法: python bgr_to_png.py <input.bgr> <output.png>
格式跟 png_to_bgr.py 一致 (4B W + 4B H + 1B C + W*H*C bytes BGR)
"""
import struct
import sys
from pathlib import Path
import numpy as np
import cv2

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

img = np.frombuffer(raw, dtype=np.uint8).reshape(h, w, c)
cv2.imwrite(str(dst), img)
print(f"Wrote {dst} ({w}x{h})")
