"""End-to-end verification — 融合模型 FP16 在 test.png 上的检测结果跟期望一致。

每个 CI 平台 (Win x64 / Mac x64 / Mac arm64 / Linux x64 / Linux arm64) 跑这个脚本,
输入: tests/merged_no_topk_fp16.onnx + tests/test.png
期望: 1 个 face (score >= 0.5), 1 个 phone (score >= 0.85), 1 个 lens (score >= 0.85)
任一缺失 → exit 1, 阻塞 CI。

证明:
  1. 我们 ONNX surgery 后的模型在所有平台 ORT 1.25 都能正常加载推理
  2. 输出 face_xxx + obj_raw 张量结构跟 C# FusedDetector 解码逻辑对齐
  3. test.png 上的 phone+lens+face 三类目标都能稳定检出
"""
import sys
import os
from pathlib import Path
import numpy as np
import cv2
import onnxruntime as ort

HERE = Path(__file__).resolve().parent
MODEL = str(HERE / "merged_no_topk_fp16.onnx")
IMG = str(HERE / "test.png")

# 期望检测结果 (基于本地 CPU EP 验证,所有平台应一致到 ±0.05)
EXPECTED = {
    "face": {"min_score": 0.50},
    "phone": {"min_score": 0.85},
    "lens": {"min_score": 0.85},
}

OBJ_CONF_THR = 0.25
OBJ_IOU_THR = 0.45
FACE_SCORE_THR = 0.5
FACE_NMS_IOU = 0.4
STRIDES = [8, 16, 32]
NUM_ANCHORS = 2

OBJ_CLASS_NAMES = {0: "phone", 1: "lens"}


# ── 预处理 ──
def letterbox(img, size=640, color=(114, 114, 114)):
    h, w = img.shape[:2]
    r = min(size / h, size / w)
    nh, nw = int(round(h * r)), int(round(w * r))
    resized = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR)
    pl = (size - nw) // 2
    pt = (size - nh) // 2
    out = cv2.copyMakeBorder(
        resized, pt, size - nh - pt, pl, size - nw - pl,
        cv2.BORDER_CONSTANT, value=color,
    )
    return out, r, (pl, pt)


def preprocess(bgr):
    lb, r, pad = letterbox(bgr, 640)
    rgb = cv2.cvtColor(lb, cv2.COLOR_BGR2RGB)
    chw = rgb.transpose(2, 0, 1).astype(np.float32) / 255.0
    return chw[None, ...], r, pad


# ── 解码 ──
def decode_scrfd(scores, bboxes, kps, stride):
    h = w = 640 // stride
    K = h * w * NUM_ANCHORS
    yy, xx = np.mgrid[:h, :w]
    centers = np.stack([xx, yy], axis=-1).reshape(-1, 2)
    centers = np.repeat(centers, NUM_ANCHORS, axis=0).astype(np.float32) * stride
    scores = scores.flatten()
    bboxes = bboxes.reshape(K, 4) * stride
    keep = scores >= FACE_SCORE_THR
    if not keep.any():
        return np.zeros((0, 5), np.float32)
    cx = centers[keep, 0]; cy = centers[keep, 1]
    bb = bboxes[keep]
    x1 = cx - bb[:, 0]; y1 = cy - bb[:, 1]
    x2 = cx + bb[:, 2]; y2 = cy + bb[:, 3]
    return np.stack([x1, y1, x2, y2, scores[keep]], axis=1)


def nms(dets, iou_thr):
    if len(dets) == 0:
        return dets
    boxes = dets[:, :4]; scores = dets[:, 4]
    order = scores.argsort()[::-1]
    keep = []
    while len(order):
        i = order[0]; keep.append(i)
        if len(order) == 1: break
        xx1 = np.maximum(boxes[i, 0], boxes[order[1:], 0])
        yy1 = np.maximum(boxes[i, 1], boxes[order[1:], 1])
        xx2 = np.minimum(boxes[i, 2], boxes[order[1:], 2])
        yy2 = np.minimum(boxes[i, 3], boxes[order[1:], 3])
        inter = np.maximum(0, xx2 - xx1) * np.maximum(0, yy2 - yy1)
        a_i = (boxes[i, 2] - boxes[i, 0]) * (boxes[i, 3] - boxes[i, 1])
        a_o = (boxes[order[1:], 2] - boxes[order[1:], 0]) * (boxes[order[1:], 3] - boxes[order[1:], 1])
        iou = inter / (a_i + a_o - inter + 1e-6)
        order = order[1:][iou < iou_thr]
    return dets[keep]


def decode_obj_raw(obj_raw, conf_thr=OBJ_CONF_THR, iou_thr=OBJ_IOU_THR):
    arr = obj_raw[0].astype(np.float32)
    cxcywh = arr[:, :4]
    cx, cy, w, h = cxcywh[:, 0], cxcywh[:, 1], cxcywh[:, 2], cxcywh[:, 3]
    boxes = np.stack([cx - w/2, cy - h/2, cx + w/2, cy + h/2], axis=1)
    class_scores = arr[:, 4:6]
    scores = class_scores.max(axis=1)
    cls_ids = class_scores.argmax(axis=1)
    keep = scores >= conf_thr
    if not keep.any():
        return [], []
    boxes = boxes[keep]; scores = scores[keep]; cls_ids = cls_ids[keep]
    out_boxes, out_scores, out_cls = [], [], []
    for c in np.unique(cls_ids):
        mask = cls_ids == c
        b = boxes[mask]; s = scores[mask]
        order = s.argsort()[::-1]
        kept = []
        while len(order):
            i = order[0]; kept.append(i)
            if len(order) == 1: break
            xx1 = np.maximum(b[i, 0], b[order[1:], 0])
            yy1 = np.maximum(b[i, 1], b[order[1:], 1])
            xx2 = np.minimum(b[i, 2], b[order[1:], 2])
            yy2 = np.minimum(b[i, 3], b[order[1:], 3])
            inter = np.maximum(0, xx2 - xx1) * np.maximum(0, yy2 - yy1)
            a_i = (b[i, 2] - b[i, 0]) * (b[i, 3] - b[i, 1])
            a_o = (b[order[1:], 2] - b[order[1:], 0]) * (b[order[1:], 3] - b[order[1:], 1])
            iou = inter / (a_i + a_o - inter + 1e-6)
            order = order[1:][iou < iou_thr]
        for i in kept:
            out_boxes.append(b[i]); out_scores.append(s[i]); out_cls.append(int(c))
    return out_boxes, out_scores, out_cls


def main():
    print(f"=== Verify Fused Model ===")
    print(f"  ORT version: {ort.__version__}")
    print(f"  Available providers: {ort.get_available_providers()}")
    print(f"  Model: {MODEL}")
    print(f"  Image: {IMG}")

    if not Path(MODEL).exists():
        print(f"::error::Model file not found: {MODEL}")
        sys.exit(1)
    if not Path(IMG).exists():
        print(f"::error::Test image not found: {IMG}")
        sys.exit(1)

    # ORT session — 用 CPU EP 跨平台一致
    opts = ort.SessionOptions()
    opts.log_severity_level = 3
    # ORT_ENABLE_BASIC 跳过 NhwcTransformer (linux-arm64 PyPI wheel 的 NHWC MaxPool
    # opset 11 kernel 缺,默认 ORT_ENABLE_ALL 会触发 NotImplemented 报错)
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
    sess = ort.InferenceSession(MODEL, opts, providers=["CPUExecutionProvider"])
    print(f"  Active EP: {sess.get_providers()}")

    img = cv2.imread(IMG)
    if img is None:
        print(f"::error::Failed to read image (cv2 returned None)")
        sys.exit(1)
    print(f"  Image shape: {img.shape}")

    x, ratio, pad = preprocess(img)
    inp_name = sess.get_inputs()[0].name
    outputs = sess.run(None, {inp_name: x})
    out_names = [o.name for o in sess.get_outputs()]
    out_map = dict(zip(out_names, outputs))

    # ── Face decode ──
    print(f"\n--- Face decode ---")
    face_score_names = ["face_443", "face_468", "face_493"]
    face_bbox_names = ["face_446", "face_471", "face_496"]
    face_kps_names = ["face_449", "face_474", "face_499"]
    all_faces = []
    for s_name, b_name, k_name, stride in zip(face_score_names, face_bbox_names, face_kps_names, STRIDES):
        s = out_map[s_name].astype(np.float32)
        b = out_map[b_name].astype(np.float32)
        k = out_map[k_name].astype(np.float32)
        dets = decode_scrfd(s, b, k, stride)
        if len(dets):
            all_faces.append(dets)
    all_faces = np.concatenate(all_faces, axis=0) if all_faces else np.zeros((0, 5), np.float32)
    if len(all_faces):
        all_faces = nms(all_faces, FACE_NMS_IOU)
    print(f"  Face detections: {len(all_faces)}")
    for d in all_faces:
        print(f"    score={d[4]:.4f}")
    face_max_score = float(all_faces[:, 4].max()) if len(all_faces) else 0.0

    # ── Obj decode ──
    print(f"\n--- Obj decode ---")
    obj_raw = out_map["obj_raw"]
    print(f"  obj_raw shape: {obj_raw.shape}, dtype: {obj_raw.dtype}")
    boxes, scores, cls_ids = decode_obj_raw(obj_raw)
    print(f"  Obj detections: {len(boxes)}")
    phone_max = 0.0
    lens_max = 0.0
    for b, s, c in zip(boxes, scores, cls_ids):
        cls_name = OBJ_CLASS_NAMES.get(c, f"cls_{c}")
        print(f"    {cls_name:6s} score={s:.4f}")
        if c == 0 and s > phone_max:
            phone_max = float(s)
        if c == 1 and s > lens_max:
            lens_max = float(s)

    # ── Assert ──
    print(f"\n=== 验证结果 ===")
    fail = False
    print(f"  face : max score {face_max_score:.4f} (期望 >= {EXPECTED['face']['min_score']})", end="")
    if face_max_score < EXPECTED["face"]["min_score"]:
        print(" ❌")
        fail = True
    else:
        print(" ✅")

    print(f"  phone: max score {phone_max:.4f} (期望 >= {EXPECTED['phone']['min_score']})", end="")
    if phone_max < EXPECTED["phone"]["min_score"]:
        print(" ❌")
        fail = True
    else:
        print(" ✅")

    print(f"  lens : max score {lens_max:.4f} (期望 >= {EXPECTED['lens']['min_score']})", end="")
    if lens_max < EXPECTED["lens"]["min_score"]:
        print(" ❌")
        fail = True
    else:
        print(" ✅")

    if fail:
        print(f"\n::error::模型推理结果不达标,无法部署到客户端")
        sys.exit(1)
    print(f"\n🎉 All passed,模型在 {sys.platform} {os.uname().machine if hasattr(os, 'uname') else ''} 上输出符合预期")


if __name__ == "__main__":
    main()
