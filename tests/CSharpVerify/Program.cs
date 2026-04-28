// 端到端验证 — *我们自己 build 的* OpenCvSharpExtern (精简版,只 core/imgproc/videoio)
// + onnxruntime native。
//
// production 流程: 摄像头帧 (videoio) → Mat (CV_8UC3 BGR) → 模型推理 → Mat 画框
// 测试流程:        预解码 test.bgr (raw BGR bytes) → Mat → 模型推理 → Mat 画框
//                  → 写 annotated.bgr → CI Python 反编码成 PNG 给人肉眼看
//
// *不* 用 Cv2.ImRead/ImWrite (imgcodecs 没编进去) — 跟 production 一致。
//
// 验证维度:
//   1. ORT native lib 加载 + 推理输出符合期望分数 (face/phone/lens)
//   2. OpenCvSharp imgproc 全套调用通过 (Resize/CopyMakeBorder/CvtColor)
//   3. 画框 (Cv2.Rectangle/PutText) 实际改了像素 — 抽样验证 box 区域颜色
//
// 用法:
//   CSharpVerify <model.onnx> <test.bgr> [<output.bgr>]

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using OpenCvSharp;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

// ── 强制从 app 目录 (AppContext.BaseDirectory) 加载 native lib ──
// 默认 .NET P/Invoke 在 macOS 上有时会优先搜 dotnet host 目录或系统路径,
// 导致客户机加载错的 onnxruntime/OpenCvSharpExtern。统一注册 resolver 锁定 app 目录。
// 这是 production 客户也应该用的模式,确保 ship 给客户的 deploy/<platform>/* 真被加载。
NativeLibrary.SetDllImportResolver(typeof(OrtEnv).Assembly, AppDirResolver);
NativeLibrary.SetDllImportResolver(typeof(Cv2).Assembly, AppDirResolver);

static IntPtr AppDirResolver(string libraryName, Assembly asm, DllImportSearchPath? path)
{
    string baseDir = AppContext.BaseDirectory;
    string ext = OperatingSystem.IsWindows() ? ".dll"
               : OperatingSystem.IsMacOS()   ? ".dylib"
               :                                ".so";
    string prefix = OperatingSystem.IsWindows() ? "" : "lib";
    // 试两种命名:libxxx.so + xxx.so (Windows 不带 lib 前缀)
    foreach (var candidate in new[] { Path.Combine(baseDir, prefix + libraryName + ext),
                                      Path.Combine(baseDir, libraryName + ext) })
    {
        if (File.Exists(candidate))
        {
            Console.WriteLine($"  [resolver] {libraryName} → {candidate}");
            return NativeLibrary.Load(candidate);
        }
    }
    return IntPtr.Zero;  // fallback to default search
}

const float FaceScoreThr = 0.5f;
const float FaceNmsIou = 0.4f;
const float ObjConfThr = 0.25f;
const float ObjNmsIou = 0.45f;
int[] strides = [8, 16, 32];
const int NumAnchors = 2;

string[] faceScoreNames = ["face_443", "face_468", "face_493"];
string[] faceBboxNames = ["face_446", "face_471", "face_496"];

const float ExpectFaceMin = 0.5f;
const float ExpectPhoneMin = 0.85f;
const float ExpectLensMin = 0.85f;

if (args.Length < 2)
{
    Console.Error.WriteLine("Usage: CSharpVerify <model.onnx> <test.bgr> [<output.bgr>]");
    return 1;
}
string modelPath = args[0];
string bgrPath = args[1];
string outputPath = args.Length >= 3 ? args[2] : "annotated_output.bgr";

if (!File.Exists(modelPath)) { Console.Error.WriteLine($"::error::Model not found: {modelPath}"); return 1; }
if (!File.Exists(bgrPath)) { Console.Error.WriteLine($"::error::BGR file not found: {bgrPath}"); return 1; }

Console.WriteLine($"=== C# Verify (build 端到端测试) ===");
Console.WriteLine($"  ORT version: {OrtEnv.Instance().GetVersionString()}");
Console.WriteLine($"  Model: {modelPath}");
Console.WriteLine($"  BGR  : {bgrPath}");
Console.WriteLine($"  Out  : {outputPath}");

// ── 读 raw BGR bytes,构 Mat (跟 production 拿摄像头帧 → Mat 等价) ──
byte[] raw = File.ReadAllBytes(bgrPath);
if (raw.Length < 9) { Console.Error.WriteLine("::error::BGR header too short"); return 1; }
int origW = BitConverter.ToInt32(raw, 0);
int origH = BitConverter.ToInt32(raw, 4);
int channels = raw[8];
if (channels != 3) { Console.Error.WriteLine($"::error::Expected 3 channels, got {channels}"); return 1; }
int expectedBytes = 9 + origW * origH * channels;
if (raw.Length != expectedBytes) { Console.Error.WriteLine($"::error::BGR size mismatch: hdr says {origW}x{origH}x{channels}, expect {expectedBytes} bytes, got {raw.Length}"); return 1; }
Console.WriteLine($"  Image: {origH}x{origW}x{channels}");

// 把 raw[9..] 直接拷到 Mat (CV_8UC3 内存布局 = HxWx3 行连续 BGR,跟我们的格式完全一致)
using var bgr = new Mat(origH, origW, MatType.CV_8UC3);
unsafe
{
    fixed (byte* srcPtr = &raw[9])
    {
        Buffer.MemoryCopy(srcPtr, (void*)bgr.DataPointer, origW * origH * 3, origW * origH * 3);
    }
}

// ── Letterbox 到 640x640 + RGB + /255 + NCHW (纯 imgproc) ──
const int ModelSize = 640;
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

// HWC u8 → NCHW float [0,1]
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
// ORT 1.25 内部 NhwcTransformer 把 opset-11 MaxPool 转成 com.ms.internal.nhwc.MaxPool,
// 但 NHWC kernel 只注册了 opset >=12,linux-arm64 上触发 NotImplemented。
// 用 ORT_ENABLE_BASIC 跳掉这个 transformer (不会丢精度,只是少做些重写优化)。
sessOpts.GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_BASIC;
using var sess = new InferenceSession(modelPath, sessOpts);

string inpName = sess.InputMetadata.Keys.First();
var inpTensor = new DenseTensor<float>(input, [1, 3, ModelSize, ModelSize]);
var inputs = new[] { NamedOnnxValue.CreateFromTensor(inpName, inpTensor) };
using var results = sess.Run(inputs);

// 输出 dtype 可能是 Float16 (obj_raw 必定 fp16) 或 float (face 头 ORT 有时反向出 fp32)
// 统一转成 float[],下游一律按 float 处理。同时记录每个输出的 shape (face decode 不需,
// 但 obj_raw 解码需要 anchors 数,从 metadata 拿)。
var outMap = new Dictionary<string, float[]>();
var outShapes = new Dictionary<string, int[]>();
foreach (var r in results)
{
    var f16 = r.AsTensor<Float16>();
    if (f16 != null)
    {
        var arr = f16.ToArray();
        var floats = new float[arr.Length];
        for (int i = 0; i < arr.Length; i++) floats[i] = (float)arr[i];
        outMap[r.Name] = floats;
        outShapes[r.Name] = f16.Dimensions.ToArray();
        continue;
    }
    var f32 = r.AsTensor<float>();
    if (f32 != null)
    {
        outMap[r.Name] = f32.ToArray();
        outShapes[r.Name] = f32.Dimensions.ToArray();
        continue;
    }
    Console.Error.WriteLine($"::error::Unsupported tensor type for output '{r.Name}'");
    return 1;
}

Console.WriteLine($"  Outputs: {string.Join(", ", outMap.Keys)}");

// ── helpers ──
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
    var s = outMap[faceScoreNames[si]];
    var b = outMap[faceBboxNames[si]];

    for (int i = 0; i < K; i++)
    {
        float score = s[i];
        if (score < FaceScoreThr) continue;
        int row = i / NumAnchors / hw;
        int col = (i / NumAnchors) % hw;
        float cx = col * stride;
        float cy = row * stride;
        float dx1 = b[i * 4 + 0] * stride;
        float dy1 = b[i * 4 + 1] * stride;
        float dx2 = b[i * 4 + 2] * stride;
        float dy2 = b[i * 4 + 3] * stride;
        faceCands.Add(new Det(cx - dx1, cy - dy1, cx + dx2, cy + dy2, score, -1));
    }
}
var faceFinal = Nms(faceCands, FaceNmsIou).Select(MapBack).ToList();
float faceMaxScore = faceFinal.Count > 0 ? faceFinal.Max(d => d.Score) : 0f;
Console.WriteLine($"  Face cands: {faceCands.Count}, after NMS: {faceFinal.Count}, max: {faceMaxScore:F4}");

// ── Obj decode (obj_raw [N,8400,6]) ──
Console.WriteLine($"\n--- Obj decode ---");
var objArr = outMap["obj_raw"];
var objShape = outShapes["obj_raw"];
int anchors = objShape[1];
var objCands = new List<Det>();
for (int i = 0; i < anchors; i++)
{
    float scorePhone = objArr[i * 6 + 4];
    float scoreLens = objArr[i * 6 + 5];
    float maxS = Math.Max(scorePhone, scoreLens);
    if (maxS < ObjConfThr) continue;
    int cls = scoreLens >= scorePhone ? 1 : 0;
    float cx = objArr[i * 6 + 0];
    float cy = objArr[i * 6 + 1];
    float w = objArr[i * 6 + 2];
    float h = objArr[i * 6 + 3];
    objCands.Add(new Det(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, maxS, cls));
}
var phoneFinal = Nms(objCands.Where(d => d.Cls == 0).ToList(), ObjNmsIou).Select(MapBack).ToList();
var lensFinal = Nms(objCands.Where(d => d.Cls == 1).ToList(), ObjNmsIou).Select(MapBack).ToList();
float phoneMax = phoneFinal.Count > 0 ? phoneFinal.Max(d => d.Score) : 0f;
float lensMax = lensFinal.Count > 0 ? lensFinal.Max(d => d.Score) : 0f;
Console.WriteLine($"  Obj raw shape: [{string.Join(",", objShape)}]");
Console.WriteLine($"  Phone: cands={objCands.Count(d => d.Cls == 0)}, NMS: {phoneFinal.Count}, max: {phoneMax:F4}");
Console.WriteLine($"  Lens : cands={objCands.Count(d => d.Cls == 1)}, NMS: {lensFinal.Count}, max: {lensMax:F4}");

// ── OpenCvSharp 画框 + 验证像素改了 ──
Console.WriteLine($"\n--- Draw boxes (Cv2.Rectangle/PutText) ---");
using var annotated = bgr.Clone();
var faceColor = new Scalar(0, 255, 0);    // BGR 绿
var phoneColor = new Scalar(255, 128, 0); // BGR 橙
var lensColor = new Scalar(0, 0, 255);    // BGR 红

// 在边框上的一个点取样,验证画框真的改了像素 (而不是 Cv2.Rectangle 静默无操作)
List<(string label, Det d, Scalar color)> drawSamples = new();

void DrawDet(Mat img, Det d, Scalar color, string label)
{
    var rect = new Rect((int)d.X1, (int)d.Y1, (int)(d.X2 - d.X1), (int)(d.Y2 - d.Y1));
    Cv2.Rectangle(img, rect, color, 3);
    var text = $"{label} {d.Score:F2}";
    var size = Cv2.GetTextSize(text, HersheyFonts.HersheyDuplex, 0.7, 2, out int baseline);
    var pt = new Point((int)d.X1, Math.Max(size.Height + 4, (int)d.Y1));
    Cv2.Rectangle(img, new Rect(pt.X, pt.Y - size.Height - baseline, size.Width + 4, size.Height + baseline + 4), color, -1);
    Cv2.PutText(img, text, new Point(pt.X + 2, pt.Y - 2), HersheyFonts.HersheyDuplex, 0.7, new Scalar(255, 255, 255), 2);
    drawSamples.Add((label, d, color));
}

foreach (var d in faceFinal) DrawDet(annotated, d, faceColor, "face");
foreach (var d in phoneFinal) DrawDet(annotated, d, phoneColor, "phone");
foreach (var d in lensFinal) DrawDet(annotated, d, lensColor, "lens");

// 抽样验证: 边框上的像素应该跟 expected color 一致 (边框线 thickness=3,中心点像素 = color)
int drawVerifiedCount = 0;
int drawTotalCount = drawSamples.Count;
foreach (var (label, d, color) in drawSamples)
{
    // 取边框顶部中点 (filled label rect 是顶部矩形,会覆盖,这里取右边框中点更稳)
    int sx = Math.Min(origW - 1, Math.Max(0, (int)d.X2 - 1));
    int sy = Math.Max(0, Math.Min(origH - 1, (int)((d.Y1 + d.Y2) / 2)));
    var pixel = annotated.At<Vec3b>(sy, sx);
    bool match = Math.Abs(pixel.Item0 - color.Val0) < 30 &&
                 Math.Abs(pixel.Item1 - color.Val1) < 30 &&
                 Math.Abs(pixel.Item2 - color.Val2) < 30;
    Console.WriteLine($"  {label} sampled ({sx},{sy}) BGR=({pixel.Item0},{pixel.Item1},{pixel.Item2}) expect~({color.Val0},{color.Val1},{color.Val2}) {(match ? "✅" : "❌")}");
    if (match) drawVerifiedCount++;
}

// ── 写 annotated.bgr (CI Python 反编码成 PNG 上传) ──
unsafe
{
    using var fs = new FileStream(outputPath, FileMode.Create);
    fs.Write(BitConverter.GetBytes(origW));
    fs.Write(BitConverter.GetBytes(origH));
    fs.WriteByte(3);
    byte[] buf = new byte[origW * origH * 3];
    fixed (byte* dstPtr = buf)
    {
        Buffer.MemoryCopy((void*)annotated.DataPointer, dstPtr, buf.Length, buf.Length);
    }
    fs.Write(buf);
}
var fi = new FileInfo(outputPath);
Console.WriteLine($"  Wrote {outputPath} ({fi.Length} bytes)");

// ── Assert ──
Console.WriteLine($"\n=== 验证结果 ===");
bool fail = false;
Console.Write($"  face : max {faceMaxScore:F4} (期望 >= {ExpectFaceMin}) ");
if (faceMaxScore < ExpectFaceMin) { Console.WriteLine("❌"); fail = true; } else Console.WriteLine("✅");

Console.Write($"  phone: max {phoneMax:F4} (期望 >= {ExpectPhoneMin}) ");
if (phoneMax < ExpectPhoneMin) { Console.WriteLine("❌"); fail = true; } else Console.WriteLine("✅");

Console.Write($"  lens : max {lensMax:F4} (期望 >= {ExpectLensMin}) ");
if (lensMax < ExpectLensMin) { Console.WriteLine("❌"); fail = true; } else Console.WriteLine("✅");

Console.Write($"  draw : {drawVerifiedCount}/{drawTotalCount} 边框像素颜色匹配 ");
if (drawTotalCount > 0 && drawVerifiedCount < drawTotalCount) { Console.WriteLine("❌"); fail = true; }
else if (drawTotalCount == 0) { Console.WriteLine("⚠️ no boxes to draw"); fail = true; }
else { Console.WriteLine("✅"); }

if (fail)
{
    Console.Error.WriteLine($"\n::error::C# 端到端验证失败 — OpenCvSharp + ORT native build 输出不达标");
    return 1;
}
Console.WriteLine($"\n🎉 C# end-to-end OK — OpenCvSharp imgproc + ORT 推理 (我们自己 build 的) 全部工作");
return 0;

// ── Type declarations (must come AFTER top-level statements per C# rules) ──
record Det(float X1, float Y1, float X2, float Y2, float Score, int Cls);
