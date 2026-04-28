// 端到端验证 — 加载 *我们自己 build 的* OpenCvSharpExtern + onnxruntime native,
// 用 OpenCvSharp 读 test.png,送进 ORT 跑融合模型,断言 face/phone/lens 三类都检出。
//
// 使用方式 (CI workflow 调用):
//   dotnet run --project tests/CSharpVerify -- <model.onnx> <test.png>
//
// 失败任一断言 → exit 1 阻塞 CI

using System;
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
    Console.Error.WriteLine("Usage: CSharpVerify <model.onnx> <test.png>");
    return 1;
}
string modelPath = args[0];
string imgPath = args[1];

if (!File.Exists(modelPath)) { Console.Error.WriteLine($"::error::Model not found: {modelPath}"); return 1; }
if (!File.Exists(imgPath)) { Console.Error.WriteLine($"::error::Image not found: {imgPath}"); return 1; }

Console.WriteLine($"=== C# Verify (build 端到端测试) ===");
Console.WriteLine($"  ORT version: {OrtEnv.Instance().GetVersionString()}");
Console.WriteLine($"  Model: {modelPath}");
Console.WriteLine($"  Image: {imgPath}");

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
using var rgb = new Mat();
Cv2.CvtColor(letterboxed, rgb, ColorConversionCodes.BGR2RGB);

// HWC u8 -> NCHW float [0,1]
float[] input = new float[3 * ModelSize * ModelSize];
unsafe
{
    byte* p = (byte*)rgb.DataPointer;
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

// ── Face decode (3 stride SCRFD) ──
Console.WriteLine($"\n--- Face decode ---");
float faceMaxScore = 0f;
var faceCands = new System.Collections.Generic.List<(float x1, float y1, float x2, float y2, float score)>();
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
        faceCands.Add((cx - dx1, cy - dy1, cx + dx2, cy + dy2, score));
        if (score > faceMaxScore) faceMaxScore = score;
    }
}
Console.WriteLine($"  Face candidates >= {FaceScoreThr}: {faceCands.Count}, max score: {faceMaxScore:F4}");

// ── Obj decode (obj_raw [N,8400,6]) ──
Console.WriteLine($"\n--- Obj decode ---");
var objRawTensor = outMap["obj_raw"];
int anchors = objRawTensor.Dimensions[1];  // 8400
float phoneMax = 0f, lensMax = 0f;
var objArr = objRawTensor.ToArray();
for (int i = 0; i < anchors; i++)
{
    float scorePhone = (float)objArr[i * 6 + 4];
    float scoreLens = (float)objArr[i * 6 + 5];
    float maxS = Math.Max(scorePhone, scoreLens);
    if (maxS < ObjConfThr) continue;
    int cls = scoreLens >= scorePhone ? 1 : 0;
    if (cls == 0 && maxS > phoneMax) phoneMax = maxS;
    if (cls == 1 && maxS > lensMax) lensMax = maxS;
}
Console.WriteLine($"  Obj raw shape: [{string.Join(",", objRawTensor.Dimensions.ToArray())}]");
Console.WriteLine($"  Phone max score: {phoneMax:F4}");
Console.WriteLine($"  Lens  max score: {lensMax:F4}");

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
Console.WriteLine($"\n🎉 C# end-to-end OK — OpenCvSharp + ORT native (我们自己 build 的) 工作正常");
return 0;
