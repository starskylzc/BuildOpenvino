# Deployment Guide

7 个平台的 ORT 1.25.0 + OpenCvSharp 4.10.0 native runtime bundle 生成 + 部署流程。

## CI 流程图

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Build ORT 1.25.0 Desktop                                 │
│    (5 self-build platforms: Win x3 + Mac x2)                │
│    每平台单独 trigger 失败不影响其他                            │
└──────────────────────┬──────────────────────────────────────┘
                       │ 成功后产出 self-build artifacts
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Build-Opencvsharp-AllPlatforms-4.10.0                    │
│    (7 archs: Win x3 + Mac x2 + Linux x64/aarch64)           │
│    一次跑完即可,7 个 archs 的 OpenCvSharpExtern               │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Verify Built Artifacts (CSharp 端到端测试)                 │
│    (7 platforms verify):                                    │
│      - 5 self-build: 拉 Build ORT artifact                  │
│      - 2 official:   curl from GitHub release v1.25.0       │
│    每平台:                                                    │
│      → publish C# project                                   │
│      → stage native libs (ORT + OpenCvSharp)                │
│      → 跑 test.png 推理 (CPU EP 验证)                         │
│      → 画框 (Cv2.Rectangle/PutText) + 像素验证                │
│      → 保存 annotated PNG 上传                                │
│      → 上传 staged native libs (deploy-<platform> artifact) │
└──────────────────────┬──────────────────────────────────────┘
                       │ 全 7 ✅
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Stage Deploy                                             │
│    输入: 上一步 verify run ID                                  │
│    校验: 7 个平台 job 都 success                              │
│    操作: 拉 7 个 deploy-<platform> artifact                  │
│         按 deploy/<platform>/ 目录组装                        │
│         附 README.md (客户部署说明)                            │
│    输出: 单个 deploy-1.25.0-<sha> artifact                   │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. ./artifacts/download_deploy.sh (本地一键)                  │
│    自动找最近 Stage Deploy success run                        │
│    下载 deploy-1.25.0-<sha> 到 ./artifacts/deploy/            │
└─────────────────────────────────────────────────────────────┘
```

## 平台来源矩阵

| 平台 | ORT 来源 | 原因 |
|---|---|---|
| `win-x64-dml` | self-build | 官方 NuGet 还停在老版,需要 1.25 新特性 |
| `win-x86-cpu` | self-build | 官方 1.25 release 没出 32-bit |
| `win-arm64-dml` | self-build | 同 1.25 win |
| `mac-x64-coreml` (10.15) | self-build | 官方 1.25 完全没 osx-x64 |
| `mac-arm64-coreml` (11.0) | self-build | 官方 osx-arm64 是 14.0 floor 太严 |
| `linux-x64` (CPU+CUDA12+TRT) | **官方 release** | glibc 2.27 比我们 manylinux_2_28 还宽,自 build 没意义 |
| `linux-aarch64` (CPU only) | **官方 release** | 同上 |

**官方 release 链接** (在 CSharpVerify workflow 里硬编码):
- `https://github.com/microsoft/onnxruntime/releases/download/v1.25.0/onnxruntime-linux-x64-gpu-1.25.0.tgz`
- `https://github.com/microsoft/onnxruntime/releases/download/v1.25.0/onnxruntime-linux-aarch64-1.25.0.tgz`

## 客户部署支持矩阵

| 客户机 OS | deploy/ 目录 | 加速路径 |
|---|---|---|
| Windows 10/11 x64 | `win-x64/` | DirectML auto (NVIDIA/AMD/Intel iGPU 都支持) |
| Windows 10/11 x86 | `win-x86/` | CPU only |
| Windows 11 ARM64 (Surface, Snapdragon X) | `win-arm64/` | DirectML |
| macOS 10.15 Catalina+ Intel | `osx-x64/` | CoreML |
| macOS 11.0 Big Sur+ Apple Silicon | `osx-arm64/` | CoreML + ANE |
| **信创 Linux x64** (麒麟 V10 / UOS V20 / 海光) | `linux-x64/` | CPU EP (~5-7 FPS) |
| **信创 Linux x64 + NVIDIA dGPU** | `linux-x64/` | CUDA EP (~30+ FPS) 或 TensorRT EP (~50+ FPS) |
| **信创 Linux ARM** (鲲鹏 / 飞腾) | `linux-aarch64/` | CPU only (~5-7 FPS) |

## 使用 Linux x64 GPU 加速

`linux-x64/` 包含：
```
libonnxruntime.so.1.25.0
libonnxruntime.so → symlink
libonnxruntime_providers_shared.so
libonnxruntime_providers_cuda.so      ← 需 CUDA 12.x driver
libonnxruntime_providers_tensorrt.so  ← 需 NVIDIA + TensorRT 10.x
libOpenCvSharpExtern.so
```

CPU 模式默认开箱即用。GPU 模式需要客户机：
1. 装 NVIDIA driver ≥ 525 (CUDA 12.x runtime)
2. (可选) 装 TensorRT 10.x runtime
3. C# 代码加 `sess.AppendExecutionProvider_CUDA(...)` 或 `_Tensorrt(...)`

## 本地一键下载

```bash
cd artifacts/
./download_deploy.sh                    # 用最近成功的 Stage Deploy run
./download_deploy.sh 12345678           # 或指定 run ID
```

## 不在本 bundle 的国产 NPU

| NPU | 当前状态 | 后续路径 |
|---|---|---|
| 华为昇腾 (CANN) | 未配 CI | 在 Build ORT workflow 加 `--use_cann` 一档,客户机要装 CANN Toolkit 8.0+ |
| 海光 DCU (MIGraphX) | 上游 migraphx 头文件改名,暂搁置 | 真有客户驱动再修 shim |
| Intel iGPU on Linux (OpenVINO) | ORT 1.25 上游 charconv/optional 多 bug | 等 ORT 1.26+ 修了再加 |
| 寒武纪 / 摩尔线程 / 燧原 | 不在 ORT 生态 | 客户用厂商 SDK,我们写 IBackend 抽象 (工程量大) |
