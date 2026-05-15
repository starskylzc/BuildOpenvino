# BuildOpenvino

GitHub Actions CI repo that produces the cross-platform native binaries
(`Backend.{dll,so,dylib}` + `OpenCvSharpExtern.{dll,so,dylib}`) consumed by
[YuYiNoPhotoLib](https://gitcode.com/baileyange/YuYiNoPhotoLib).

(The repo name is historical — it started as an OpenVINO build scaffold,
later became ORT, and is now MNN. Renaming will follow when convenient.)

## What's in here

```
.github/
├── workflows/
│   ├── Build MNN 3.5.0 (Win+Mac+Linux).yml          MNN + mnnwrap → 8 RID
│   └── Build-Opencvsharp-AllPlatforms-4.10.0.yml    OpenCV → 8 RID
└── scripts/
    ├── build_mnn_{windows.ps1,macos.sh,linux.sh}    per-platform MNN build drivers
    ├── build_opencv_windows.ps1                      Windows OpenCV driver
    ├── build_{linux,macos}_slice.sh                  Linux/Mac OpenCV driver
    ├── patch_mnn_opencl_runtime.py                   per-platform-id globalContext
    ├── patch_mnn_silence_print.py                    no-op MNN_PRINT in MNNDefine.h
    └── smoke_test_*.{py,ps1}                         per-RID artifact sanity probes

mnnwrap/
├── README.md                                         canonical mnnwrap source-of-truth
├── mnnwrap.h                                         C ABI surface (yuyi_backend_*)
└── mnnwrap.cpp                                       impl, compiled into MNN target
```

## Trigger a build

```bash
# manual dispatch via gh CLI:
gh workflow run "Build MNN 3.5.0 (Win + Mac + Linux)" \
  -R starskylzc/BuildOpenvino -r main \
  -f build_type=Release -f target_set=all
```

After 8/8 green, consumers fetch via:
```bash
bash YuYiNoPhotoLib/bench/tools/deploy_mnn_artifacts.sh <run-id>
```

See `mnnwrap/README.md` for how the wrapper gets compiled into MNN's target
to produce a single anonymized `Backend.{dll,so,dylib}` per RID.
