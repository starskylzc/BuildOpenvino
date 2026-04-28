"""离线把 test.png 转成 test.bgr — raw BGR bytes,不需要 imgcodecs 在 CI 解码。

格式 (little-endian):
  bytes [0:4]    uint32  width
  bytes [4:8]    uint32  height
  bytes [8]      uint8   channels (固定 3 = BGR)
  bytes [9:]     raw     H * W * 3 bytes BGR (跟 OpenCV Mat CV_8UC3 内存布局一致)

用 Pillow 而不是 cv2/numpy 因为:
  - Pillow 在 win-arm64 / linux-arm64 / mac/x64 都有预编 wheel
  - opencv-python 没 win-arm64 wheel,build from source 失败
  - numpy 同样在 win-arm64 没 wheel,而且 Pillow 不依赖 numpy
"""
import struct
import sys
from pathlib import Path
from PIL import Image  # Pillow,纯 Python pkg + 自带原生

HERE = Path(__file__).resolve().parent
PNG = HERE / "test.png"
BGR = HERE / "test.bgr"

img = Image.open(PNG).convert("RGB")  # PIL 默认 RGB
w, h = img.size
rgb = img.tobytes()  # H*W*3 RGB row-major
# RGB → BGR:每个像素的 R 和 B 互换 (中间 G 不动)
buf = bytearray(rgb)
for i in range(0, len(buf), 3):
    buf[i], buf[i + 2] = buf[i + 2], buf[i]

with BGR.open("wb") as f:
    f.write(struct.pack("<I", w))
    f.write(struct.pack("<I", h))
    f.write(struct.pack("<B", 3))
    f.write(bytes(buf))

print(f"Wrote {BGR}")
print(f"  W={w}, H={h}, channels=3")
print(f"  Bytes: {BGR.stat().st_size} (header 9 + pixels {w*h*3})")
