# mnnwrap source — vendored from YuYiNoPhotoLib

**Canonical source**: `YuYiNoPhotoLib/src/mnnwrap/{mnnwrap.h,mnnwrap.cpp}`

These two files are vendored here so the BuildOpenvino MNN workflow can patch the
upstream alibaba/MNN CMakeLists.txt to compile mnnwrap.cpp directly into the MNN
target. This produces ONE native artifact per RID (`MNN.dll` / `libMNN.so` /
`libMNN.dylib`) that contains both MNN's own C++ symbols and the `yuyi_mnn_*` C ABI
symbols — clients deploy a single shared library instead of MNN + mnnwrap separately.

## Sync rule

Whenever `YuYiNoPhotoLib/src/mnnwrap/{mnnwrap.h,mnnwrap.cpp}` changes, manually
update this directory and re-run the **Build MNN 3.5.0** workflow to refresh the
8 RID artifacts.

## How injection works

Each `.github/scripts/build_mnn_<platform>.{ps1,sh}` calls the helper
`patch_mnn_with_mnnwrap.{ps1,sh}` (or appends inline) to write a small integration
block to the end of `$MNN_SOURCE/CMakeLists.txt`:

```cmake
# YuYiNoPhotoLib mnnwrap integration (build-time injection)
target_sources(MNN PRIVATE "${MNNWRAP_DIR}/mnnwrap.cpp")
target_include_directories(MNN PRIVATE "${MNNWRAP_DIR}")
target_compile_definitions(MNN PRIVATE MNNWRAP_BUILDING)
```

`MNNWRAP_DIR` is set to the absolute path of this directory inside the GHA
workspace. After cmake configure picks up the modified CMakeLists, ninja compiles
mnnwrap.cpp as part of the MNN target — no separate library, no separate link step.
