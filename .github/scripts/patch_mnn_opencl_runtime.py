"""
YuYiNoPhotoLib patch — OpenCLRuntime.cpp globalContext 改成按 platformId 分 map。

原版 globalContext = std::weak_ptr<cl::Context> 是 process 单例,跨多 GPU
RuntimeManager 切换时(NVIDIA dGPU + Intel iGPU)第二个 RuntimeManager 用
getGlobalContext().lock() 拿到第一个 platform 的 cl::Context(没立即释放),
导致"选 iGPU 实际跑 dGPU"。

改成 map<platformId, weak_ptr> 后两个 platform 各持独立 cl::Context,
RuntimeManager 切换严格隔离。

Usage:
    python patch_mnn_opencl_runtime.py <MNN_SOURCE>
"""
import sys
from pathlib import Path

target = Path(sys.argv[1]) / "source" / "backend" / "opencl" / "core" / "runtime" / "OpenCLRuntime.cpp"
if not target.exists():
    print(f"::error::{target} not found")
    sys.exit(1)

src = target.read_text(encoding="utf-8")

if "globalContextMap" in src:
    print(f"OpenCLRuntime.cpp already patched (globalContextMap present), skip")
    sys.exit(0)

# 1. 替换全局变量声明 + 两个 helper 函数
old_decl = """static std::weak_ptr<::cl::Context> globalContext;
static std::mutex gCLContextMutex;
static std::shared_ptr<::cl::Context> getGlobalContext(){
    return globalContext.lock();
        }

static void setGlobalContext(std::shared_ptr<cl::Context> Context){
    std::lock_guard<std::mutex> lck(gCLContextMutex);
    globalContext = Context;
}"""

new_decl = """// YuYiNoPhotoLib patch: globalContext 按 platformId 分 map,防多 GPU 切换时
// 后创建的 OpenCLRuntime 误复用前一个 platform 的 cl::Context。
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
    print("::error::globalContext declaration block not found in expected form (MNN 版本可能变了)")
    print("Looking for:", old_decl[:80])
    sys.exit(2)

src = src.replace(old_decl, new_decl, 1)

# 2. 调用点改成带 platformId 参数
src = src.replace("mContext = getGlobalContext();", "mContext = getGlobalContext(platformId);")
src = src.replace("setGlobalContext(mContext);", "setGlobalContext(platformId, mContext);")

target.write_text(src, encoding="utf-8")
print(f">>> Patched {target.name}: globalContext → globalContextMap[platformId]")
