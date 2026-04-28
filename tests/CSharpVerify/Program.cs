// 端到端验证 — 加载 *我们自己 build 的* OpenCvSharpExtern + onnxruntime native,
// OpenCvSharp 读图 + 画框 + 存 annotated PNG,ORT 推理融合模型,断言 face/phone/lens 三类都检出。
//
// 两个 native lib 在同一进程都被实际用上,作为下载前的硬门槛 — 双 lib 任何一个有问题都会暴露。
//
// 使用方式 (CI workflow 调用):
//   dotnet run --project tests/CSharpVerify -- <model.onnx> <test.png> [<output.png>]
//
// 失败任一断言 → exit 1 阻塞 CI

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using OpenCvSharp;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

const float FaceScoreThr = 0.5f;
const float FaceNmsIou = 0.4f;
const float ObjConfThr = 0.25f;
const float ObjNmsIou = 0.45f;
int[] strides = [8, 16, 32];
const int NumAnchors = 2;

string[] faceScoreNames = ["face_443", "face_468", "face_493"];
string[] faceBboxNames = ["face_446", "face_471", "face_496"];

// 期望:
const float ExpectFaceMin = 0.5f;
const float ExpectPhoneMin = 0.85f;
const float ExpectLensMin = 0.85f;

if (args.Length < 2)
{
    Console.Error.WriteLine("Usage: CSharpVerify <model.onnx> <test.png> [<output.png>]");
    return 1;
}
string modelPath = args[0];
string imgPath = args[1];
string outputPath = args.Length >= 3 ? args[2] : "annotated_output.png";

if (!File.Exists(modelPath)) { Console.Error.WriteLine($"::error::Model not found: {modelPath}"); return 1; }
if (!File.Exists(imgPath)) { Console.Error.WriteLine($"::error::Image not found: {imgPath}"); return 1; }

Console.WriteLine($"=== C# Verify (build 端到端测试) ===");
Console.WriteLine($"  ORT version: {OrtEnv.Instance().GetVersionString()}");
Console.WriteLine($"  Model: {modelPath}");
Console.WriteLine($"  Image: {imgPath}");
Console.WriteLine($"  Output: {outputPath}");

// ── OpenCvSharp 读图 ──
using var bgr = Cv2.ImRead(imgPath, ImreadModes.Color);
if (bgr.Empty()) { Console.Error.WriteLine("::error::OpenCvSharp ImRead failed"); return 1; }
Console.WriteLine($"  Image shape: {bgr.Rows}x{bgr.Cols}");

// ── Letterbox 到 640x640 + RGB + /255 + NCHW ──
const int ModelSize = 640;
int origH = bgr.Rows, origW = bgr.Cols;
float ratio = Math.Min((float)ModelSize / origH, (float)ModelSize / origW);
int nh = (int)Math.Round(origH * ratio);
int nw = (int)Math.Round(origW * ratio);
int padX = (ModelSize - nw) / 2;
int padY = (ModelSize - nh) / 2;

using var resized = new Mat();
Cv2.Resize(bgr, resized, new Size(nw, nh), 0, 0, InterpolationFlags.Linear);
using var letterboxed = new Mat();
Cv2.CopyMakeBorder(resized, letterboxed, padY, ModelSize - nh - padY, padX, ModelSize - nw - padX,
    BorderTypes.Constant, new Scalar(114, 114, 114));
using var rgbMat = new Mat();
Cv2.CvtColor(letterboxed, rgbMat, ColorConversionCodes.BGR2RGB);

// HWC u8 -> NCHW float [0,1]
float[] input = new float[3 * ModelSize * ModelSize];
unsafe
{
    byte* p = (byte*)rgbMat.DataPointer;
    int planeSize = ModelSize * ModelSize;
    for (int y = 0; y < ModelSize; y++)
        for (int x = 0; x < ModelSize; x++)
        {
            int idx = (y * ModelSize + x) * 3;
            input[0 * planeSize + y * ModelSize + x] = p[idx + 0] / 255f;
            input[1 * planeSize + y * ModelSize + x] = p[idx + 1] / 255f;
            input[2 * planeSize + y * ModelSize + x] = p[idx + 2] / 255f;
        }
}

// ── ORT 推理 ──
var sessOpts = new SessionOptions();
sessOpts.LogSeverityLevel = OrtLoggingLevel.ORT_LOGGING_LEVEL_ERROR;
using var sess = new InferenceSession(modelPath, sessOpts);

string inpName = sess.InputMetadata.Keys.First();
var inpTensor = new DenseTensor<float>(input, [1, 3, ModelSize, ModelSize]);
var inputs = new[] { NamedOnnxValue.CreateFromTensor(inpName, inpTensor) };
using var results = sess.Run(inputs);
var outMap = results.ToDictionary(r => r.Name, r => r.AsTensor<Float16>());

Console.WriteLine($"  Outputs: {string.Join(", ", outMap.Keys)}");

// ── helpers ──
record Det(float X1, float Y1, float X2, float Y2, float Score, int Cls);

// 把 letterboxed 坐标映射回原图
Det MapBack(Det d) => new(
    Math.Max(0, (d.X1 - padX) / ratio),
    Math.Max(0, (d.Y1 - padY) / ratio),
    Math.Min(origW - 1, (d.X2 - padX) / ratio),
    Math.Min(origH - 1, (d.Y2 - padY) / ratio),
    d.Score, d.Cls);

static List<Det> Nms(List<Det> dets, float iouThr)
{
    if (dets.Count == 0) return dets;
    var ordered = dets.OrderByDescending(d => d.Score).ToList();
    var keep = new List<Det>();
    while (ordered.Count > 0)
    {
        var top = ordered[0];
        keep.Add(top);
        ordered.RemoveAt(0);
        ordered.RemoveAll(o =>
        {
            float ix1 = Math.Max(top.X1, o.X1);
            float iy1 = Math.Max(top.Y1, o.Y1);
            float ix2 = Math.Min(top.X2, o.X2);
            float iy2 = Math.Min(top.Y2, o.Y2);
            float iw = Math.Max(0, ix2 - ix1);
            float ih = Math.Max(0, iy2 - iy1);
            float inter = iw * ih;
            float aT = (top.X2 - top.X1) * (top.Y2 - top.Y1);
            float aO = (o.X2 - o.X1) * (o.Y2 - o.Y1);
            float iou = inter / (aT + aO - inter + 1e-6f);
            return iou >= iouThr;
        });
    }
    return keep;
}

// ── Face decode (3 stride SCRFD) ──
Console.WriteLine($"\n--- Face decode ---");
var faceCands = new List<Det>();
for (int si = 0; si < strides.Length; si++)
{
    int stride = strides[si];
    int hw = ModelSize / stride;
    int K = hw * hw * NumAnchors;
    var s = outMap[faceScoreNames[si]].ToArray();
    var b = outMap[faceBboxNames[si]].ToArray();

    for (int i = 0; i < K; i++)
    {
        float score = (float)s[i];
        if (score < FaceScoreThr) continue;
        int row = i / NumAnchors / hw;
        int col = (i / NumAnchors) % hw;
        float cx = col * stride;
        float cy = row * stride;
        float dx1 = (float)b[i * 4 + 0] * stride;
        float dy1 = (float)b[i * 4 + 1] * stride;
        float dx2 = (float)b[i * 4 + 2] * stride;
        float dy2 = (float)b[i * 4 + 3] * stride;
        faceCands.Add(new Det(cx - dx1, cy - dy1, cx + dx2, cy + dy2, score, -1));  // cls=-1 表示 face
    }
}
var faceFinal = Nms(faceCands, FaceNmsIou).Select(MapBack).ToList();
float faceMaxScore = faceFinal.Count > 0 ? faceFinal.Max(d => d.Score) : 0f;
Console.WriteLine($"  Face candidates: {faceCands.Count}, after NMS: {faceFinal.Count}, max score: {faceMaxScore:F4}");

// ── Obj decode (obj_raw [N,8400,6] cxcywh + 2 class scores) ──
Console.WriteLine($"\n--- Obj decode ---");
var objRawTensor = outMap["obj_raw"];
int anchors = objRawTensor.Dimensions[1];  // 8400
var objArr = objRawTensor.ToArray();
var objCands = new List<Det>();
for (int i = 0; i < anchors; i++)
{
    float scorePhone = (float)objArr[i * 6 + 4];
    float scoreLens = (float)objArr[i * 6 + 5];
    float maxS = Math.Max(scorePhone, scoreLens);
    if (maxS < ObjConfThr) continue;
    int cls = scoreLens >= scorePhone ? 1 : 0;
    float cx = (float)objArr[i * 6 + 0];
    float cy = (float)objArr[i * 6 + 1];
    float w = (float)objArr[i * 6 + 2];
    float h = (float)objArr[i * 6 + 3];
    objCands.Add(new Det(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, maxS, cls));
}
// Per-class NMS
var phoneFinal = Nms(objCands.Where(d => d.Cls == 0).ToList(), ObjNmsIou).Select(MapBack).ToList();
var lensFinal = Nms(objCands.Where(d => d.Cls == 1).ToList(), ObjNmsIou).Select(MapBack).ToList();
float phoneMax = phoneFinal.Count > 0 ? phoneFinal.Max(d => d.Score) : 0f;
float lensMax = lensFinal.Count > 0 ? lensFinal.Max(d => d.Score) : 0f;
Console.WriteLine($"  Obj raw shape: [{string.Join(",", objRawTensor.Dimensions.ToArray())}]");
Console.WriteLine($"  Phone: cands={objCands.Count(d => d.Cls == 0)}, after NMS: {phoneFinal.Count}, max: {phoneMax:F4}");
Console.WriteLine($"  Lens : cands={objCands.Count(d => d.Cls == 1)}, after NMS: {lensFinal.Count}, max: {lensMax:F4}");

// ── OpenCvSharp 画框 + 存 annotated PNG ──
Console.WriteLine($"\n--- Draw + save annotated PNG ---");
using var annotated = bgr.Clone();
// 颜色 (BGR): face=绿,phone=蓝,lens=红
var faceColor = new Scalar(0, 255, 0);
var phoneColor = new Scalar(255, 128, 0);
var lensColor = new Scalar(0, 0, 255);

void DrawDet(Mat img, Det d, Scalar color, string label)
{
    var rect = new Rect((int)d.X1, (int)d.Y1, (int)(d.X2 - d.X1), (int)(d.Y2 - d.Y1));
    Cv2.Rectangle(img, rect, color, 3);
    var text = $"{label} {d.Score:F2}";
    var size = Cv2.GetTextSize(text, HersheyFonts.HersheyDuplex, 0.7, 2, out int baseline);
    var pt = new Point((int)d.X1, Math.Max(size.Height + 4, (int)d.Y1));
    Cv2.Rectangle(img, new Rect(pt.X, pt.Y - size.Height - baseline, size.Width + 4, size.Height + baseline + 4), color, -1);
    Cv2.PutText(img, text, new Point(pt.X + 2, pt.Y - 2), HersheyFonts.HersheyDuplex, 0.7, new Scalar(255, 255, 255), 2);
}

foreach (var d in faceFinal) DrawDet(annotated, d, faceColor, "face");
foreach (var d in phoneFinal) DrawDet(annotated, d, phoneColor, "phone");
foreach (var d in lensFinal) DrawDet(annotated, d, lensColor, "lens");

bool wroteOk = Cv2.ImWrite(outputPath, annotated);
if (!wroteOk) { Console.Error.WriteLine($"::error::Cv2.ImWrite failed: {outputPath}"); return 1; }
var fi = new FileInfo(outputPath);
Console.WriteLine($"  Saved annotated: {fi.FullName} ({fi.Length} bytes, {faceFinal.Count + phoneFinal.Count + lensFinal.Count} boxes drawn)");

// ── Assert ──
Console.WriteLine($"\n=== 验证结果 ===");
bool fail = false;
Console.Write($"  face : max {faceMaxScore:F4} (期望 >= {ExpectFaceMin}) ");
if (faceMaxScore < ExpectFaceMin) { Console.WriteLine("❌"); fail = true; }
else Console.WriteLine("✅");

Console.Write($"  phone: max {phoneMax:F4} (期望 >= {ExpectPhoneMin}) ");
if (phoneMax < ExpectPhoneMin) { Console.WriteLine("❌"); fail = true; }
else Console.WriteLine("✅");

Console.Write($"  lens : max {lensMax:F4} (期望 >= {ExpectLensMin}) ");
if (lensMax < ExpectLensMin) { Console.WriteLine("❌"); fail = true; }
else Console.WriteLine("✅");

if (fail)
{
    Console.Error.WriteLine($"\n::error::C# 端到端验证失败 — OpenCvSharp + ORT native build 输出不达标");
    return 1;
}
Console.WriteLine($"\n🎉 C# end-to-end OK — OpenCvSharp 画框 + ORT 推理 (我们自己 build 的) 全部工作");
return 0;
