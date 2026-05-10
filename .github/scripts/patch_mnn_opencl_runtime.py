"""
YuYiNoPhotoLib patch -- OpenCLRuntime.cpp globalContext per-platform map.

Original globalContext = weak_ptr<cl::Context> is process singleton; cross
multi-GPU RuntimeManager switching causes the second RuntimeManager to reuse
the first platform's cl::Context. Patch turns it into map<platformId, weak_ptr>.

Defense-in-depth on top of mnnwrap's MNNDeviceContext.platformId path.

Usage:
    python patch_mnn_opencl_runtime.py <MNN_SOURCE>
"""
import io
import sys
from pathlib import Path

# Windows GHA runner stdout default cp1252; force UTF-8 to allow CJK / arrows.
if sys.stdout.encoding and sys.stdout.encoding.lower() not in ("utf-8", "utf8"):
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True)

target = Path(sys.argv[1]) / "source" / "backend" / "opencl" / "core" / "runtime" / "OpenCLRuntime.cpp"
if not target.exists():
    print(f"::error::{target} not found")
    sys.exit(1)

src = target.read_text(encoding="utf-8")

if "globalContextMap" in src:
    print("OpenCLRuntime.cpp already patched (globalContextMap present); skip")
    sys.exit(0)

# Original (verbatim from MNN 3.5.0 source):
old_decl = """static std::weak_ptr<::cl::Context> globalContext;
static std::mutex gCLContextMutex;
static std::shared_ptr<::cl::Context> getGlobalContext(){
    return globalContext.lock();
        }

static void setGlobalContext(std::shared_ptr<cl::Context> Context){
    std::lock_guard<std::mutex> lck(gCLContextMutex);
    globalContext = Context;
}"""

new_decl = """// YuYiNoPhotoLib patch: globalContext per-platformId map -- defense-in-depth
// for multi-GPU runtime switching; pairs with mnnwrap MNNDeviceContext.platformId.
static std::map<int, std::weak_ptr<::cl::Context>> globalContextMap;
static std::mutex gCLContextMutex;
static std::shared_ptr<::cl::Context> getGlobalContext(int platformId){
    std::lock_guard<std::mutex> lck(gCLContextMutex);
    auto it = globalContextMap.find(platformId);
    if (it == globalContextMap.end()) return nullptr;
    return it->second.lock();
}

static void setGlobalContext(int platformId, std::shared_ptr<cl::Context> Context){
    std::lock_guard<std::mutex> lck(gCLContextMutex);
    globalContextMap[platformId] = Context;
}"""

if old_decl not in src:
    print("::error::globalContext block not found verbatim (MNN version drift?)")
    print("Looking for first 80 chars: " + old_decl[:80])
    sys.exit(2)

src = src.replace(old_decl, new_decl, 1)

# Update call sites to pass platformId.
src = src.replace("mContext = getGlobalContext();", "mContext = getGlobalContext(platformId);")
src = src.replace("setGlobalContext(mContext);", "setGlobalContext(platformId, mContext);")

target.write_text(src, encoding="utf-8")
print("Patched " + target.name + ": globalContext -> globalContextMap[platformId]")
