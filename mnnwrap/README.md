# mnnwrap — C ABI wrapper for MNN

**Canonical source location** for the YuYiNoPhotoLib inference wrapper.

## What this is

A minimal C ABI shim around `MNN::Express::Module` so .NET / Go / Rust clients can
P/Invoke without dealing with C++ name mangling. The wrapper exports a stable
`yuyi_backend_*` API surface (see `mnnwrap.h`).

## How it ships

There is no separate `mnnwrap.dll` artifact. Each platform build script under
`.github/scripts/build_mnn_<platform>.{ps1,sh}` appends a CMake injection block
to MNN's upstream `CMakeLists.txt`:

```cmake
target_sources(MNN PRIVATE "${MNNWRAP_DIR}/mnnwrap.cpp")
target_include_directories(MNN PRIVATE "${MNNWRAP_DIR}")
target_compile_definitions(MNN PRIVATE MNNWRAP_BUILDING)
set_target_properties(MNN PROPERTIES OUTPUT_NAME "Backend")
```

`MNNWRAP_DIR` resolves to this directory inside the GHA workspace. Ninja then
compiles `mnnwrap.cpp` as part of the MNN target, producing a single
`Backend.{dll,so,dylib}` per RID that contains:

- All MNN C++ symbols (internal, hidden by `OUTPUT_NAME=Backend` so PE
  `IMAGE_EXPORT_DIRECTORY.Name` / ELF `DT_SONAME` / Mach-O `LC_ID_DYLIB` all read
  `Backend.*`)
- Our 17 `yuyi_backend_*` C ABI exports (visible to `dumpbin /exports`)

Clients deploy one shared library per RID; no separate wrapper to ship.

## Workflow

Edits to `mnnwrap.{h,cpp}` are made directly here. Re-run the **Build MNN 3.5.0**
workflow after each change to refresh the 8 RID artifacts. Consumers fetch via
`YuYiNoPhotoLib/bench/deploy_mnn_artifacts.sh <run-id>`.

The previous "vendored from YuYiNoPhotoLib/src/mnnwrap" arrangement (with manual
sync) has been retired — `YuYiNoPhotoLib/src/mnnwrap/` was removed and this
directory is the single source of truth.
