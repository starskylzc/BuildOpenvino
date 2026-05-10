"""跑融合模型在原生 OpenVINO CPU runtime 上的速度,对比 ORT CPU EP。

OpenVINO CPU plugin = Intel 自家深度优化:
  - oneDNN kernel (ORT CPU EP 也用,但 OV 集成更深)
  - 自动 BF16 (Intel Sapphire Rapids+) / FP16 (ARM bf16)
  - 自动算子融合 (比 ORT GraphOptimizer 更激进)

PyPI openvino 全平台 wheel:
  - Linux x64 / aarch64
  - macOS x64 / arm64
  - Windows x64

直接读 ONNX (不用 mo 转 IR), CPU device.
"""
import os
import sys
import time
import statistics
import platform
from pathlib import Path

import numpy as np
import psutil
from PIL import Image

HERE = Path(__file__).resolve().parent
MODEL = HERE / "merged_no_topk_fp16.onnx"
PNG = HERE / "test.png"
WARMUP = 10
TIMED = 100


def load_image_as_nchw():
    img = Image.open(PNG).convert("RGB")
    target = 640
    w, h = img.size
    r = min(target / h, target / w)
    nh, nw = int(round(h * r)), int(round(w * r))
    img2 = img.resize((nw, nh), Image.BILINEAR)
    canvas = Image.new("RGB", (target, target), (114, 114, 114))
    canvas.paste(img2, ((target - nw) // 2, (target - nh) // 2))
    arr = np.frombuffer(canvas.tobytes(), dtype=np.uint8).reshape(target, target, 3)
    nchw = arr.transpose(2, 0, 1).astype(np.float32) / 255.0
    return nchw[None, ...]  # [1,3,640,640]


def bench_openvino(inp):
    import openvino as ov
    print(f"\n=== Native OpenVINO CPU runtime ===")
    print(f"  OpenVINO version: {ov.__version__}")

    core = ov.Core()
    print(f"  Devices: {core.available_devices}")
    if "CPU" not in core.available_devices:
        print("::error::No CPU device in OpenVINO")
        return None

    # CPU 配置:让 OV 自己选最佳并行度 + 启用所有 优化
    # PERFORMANCE_HINT=LATENCY 单帧延迟最低 (默认 THROUGHPUT 是批量优先)
    config = {"PERFORMANCE_HINT": "LATENCY"}
    cm = core.compile_model(str(MODEL), "CPU", config)

    inp_name = cm.inputs[0].any_name
    print(f"  Input  : {inp_name} {cm.inputs[0].shape}")
    print(f"  Outputs: {[o.any_name for o in cm.outputs]}")

    proc = psutil.Process()
    mem_before = proc.memory_info().rss / 1024 / 1024

    print(f"\n--- Warmup ({WARMUP}) ---")
    for _ in range(WARMUP):
        cm({inp_name: inp})

    proc.cpu_percent(interval=None)
    times_ms = []
    t_start = time.perf_counter()
    for _ in range(TIMED):
        t0 = time.perf_counter()
        cm({inp_name: inp})
        t1 = time.perf_counter()
        times_ms.append((t1 - t0) * 1000.0)
    t_total = time.perf_counter() - t_start
    cpu_pct = proc.cpu_percent(interval=None)
    mem_peak = proc.memory_info().rss / 1024 / 1024

    times_ms.sort()
    return {
        "engine": "OpenVINO",
        "min": times_ms[0], "p50": statistics.median(times_ms),
        "p90": times_ms[int(len(times_ms)*0.9)],
        "p99": times_ms[int(len(times_ms)*0.99)],
        "max": times_ms[-1], "mean": statistics.mean(times_ms),
        "stdev": statistics.stdev(times_ms),
        "fps": TIMED / t_total,
        "mem_peak_mb": mem_peak,
        "mem_before_mb": mem_before,
        "cpu_pct": cpu_pct,
    }


def bench_ort(inp):
    import onnxruntime as ort
    print(f"\n=== ORT CPU EP (对比 baseline) ===")
    print(f"  ORT version: {ort.__version__}")
    opts = ort.SessionOptions()
    opts.log_severity_level = 3
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
    sess = ort.InferenceSession(str(MODEL), opts, providers=["CPUExecutionProvider"])
    inp_name = sess.get_inputs()[0].name

    proc = psutil.Process()
    mem_before = proc.memory_info().rss / 1024 / 1024

    for _ in range(WARMUP):
        sess.run(None, {inp_name: inp})

    proc.cpu_percent(interval=None)
    times_ms = []
    t_start = time.perf_counter()
    for _ in range(TIMED):
        t0 = time.perf_counter()
        sess.run(None, {inp_name: inp})
        t1 = time.perf_counter()
        times_ms.append((t1 - t0) * 1000.0)
    t_total = time.perf_counter() - t_start
    cpu_pct = proc.cpu_percent(interval=None)
    mem_peak = proc.memory_info().rss / 1024 / 1024

    times_ms.sort()
    return {
        "engine": "ORT-CPU",
        "min": times_ms[0], "p50": statistics.median(times_ms),
        "p90": times_ms[int(len(times_ms)*0.9)],
        "p99": times_ms[int(len(times_ms)*0.99)],
        "max": times_ms[-1], "mean": statistics.mean(times_ms),
        "stdev": statistics.stdev(times_ms),
        "fps": TIMED / t_total,
        "mem_peak_mb": mem_peak,
        "mem_before_mb": mem_before,
        "cpu_pct": cpu_pct,
    }


def main():
    print(f"Platform   : {platform.system()} {platform.machine()}")
    print(f"CPU count  : {psutil.cpu_count(logical=False)} physical / {psutil.cpu_count(logical=True)} logical")
    inp = load_image_as_nchw()
    print(f"Input shape: {inp.shape}")

    r_ort = bench_ort(inp)
    r_ov = bench_openvino(inp)

    print(f"\n=== 对比 (FP16 模型,无量化) ===")
    print(f"  {'Engine':<12} {'p50 ms':>8} {'p99 ms':>8} {'mean ms':>8} {'FPS':>6} {'CPU %':>6} {'RSS MB':>8}")
    for r in [r_ort, r_ov]:
        if r is None:
            continue
        print(f"  {r['engine']:<12} {r['p50']:>8.1f} {r['p99']:>8.1f} {r['mean']:>8.1f} {r['fps']:>6.1f} {r['cpu_pct']:>6.0f} {r['mem_peak_mb']:>8.1f}")

    if r_ov and r_ort:
        speedup = r_ort["p50"] / r_ov["p50"]
        print(f"\n  OpenVINO 相对 ORT CPU EP 速度比: {speedup:.2f}x")
        if r_ov["p99"] <= 33.3:
            print(f"  ✅ OpenVINO p99 {r_ov['p99']:.1f}ms 满足 30fps 实时")
        elif r_ov["p99"] <= 66.7:
            print(f"  ⚠️  OpenVINO p99 {r_ov['p99']:.1f}ms 满足 15fps")
        elif r_ov["p99"] <= 100:
            print(f"  ⚠️  OpenVINO p99 {r_ov['p99']:.1f}ms 满足 10fps")
        else:
            print(f"  ❌ OpenVINO p99 {r_ov['p99']:.1f}ms <10fps,CPU 路线天花板")


if __name__ == "__main__":
    main()
