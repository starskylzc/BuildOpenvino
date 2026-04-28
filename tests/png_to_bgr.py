"""离线把 test.png 转成 test.bgr — raw BGR bytes,不需要 imgcodecs 在 CI 解码。

格式 (little-endian):
  bytes [0:4]    uint32  width
  bytes [4:8]    uint32  height
  bytes [8]      uint8   channels (固定 3 = BGR)
  bytes [9:]     raw     H * W * 3 bytes BGR (跟 OpenCV Mat CV_8UC3 内存布局一致)

在本地跑一次,提交 test.bgr 进仓库。CI 端 C# 直接 File.ReadAllBytes + Mat 构造,
跟 production 拿摄像头帧一致 (videoio 给 byte[] → Mat),不依赖 PNG decoder。
"""
import struct
import sys
from pathlib import Path
import cv2  # 只本地用一次,生成 test.bgr 后 CI 不需要 cv2

HERE = Path(__file__).resolve().parent
PNG = HERE / "test.png"
BGR = HERE / "test.bgr"

img = cv2.imread(str(PNG), cv2.IMREAD_COLOR)  # BGR HxWx3 u8
if img is None:
    print(f"Failed to read {PNG}")
    sys.exit(1)
h, w = img.shape[:2]
ch = img.shape[2]
assert ch == 3, f"expected 3 channels, got {ch}"

with BGR.open("wb") as f:
    f.write(struct.pack("<I", w))    # width LE u32
    f.write(struct.pack("<I", h))    # height LE u32
    f.write(struct.pack("<B", ch))   # channels u8
    f.write(img.tobytes())

print(f"Wrote {BGR}")
print(f"  W={w}, H={h}, channels={ch}")
print(f"  Bytes: {BGR.stat().st_size} (header 9 + pixels {w*h*ch})")
