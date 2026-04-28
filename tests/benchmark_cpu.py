"""跑融合模型在 CPU EP 上的 latency / 内存 / CPU 实际占用。

用 PyPI onnxruntime (1.23.2) — 跟我们 build 的 1.25 略有差异但在量级上一致,
能快速给出 "CPU EP 是否足够" 的判断。

输出:
  warmup / N=100 timed runs 的 min / p50 / p99 / mean / stddev (ms)
  peak RSS (MB)
  推理时 CPU 占用 (%)
  线程数 (intra_op_num_threads)
"""
import os
import sys
import time
import statistics
import platform
import struct
from pathlib import Path

import psutil
import onnxruntime as ort
from PIL import Image

HERE = Path(__file__).resolve().parent
MODEL = HERE / "merged_no_topk_fp16.onnx"
PNG = HERE / "test.png"
WARMUP = 10
TIMED = 100


def load_image_as_nchw():
    img = Image.open(PNG).convert("RGB")
    w, h = img.size
    # letterbox 到 640
    import numpy as np
    target = 640
    r = min(target / h, target / w)
    nh, nw = int(round(h * r)), int(round(w * r))
    img2 = img.resize((nw, nh), Image.BILINEAR)
    canvas = Image.new("RGB", (target, target), (114, 114, 114))
    canvas.paste(img2, ((target - nw) // 2, (target - nh) // 2))
    arr = np.frombuffer(canvas.tobytes(), dtype=np.uint8).reshape(target, target, 3)
    nchw = arr.transpose(2, 0, 1).astype(np.float32) / 255.0
    return nchw[None, ...]  # [1,3,640,640]


def main():
    print(f"=== Benchmark CPU EP ===")
    print(f"  Platform   : {platform.system()} {platform.machine()}")
    print(f"  Python     : {platform.python_version()}")
    print(f"  ORT version: {ort.__version__}")
    print(f"  CPU count  : {psutil.cpu_count(logical=False)} physical / {psutil.cpu_count(logical=True)} logical")

    inp = load_image_as_nchw()
    print(f"  Input shape: {inp.shape}, dtype: {inp.dtype}")

    opts = ort.SessionOptions()
    opts.log_severity_level = 3
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
    # 默认让 ORT 自己决定线程数 (= 物理核心),代表"开箱即用"性能

    sess = ort.InferenceSession(str(MODEL), opts, providers=["CPUExecutionProvider"])
    inp_name = sess.get_inputs()[0].name
    print(f"  intra_op_num_threads: {opts.intra_op_num_threads or 'auto'}")
    print(f"  inter_op_num_threads: {opts.inter_op_num_threads or 'auto'}")

    proc = psutil.Process()
    mem_before = proc.memory_info().rss / 1024 / 1024  # MB
    print(f"  RSS before model load: {mem_before:.1f} MB")
    mem_after_load = proc.memory_info().rss / 1024 / 1024
    print(f"  RSS after  model load: {mem_after_load:.1f} MB (+{mem_after_load - mem_before:.1f})")

    # ── Warmup ──
    print(f"\n--- Warmup ({WARMUP}) ---")
    for _ in range(WARMUP):
        sess.run(None, {inp_name: inp})

    # ── Timed (with CPU sampling) ──
    print(f"\n--- Timed ({TIMED}) ---")
    times_ms = []
    proc.cpu_percent(interval=None)  # reset
    t_start = time.perf_counter()
    for _ in range(TIMED):
        t0 = time.perf_counter()
        sess.run(None, {inp_name: inp})
        t1 = time.perf_counter()
        times_ms.append((t1 - t0) * 1000.0)
    t_total = time.perf_counter() - t_start
    cpu_pct = proc.cpu_percent(interval=None)  # cumulative since reset

    mem_peak = proc.memory_info().rss / 1024 / 1024
    print(f"  RSS peak             : {mem_peak:.1f} MB")
    print(f"  Total wall time      : {t_total*1000:.1f} ms for {TIMED} runs")
    print(f"  Process CPU %        : {cpu_pct:.0f}% (cumulative,>100 = 多核)")

    times_ms.sort()
    print(f"\n  Latency per inference (ms):")
    print(f"    min   : {times_ms[0]:.2f}")
    print(f"    p50   : {statistics.median(times_ms):.2f}")
    print(f"    p90   : {times_ms[int(len(times_ms)*0.9)]:.2f}")
    print(f"    p99   : {times_ms[int(len(times_ms)*0.99)]:.2f}")
    print(f"    max   : {times_ms[-1]:.2f}")
    print(f"    mean  : {statistics.mean(times_ms):.2f}")
    print(f"    stdev : {statistics.stdev(times_ms):.2f}")

    fps = TIMED / t_total
    print(f"\n  Throughput: {fps:.1f} FPS (sustained,单线程串行 inference)")

    # ── 30 fps 摄像头能否实时 ──
    p99 = times_ms[int(len(times_ms) * 0.99)]
    target_ms = 1000 / 30  # 33.3ms
    if p99 <= target_ms:
        print(f"\n  ✅ 30fps 摄像头实时可行 (p99 {p99:.1f}ms <= 33.3ms)")
    elif p99 <= 100:
        print(f"\n  ⚠️  10fps OK,30fps 偶尔丢帧 (p99 {p99:.1f}ms)")
    else:
        print(f"\n  ❌ 30fps 不够,p99 {p99:.1f}ms,建议 GPU EP 或更小模型")


if __name__ == "__main__":
    main()
