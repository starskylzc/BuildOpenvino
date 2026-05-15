// =====================================================================
// mnnwrap — implementation. Wraps MNN::Express::Module API in C ABI.
// =====================================================================

#define MNNWRAP_BUILDING

#include "mnnwrap.h"

#include <MNN/MNNDefine.h>
#include <MNN/MNNForwardType.h>
// 必须 #define MNN_USER_SET_DEVICE 才能看到 MNNDeviceContext 结构体
// (它在 MNNSharedContext.h 内被 #ifdef MNN_USER_SET_DEVICE guard,
//  跟 OpenCLBackend.hpp 里的 #define 一致)
#define MNN_USER_SET_DEVICE
#include <MNN/MNNSharedContext.h>
#include <MNN/expr/Module.hpp>
#include <MNN/expr/Expr.hpp>
#include <MNN/expr/ExprCreator.hpp>
#include <MNN/expr/Executor.hpp>
#include <MNN/expr/ExecutorScope.hpp>
#include <MNN/expr/NeuralNetWorkOp.hpp>
#include <MNN/Interpreter.hpp>

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#if defined(_WIN32) || defined(_WIN64)
  #ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
  #endif
  #include <windows.h>
#else
  #include <dlfcn.h>
#endif

using namespace MNN;
using namespace MNN::Express;

// ============================== 日志回调路由 ==============================
// MNN 上游 MNN_ERROR 宏被 patch_mnn_silence_print.py 重定向为
// yuyi_backend_native_log(format, ...)。本编译单元提供其实现 + 一个可注册
// 的回调指针。默认 nullptr → 静默(production 默认)。C# 端注册回调
// 把消息塞进 AsyncLogger,文件/UI 自决,不污染 stdout / stderr。

namespace {
    std::atomic<YuYiBackendLogCallback> g_native_log_cb{nullptr};
}

extern "C" MNNWRAP_API void yuyi_backend_set_log_callback(YuYiBackendLogCallback cb) {
    g_native_log_cb.store(cb, std::memory_order_release);
}

extern "C" MNNWRAP_API void yuyi_backend_native_log(const char* fmt, ...) {
    auto cb = g_native_log_cb.load(std::memory_order_acquire);
    if (cb == nullptr) {
        return;  // 没人监听 → 完全静默,format 都不算
    }
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    int n = std::vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n < 0) {
        return;
    }
    // 去尾换行 — MNN 的 format 通常带 "\n",日志层自己加换行更整齐
    int len = (n < (int)sizeof(buf) - 1) ? n : (int)sizeof(buf) - 1;
    buf[len] = '\0';   // 显式 NUL 终止 — vsnprintf 在 truncation 时 glibc 各版本行为不一致
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) {
        buf[--len] = '\0';
    }
    cb(buf);
}

// ============================== 内部结构 ==============================

struct YuYiMnnRuntime_s {
    // 每个 RuntimeManager 配独立 Executor + 独立 MNNDeviceContext。
    // GPU 路径用 mnnwrap 自造的 cl_context 通过 MNNDeviceContext.contextPtr 灌给 MNN,
    // MNN 看到 contextPtr 非空就直接用,完全绕开内部 globalContext 单例(那条路径
    // process 级共享,在 Win 多 GPU + 老 NVIDIA driver 下会让选 dGPU 实际跑 iGPU)。
    std::shared_ptr<Executor> executor;
    std::shared_ptr<Executor::RuntimeManager> rt;
    // backendConfig + devCtx 都做成 runtime 成员 — MNN createRuntimeManager
    // 内部对 ScheduleConfig 做 shallow copy,如果 bc 在栈上 + MNN 后续读它就是 UAF。
    // 持久化为成员之后地址稳定,可被 sharedContext 安全引用。
    BackendConfig backendConfig;
    MNNDeviceContext devCtx;
    MNNForwardType actualType = MNN_FORWARD_CPU;
    std::mutex lock;

    // ── OpenCL 自管资源(仅 forward=OPENCL 路径填) ────────────────────
    // 我们用 ICD loader 直接 clCreateContext 出来的 cl_context, 灌给 devCtx.contextPtr。
    // MNN 用 no-op deleter 包它(看 OpenCLRuntime.cpp contextPtr 分支),不会释放,
    // 由本 wrapper 在 runtime_destroy 里 clReleaseContext。
    void*  ownedClContext = nullptr;
    // OpenCL.dll / libOpenCL.so 的句柄 + 函数指针,生命周期跟 ownedClContext 绑定 —
    // 不能在 runtime_create 结束时 release(否则后面 clReleaseContext 调用悬空指针)。
    void*  clLib = nullptr;
    int32_t (*clReleaseContextFn)(void*) = nullptr;
};

struct YuYiMnnModule_s {
    std::shared_ptr<Module> mod;
    YuYiMnnRuntimeHandle owningRt = nullptr;     // 借引用,不释放
    std::vector<std::string> inputNames;
    std::vector<std::string> outputNames;

    // 当前持有的输入 VARP(set_input 写入,forward 读取)
    std::vector<VARP> inputs;
    // 上次 forward 的输出 VARP(get_output_data 读取)
    std::vector<VARP> outputs;

    std::mutex lock;
};

// ============================== 工具 ==============================

static MNNForwardType toMnnForward(int32_t v) {
    switch (v) {
        case MNNWRAP_FORWARD_CPU:    return MNN_FORWARD_CPU;
        case MNNWRAP_FORWARD_OPENCL: return MNN_FORWARD_OPENCL;
        case MNNWRAP_FORWARD_METAL:  return MNN_FORWARD_METAL;
        case MNNWRAP_FORWARD_CUDA:   return MNN_FORWARD_CUDA;
        case MNNWRAP_FORWARD_VULKAN: return MNN_FORWARD_VULKAN;
        case MNNWRAP_FORWARD_NN:     return MNN_FORWARD_NN;
        case MNNWRAP_FORWARD_AUTO:   return MNN_FORWARD_AUTO;
        default:                     return MNN_FORWARD_CPU;
    }
}

static int32_t fromMnnForward(MNNForwardType t) {
    switch (t) {
        case MNN_FORWARD_CPU:    return MNNWRAP_FORWARD_CPU;
        case MNN_FORWARD_OPENCL: return MNNWRAP_FORWARD_OPENCL;
        case MNN_FORWARD_METAL:  return MNNWRAP_FORWARD_METAL;
        case MNN_FORWARD_CUDA:   return MNNWRAP_FORWARD_CUDA;
        case MNN_FORWARD_VULKAN: return MNNWRAP_FORWARD_VULKAN;
        case MNN_FORWARD_NN:     return MNNWRAP_FORWARD_NN;
        case MNN_FORWARD_AUTO:   return MNNWRAP_FORWARD_AUTO;
        default:                 return MNNWRAP_FORWARD_CPU;
    }
}

static size_t copyToBuf(const std::string& s, char* buf, size_t bufSize) {
    size_t need = s.size() + 1;
    if (buf != nullptr && bufSize >= need) {
        std::memcpy(buf, s.data(), s.size());
        buf[s.size()] = '\0';
    } else if (buf != nullptr && bufSize > 0) {
        // 截断 NUL terminate(不够时)
        size_t cp = bufSize - 1;
        if (cp > s.size()) cp = s.size();
        std::memcpy(buf, s.data(), cp);
        buf[cp] = '\0';
    }
    return need;
}

// ============================== OpenCL ICD 动态枚举 ==============================
// 不在 link 期依赖 OpenCL SDK / OpenCL.dll 必存在 — 通过 LoadLibrary/dlopen 在运行期
// 探测 ICD loader。生产路径(NVIDIA / Intel / AMD / 国产 OpenCL driver)都会装
// OpenCL.dll / libOpenCL.so.1;装了我们枚举,没装就返回 0 候选,wrapper 自身依然
// 可正常加载与运行(只有 GPU 后端选项变空,MNN 自然走 CPU)。
//
// 仅枚举 CL_DEVICE_TYPE_GPU,跳过 CL_DEVICE_TYPE_CPU(那是 ICD 自带的软 CPU 渲染器,
// 没意义)。
namespace clenum {

// 必要 OpenCL 常量(避免引 cl.h header,直接照抄数值)。
constexpr uint32_t CL_SUCCESS                       = 0;
constexpr uint32_t CL_DEVICE_TYPE_GPU               = (1u << 2);
constexpr uint32_t CL_DEVICE_NAME                   = 0x102B;
constexpr uint32_t CL_DEVICE_VENDOR                 = 0x102C;
constexpr uint32_t CL_DRIVER_VERSION                = 0x102D;
constexpr uint32_t CL_DEVICE_VENDOR_ID              = 0x1001;
constexpr uint32_t CL_DEVICE_GLOBAL_MEM_SIZE        = 0x101F;
constexpr uint32_t CL_DEVICE_HOST_UNIFIED_MEMORY    = 0x1035;
// Context 选项 — yuyi_backend_runtime_create 用这两条直接造 cl_context
constexpr intptr_t CL_CONTEXT_PLATFORM              = 0x1084;
constexpr uint32_t CL_CONTEXT_DEVICES               = 0x1081;

typedef int32_t  (*pfn_clGetPlatformIDs)(uint32_t, void**, uint32_t*);
typedef int32_t  (*pfn_clGetDeviceIDs)(void*, uint64_t, uint32_t, void**, uint32_t*);
typedef int32_t  (*pfn_clGetDeviceInfo)(void*, uint32_t, size_t, void*, size_t*);
// clCreateContext(properties[], num_devices, devices[], pfn_notify, user_data, errcode_ret) -> cl_context
typedef void*    (*pfn_clCreateContext)(const intptr_t*, uint32_t, void* const*, void*, void*, int32_t*);
typedef int32_t  (*pfn_clReleaseContext)(void*);
typedef int32_t  (*pfn_clGetContextInfo)(void*, uint32_t, size_t, void*, size_t*);

struct IcdFns {
    void* lib = nullptr;
    pfn_clGetPlatformIDs  getPlatformIDs = nullptr;
    pfn_clGetDeviceIDs    getDeviceIDs   = nullptr;
    pfn_clGetDeviceInfo   getDeviceInfo  = nullptr;
    pfn_clCreateContext   createContext  = nullptr;
    pfn_clReleaseContext  releaseContext = nullptr;
    pfn_clGetContextInfo  getContextInfo = nullptr;

    bool resolve() {
#if defined(_WIN32) || defined(_WIN64)
        lib = (void*)LoadLibraryW(L"OpenCL.dll");
        if (lib == nullptr) return false;
        getPlatformIDs = (pfn_clGetPlatformIDs)GetProcAddress((HMODULE)lib, "clGetPlatformIDs");
        getDeviceIDs   = (pfn_clGetDeviceIDs)  GetProcAddress((HMODULE)lib, "clGetDeviceIDs");
        getDeviceInfo  = (pfn_clGetDeviceInfo) GetProcAddress((HMODULE)lib, "clGetDeviceInfo");
        createContext  = (pfn_clCreateContext) GetProcAddress((HMODULE)lib, "clCreateContext");
        releaseContext = (pfn_clReleaseContext)GetProcAddress((HMODULE)lib, "clReleaseContext");
        getContextInfo = (pfn_clGetContextInfo)GetProcAddress((HMODULE)lib, "clGetContextInfo");
#else
        // Linux 上 libOpenCL.so.1 是 ICD loader 的 SONAME(ocl-icd-libopencl1 / KhronosGroup OpenCL-ICD-Loader)
        // .so 不带版本号有时找不到,优先 .so.1
        lib = dlopen("libOpenCL.so.1", RTLD_NOW | RTLD_LOCAL);
        if (lib == nullptr) {
            lib = dlopen("libOpenCL.so", RTLD_NOW | RTLD_LOCAL);
        }
        if (lib == nullptr) return false;
        getPlatformIDs = (pfn_clGetPlatformIDs)dlsym(lib, "clGetPlatformIDs");
        getDeviceIDs   = (pfn_clGetDeviceIDs)  dlsym(lib, "clGetDeviceIDs");
        getDeviceInfo  = (pfn_clGetDeviceInfo) dlsym(lib, "clGetDeviceInfo");
        createContext  = (pfn_clCreateContext) dlsym(lib, "clCreateContext");
        releaseContext = (pfn_clReleaseContext)dlsym(lib, "clReleaseContext");
        getContextInfo = (pfn_clGetContextInfo)dlsym(lib, "clGetContextInfo");
#endif
        // 枚举所需的三个是核心,Context 三个是 GPU 选卡路径新加的 —
        // ListOpenClDevices 只 enumerate 不 createContext,枚举三个就够。
        return getPlatformIDs && getDeviceIDs && getDeviceInfo;
    }

    /// Context 创建链所需的三个函数指针是否齐全 — runtime_create OPENCL 分支前置检查。
    bool hasContextApi() const {
        return createContext && releaseContext && getContextInfo;
    }

    void release() {
        if (lib == nullptr) return;
#if defined(_WIN32) || defined(_WIN64)
        FreeLibrary((HMODULE)lib);
#else
        dlclose(lib);
#endif
        lib = nullptr;
    }
};

static void fillString(void* dev, uint32_t param, char* dst, size_t dstCap, pfn_clGetDeviceInfo getInfo) {
    if (dstCap == 0 || dst == nullptr) return;
    dst[0] = '\0';
    size_t need = 0;
    if (getInfo(dev, param, 0, nullptr, &need) != CL_SUCCESS || need == 0) return;
    if (need > dstCap) need = dstCap;  // 截断,保留 NUL 位
    if (getInfo(dev, param, need, dst, nullptr) != CL_SUCCESS) {
        dst[0] = '\0';
        return;
    }
    dst[dstCap - 1] = '\0';  // 显式 NUL 终止
}

/// 给定 platformId / deviceId, 用 ICD 解析到具体的 cl_platform_id + cl_device_id;
/// 失败返回 false, *outPlat / *outDev 不变。
static bool resolvePlatformDevice(const IcdFns& icd, uint32_t platformId, uint32_t deviceId,
                                  void** outPlat, void** outDev) {
    uint32_t platCount = 0;
    if (icd.getPlatformIDs(0, nullptr, &platCount) != CL_SUCCESS || platCount == 0) {
        return false;
    }
    if (platformId >= platCount) {
        return false;
    }
    std::vector<void*> platforms(platCount, nullptr);
    if (icd.getPlatformIDs(platCount, platforms.data(), nullptr) != CL_SUCCESS) {
        return false;
    }
    void* plat = platforms[platformId];

    uint32_t devCount = 0;
    if (icd.getDeviceIDs(plat, CL_DEVICE_TYPE_GPU, 0, nullptr, &devCount) != CL_SUCCESS
        || devCount == 0) {
        return false;
    }
    if (deviceId >= devCount) {
        return false;
    }
    std::vector<void*> devices(devCount, nullptr);
    if (icd.getDeviceIDs(plat, CL_DEVICE_TYPE_GPU, devCount, devices.data(), nullptr) != CL_SUCCESS) {
        return false;
    }
    *outPlat = plat;
    *outDev  = devices[deviceId];
    return true;
}

} // namespace clenum

// ============================== API ==============================

extern "C" {

MNNWRAP_API const char* yuyi_backend_version(void) {
    return getVersion();
}

MNNWRAP_API int32_t yuyi_backend_list_opencl_devices(YuyiClDevice* outBuf, int32_t bufLen) {
    using namespace clenum;
    IcdFns icd;
    if (!icd.resolve()) {
        return 0;  // 没装 OpenCL ICD loader → 视作无任何 GPU device
    }

    int32_t writtenOrTotal = 0;
    do {
        uint32_t platCount = 0;
        if (icd.getPlatformIDs(0, nullptr, &platCount) != CL_SUCCESS || platCount == 0) {
            break;
        }
        std::vector<void*> platforms(platCount, nullptr);
        if (icd.getPlatformIDs(platCount, platforms.data(), nullptr) != CL_SUCCESS) {
            break;
        }

        for (uint32_t p = 0; p < platCount; ++p) {
            uint32_t devCount = 0;
            // 平台下没 GPU device 时 CL_DEVICE_NOT_FOUND 是正常情况(纯 CPU ICD),跳过
            if (icd.getDeviceIDs(platforms[p], CL_DEVICE_TYPE_GPU, 0, nullptr, &devCount) != CL_SUCCESS
                || devCount == 0) {
                continue;
            }
            std::vector<void*> devices(devCount, nullptr);
            if (icd.getDeviceIDs(platforms[p], CL_DEVICE_TYPE_GPU, devCount, devices.data(), nullptr) != CL_SUCCESS) {
                continue;
            }

            for (uint32_t d = 0; d < devCount; ++d) {
                if (outBuf != nullptr && writtenOrTotal < bufLen) {
                    YuyiClDevice& slot = outBuf[writtenOrTotal];
                    std::memset(&slot, 0, sizeof(slot));
                    slot.platformIndex = p;
                    slot.deviceIndex   = d;

                    uint32_t vendorId = 0;
                    icd.getDeviceInfo(devices[d], CL_DEVICE_VENDOR_ID,
                                      sizeof(vendorId), &vendorId, nullptr);
                    slot.vendorId = vendorId;

                    uint32_t hostUnified = 0;
                    icd.getDeviceInfo(devices[d], CL_DEVICE_HOST_UNIFIED_MEMORY,
                                      sizeof(hostUnified), &hostUnified, nullptr);
                    slot.hostUnifiedMemory = hostUnified;

                    uint64_t globalMem = 0;
                    icd.getDeviceInfo(devices[d], CL_DEVICE_GLOBAL_MEM_SIZE,
                                      sizeof(globalMem), &globalMem, nullptr);
                    slot.globalMemBytes = globalMem;

                    fillString(devices[d], CL_DEVICE_NAME,     slot.name,          sizeof(slot.name),          icd.getDeviceInfo);
                    fillString(devices[d], CL_DEVICE_VENDOR,   slot.vendor,        sizeof(slot.vendor),        icd.getDeviceInfo);
                    fillString(devices[d], CL_DRIVER_VERSION,  slot.driverVersion, sizeof(slot.driverVersion), icd.getDeviceInfo);
                }
                ++writtenOrTotal;
            }
        }
    } while (false);

    icd.release();
    return writtenOrTotal;
}

MNNWRAP_API int32_t yuyi_backend_available_backends(int32_t* outBuf, int32_t bufLen) {
    // 探测 RuntimeManager 创建是否成功来判断 backend 可用性
    // 实际 wrapper 调用方拿到这个列表后,可以决定 fallback 链
    static const MNNForwardType candidates[] = {
        MNN_FORWARD_CPU, MNN_FORWARD_OPENCL, MNN_FORWARD_METAL,
        MNN_FORWARD_CUDA, MNN_FORWARD_VULKAN, MNN_FORWARD_NN,
    };
    int32_t cnt = 0;
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); ++i) {
        ScheduleConfig sc;
        sc.type = candidates[i];
        sc.numThread = 1;
        std::shared_ptr<Executor::RuntimeManager> rt(
            Executor::RuntimeManager::createRuntimeManager(sc),
            Executor::RuntimeManager::destroy);
        if (!rt) continue;
        // isBackendSupport 给出真实可用性
        std::vector<MNNForwardType> probe{ candidates[i] };
        auto sup = rt->isBackendSupport(probe);
        if (!sup.empty() && sup[0]) {
            if (outBuf != nullptr && cnt < bufLen) {
                outBuf[cnt] = fromMnnForward(candidates[i]);
            }
            ++cnt;
        }
    }
    return cnt;
}

MNNWRAP_API YuYiMnnRuntimeHandle yuyi_backend_runtime_create(const YuYiMnnRuntimeConfig* cfg) {
    if (cfg == nullptr) return nullptr;

    // ── 提前分配 runtime handle,持有 MNNDeviceContext + Executor + BackendConfig 生命周期 ──
    // 关键:bc / devCtx 是 runtime 成员而不是栈变量 — MNN 内部对 sharedContext 指针保留,
    // 栈对象会 UAF。
    auto* h = new YuYiMnnRuntime_s();

    ScheduleConfig sc;
    sc.type       = toMnnForward(cfg->forwardType);
    sc.numThread  = cfg->numThread > 0 ? cfg->numThread : 1;
    sc.backupType = MNN_FORWARD_CPU;
    h->actualType = sc.type;

    BackendConfig& bc = h->backendConfig;
    switch (cfg->precision) {
        case MNNWRAP_PRECISION_HIGH:     bc.precision = BackendConfig::Precision_High; break;
        case MNNWRAP_PRECISION_LOW:      bc.precision = BackendConfig::Precision_Low; break;
        case MNNWRAP_PRECISION_LOW_BF16: bc.precision = BackendConfig::Precision_Low_BF16; break;
        default:                         bc.precision = BackendConfig::Precision_Normal; break;
    }
    switch (cfg->memory) {
        case MNNWRAP_MEMORY_HIGH: bc.memory = BackendConfig::Memory_High; break;
        case MNNWRAP_MEMORY_LOW:  bc.memory = BackendConfig::Memory_Low;  break;
        default:                  bc.memory = BackendConfig::Memory_Normal; break;
    }
    switch (cfg->power) {
        case MNNWRAP_POWER_HIGH: bc.power = BackendConfig::Power_High; break;
        case MNNWRAP_POWER_LOW:  bc.power = BackendConfig::Power_Low;  break;
        default:                 bc.power = BackendConfig::Power_Normal; break;
    }
    sc.backendConfig = &bc;

    // ── OpenCL 路径:wrapper 自造 cl_context 通过 MNNDeviceContext.contextPtr 灌给 MNN ──
    //
    // ## 为什么不让 MNN 自己根据 platformId 创建 context
    //
    // MNN OpenCLRuntime 用 process 级 `static weak_ptr<cl::Context> globalContext`
    // 缓存第一次创建的 cl::Context。同 process 后续 OpenCL backend init 全部拿这个缓存,
    // **传 platformId / deviceId 都被无视**。多 GPU 机器上(Win 老 NVIDIA Optimus-ish
    // 路由 / Kepler driver / OpenCL ICD 顺序变化等场景)选 dGPU 实际跑 iGPU。
    //
    // OpenCLRuntime.cpp 同时还有一条 contextPtr 分支(MNN 文档级 API):
    //   if (nullptr != contextPtr) {
    //       mContext = shared_ptr<cl::Context>((cl::Context*)contextPtr, no_op_deleter);
    //   } else { mContext = getGlobalContext(); ... }
    //
    // contextPtr 非空时 MNN 完全跳过 globalContext, 直接用我们给的 context。
    // wrapper 自己 ICD loader 调 clCreateContext + CL_CONTEXT_PLATFORM 锁死 platform,
    // 然后 clGetContextInfo(CL_CONTEXT_DEVICES) 再验一次 — 驱动若偷偷把 context 路由
    // 到别的卡, 在这一步就能抓到(verifyDev != 我们请求的 dev), 立即 fail 让上层重选,
    // 绝不沉默地跑错卡。
    //
    // platformId / deviceId 字段也填上 — MNN OpenCLRuntime 即便走 contextPtr 分支,
    // 后续还要用 platforms[platformId].getDevices()[deviceId] 拿 cl_device_id 给
    // CommandQueue 用, 必须跟我们 cl_context 的实际 device 一致。
    //
    // CUDA / Vulkan / NN 等其它 GPU forward type 当前未被任何 profile 派发(参
    // MnnBackend.ResolveForwardType), wrapper 这里也不再为它们填 sharedContext,
    // 避免无关 backend 的 platformId 语义混淆。需要 CUDA 时单独走 CUDA 分支即可。
    if (sc.type == MNN_FORWARD_OPENCL) {
        uint32_t reqPlat = (uint32_t)(cfg->gpuPlatformId >= 0 ? cfg->gpuPlatformId : 0);
        uint32_t reqDev  = (uint32_t)(cfg->gpuDeviceId   >= 0 ? cfg->gpuDeviceId   : 0);

        clenum::IcdFns icd;
        if (!icd.resolve()) {
            yuyi_backend_native_log("[mnnwrap] OpenCL ICD loader 加载失败 — 系统未装 OpenCL driver, GPU 路径不可用\n");
            delete h;
            return nullptr;
        }
        if (!icd.hasContextApi()) {
            yuyi_backend_native_log("[mnnwrap] OpenCL ICD 缺 clCreateContext/clReleaseContext/clGetContextInfo 三件套 — driver 太老或损坏\n");
            icd.release();
            delete h;
            return nullptr;
        }

        void* plat = nullptr;
        void* dev  = nullptr;
        if (!clenum::resolvePlatformDevice(icd, reqPlat, reqDev, &plat, &dev)) {
            yuyi_backend_native_log("[mnnwrap] OpenCL 解析 platformId=%u deviceId=%u 失败 — ICD 枚举顺序变了或卡数不够\n",
                                    reqPlat, reqDev);
            icd.release();
            delete h;
            return nullptr;
        }

        // 用 CL_CONTEXT_PLATFORM 显式锁死 platform, 防驱动按默认 platform 重路由
        const intptr_t props[] = {
            clenum::CL_CONTEXT_PLATFORM, (intptr_t)plat,
            0
        };
        int32_t err = 0;
        void* clCtx = icd.createContext(props, 1, &dev, nullptr, nullptr, &err);
        if (clCtx == nullptr || err != (int32_t)clenum::CL_SUCCESS) {
            yuyi_backend_native_log("[mnnwrap] clCreateContext 失败(err=%d, platformId=%u deviceId=%u) — driver/卡不可用\n",
                                    err, reqPlat, reqDev);
            icd.release();
            delete h;
            return nullptr;
        }

        // 验证:context 真在我们请求的 device 上, 没被驱动 reroute
        void* verifyDev = nullptr;
        size_t verifySize = 0;
        if (icd.getContextInfo(clCtx, clenum::CL_CONTEXT_DEVICES, sizeof(verifyDev), &verifyDev, &verifySize) != (int32_t)clenum::CL_SUCCESS
            || verifyDev != dev) {
            yuyi_backend_native_log("[mnnwrap] clGetContextInfo 验证失败 — 驱动把 context 路由到了别的 device (请求 %p, 实际 %p)。"
                                    "Win10+ 上检查 Graphics performance preference / NVIDIA Control Panel 的 Manage 3D Settings, "
                                    "把本程序设为 High Performance 卡\n",
                                    dev, verifyDev);
            icd.releaseContext(clCtx);
            icd.release();
            delete h;
            return nullptr;
        }

        // 验证通过 — 把 context + 生命周期管理塞进 runtime handle。
        // 把 icd.lib 所有权交给 h, 防 IcdFns 析构把 OpenCL.dll FreeLibrary 导致后续
        // clReleaseContext 调用悬空函数指针。
        h->ownedClContext      = clCtx;
        h->clLib               = icd.lib;
        h->clReleaseContextFn  = icd.releaseContext;
        icd.lib = nullptr;     // 转移所有权,IcdFns 析构变 no-op

        h->devCtx.platformId   = reqPlat;
        h->devCtx.deviceId     = reqDev;
        h->devCtx.platformSize = 0;       // 0 = MNN 自己再枚举一次(只为 mFirstGPUDevicePtr)
        h->devCtx.contextPtr   = clCtx;   // ⭐ 关键:MNN 看到非空, 走 contextPtr 分支跳过 globalContext
        bc.sharedContext = (void*)&h->devCtx;
    }

    // ── 独立 Executor + ExecutorScope:绕开全局 Executor 的 mRuntimeInfo
    // 按 forwardType 缓存 runtime(导致两 OpenCL RuntimeManager 共享同 runtime)。
    // OPENCL 路径下我们 contextPtr 已经锁死了 device, 即便 Executor 复用 runtime 也无所谓 —
    // 复用的 runtime 也绑在我们这个 context 上。
    std::shared_ptr<Executor> executor = Executor::newExecutor(sc.type, bc, sc.numThread);
    if (!executor) {
        delete h;
        return nullptr;
    }
    std::shared_ptr<Executor::RuntimeManager> rt;
    {
        ExecutorScope scope(executor);
        rt.reset(Executor::RuntimeManager::createRuntimeManager(sc),
                 Executor::RuntimeManager::destroy);
    }
    if (!rt) {
        delete h;
        return nullptr;
    }

    h->executor = std::move(executor);
    h->rt = std::move(rt);
    return h;
}

MNNWRAP_API int32_t yuyi_backend_runtime_set_cache(YuYiMnnRuntimeHandle rt, const char* cacheFilePath) {
    if (rt == nullptr || rt->rt == nullptr || cacheFilePath == nullptr) return MNNWRAP_ERR_INVALID;
    std::lock_guard<std::mutex> g(rt->lock);
    rt->rt->setCache(std::string(cacheFilePath));
    return MNNWRAP_OK;
}

MNNWRAP_API int32_t yuyi_backend_runtime_update_cache(YuYiMnnRuntimeHandle rt) {
    if (rt == nullptr || rt->rt == nullptr) return MNNWRAP_ERR_INVALID;
    std::lock_guard<std::mutex> g(rt->lock);
    rt->rt->updateCache();
    return MNNWRAP_OK;
}

MNNWRAP_API int32_t yuyi_backend_runtime_set_hint(YuYiMnnRuntimeHandle rt, int32_t hintId, int32_t value) {
    if (rt == nullptr || rt->rt == nullptr) return MNNWRAP_ERR_INVALID;
    std::lock_guard<std::mutex> g(rt->lock);
    rt->rt->setHint(static_cast<Interpreter::HintMode>(hintId), value);
    return MNNWRAP_OK;
}

MNNWRAP_API int32_t yuyi_backend_runtime_set_mode(YuYiMnnRuntimeHandle rt, int32_t modeValue) {
    if (rt == nullptr || rt->rt == nullptr) return MNNWRAP_ERR_INVALID;
    std::lock_guard<std::mutex> g(rt->lock);
    rt->rt->setMode(static_cast<Interpreter::SessionMode>(modeValue));
    return MNNWRAP_OK;
}

MNNWRAP_API int32_t yuyi_backend_runtime_actual_forward_type(YuYiMnnRuntimeHandle rt) {
    if (rt == nullptr) return MNNWRAP_ERR_INVALID;
    return fromMnnForward(rt->actualType);
}

MNNWRAP_API void yuyi_backend_runtime_destroy(YuYiMnnRuntimeHandle rt) {
    if (rt == nullptr) return;

    // 关键顺序:先 reset MNN 持有的 executor/rt(让 MNN 内部 OpenCLRuntime 析构,
    // 它会用 mContext 调 clReleaseCommandQueue / clReleaseEvent 等清理 — 此时
    // 我们的 cl_context 必须还活着), 再 clReleaseContext 释放 wrapper 持有的 +1 引用。
    rt->rt.reset();
    rt->executor.reset();

    if (rt->ownedClContext != nullptr && rt->clReleaseContextFn != nullptr) {
        rt->clReleaseContextFn(rt->ownedClContext);
        rt->ownedClContext = nullptr;
    }
    if (rt->clLib != nullptr) {
#if defined(_WIN32) || defined(_WIN64)
        FreeLibrary((HMODULE)rt->clLib);
#else
        dlclose(rt->clLib);
#endif
        rt->clLib = nullptr;
    }
    delete rt;
}

// ---------- Module ----------

static YuYiMnnModuleHandle createModuleFromVars(
    YuYiMnnRuntimeHandle rt,
    Module* raw)
{
    if (raw == nullptr) return nullptr;

    auto* m = new YuYiMnnModule_s();
    m->mod.reset(raw, Module::destroy);
    m->owningRt = rt;

    const Module::Info* info = raw->getInfo();
    if (info != nullptr) {
        m->inputNames  = info->inputNames;
        m->outputNames = info->outputNames;
    }
    m->inputs.resize(m->inputNames.size());
    return m;
}

MNNWRAP_API YuYiMnnModuleHandle yuyi_backend_module_load_from_memory(
    YuYiMnnRuntimeHandle rt,
    const uint8_t* buffer, size_t size,
    int32_t dynamic, int32_t shapeMutable, int32_t rearrange)
{
    if (buffer == nullptr || size == 0) return nullptr;

    Module::Config cfg;
    cfg.dynamic       = dynamic != 0;
    cfg.shapeMutable  = shapeMutable != 0;
    cfg.rearrange     = rearrange != 0;

    Module* raw = nullptr;
    if (rt != nullptr && rt->rt != nullptr) {
        // 在 runtime 关联的独立 Executor scope 下 load,Module 内部的 Express graph
        // 编译走该 Executor 的 runtime 缓存,而非全局单例。
        ExecutorScope scope(rt->executor);
        raw = Module::load({}, {}, buffer, size, rt->rt, &cfg);
    } else {
        raw = Module::load({}, {}, buffer, size, &cfg);
    }
    return createModuleFromVars(rt, raw);
}

MNNWRAP_API YuYiMnnModuleHandle yuyi_backend_module_load_from_file(
    YuYiMnnRuntimeHandle rt,
    const char* filePath,
    int32_t dynamic, int32_t shapeMutable, int32_t rearrange)
{
    if (filePath == nullptr) return nullptr;

    Module::Config cfg;
    cfg.dynamic       = dynamic != 0;
    cfg.shapeMutable  = shapeMutable != 0;
    cfg.rearrange     = rearrange != 0;

    Module* raw = nullptr;
    if (rt != nullptr && rt->rt != nullptr) {
        ExecutorScope scope(rt->executor);
        raw = Module::load({}, {}, filePath, rt->rt, &cfg);
    } else {
        raw = Module::load({}, {}, filePath, &cfg);
    }
    return createModuleFromVars(rt, raw);
}

MNNWRAP_API void yuyi_backend_module_destroy(YuYiMnnModuleHandle m) {
    if (m == nullptr) return;
    // 显式释放 outputs/inputs 引用,再释放 Module
    {
        std::lock_guard<std::mutex> g(m->lock);
        m->inputs.clear();
        m->outputs.clear();
    }
    delete m;
}

MNNWRAP_API int32_t yuyi_backend_module_input_count(YuYiMnnModuleHandle m) {
    if (m == nullptr) return MNNWRAP_ERR_INVALID;
    return (int32_t)m->inputNames.size();
}

MNNWRAP_API int32_t yuyi_backend_module_output_count(YuYiMnnModuleHandle m) {
    if (m == nullptr) return MNNWRAP_ERR_INVALID;
    return (int32_t)m->outputNames.size();
}

MNNWRAP_API size_t yuyi_backend_module_input_name(YuYiMnnModuleHandle m, int32_t idx, char* buf, size_t bufSize) {
    if (m == nullptr || idx < 0 || idx >= (int32_t)m->inputNames.size()) return 0;
    return copyToBuf(m->inputNames[idx], buf, bufSize);
}

MNNWRAP_API size_t yuyi_backend_module_output_name(YuYiMnnModuleHandle m, int32_t idx, char* buf, size_t bufSize) {
    if (m == nullptr || idx < 0 || idx >= (int32_t)m->outputNames.size()) return 0;
    return copyToBuf(m->outputNames[idx], buf, bufSize);
}

MNNWRAP_API int32_t yuyi_backend_module_input_shape(YuYiMnnModuleHandle m, int32_t idx, int32_t* shapeBuf, int32_t bufLen) {
    if (m == nullptr || m->mod == nullptr) return -1;
    const Module::Info* info = m->mod->getInfo();
    if (info == nullptr || idx < 0 || idx >= (int32_t)info->inputs.size()) return -1;
    const auto& dim = info->inputs[idx].dim;
    int32_t rank = (int32_t)dim.size();
    if (shapeBuf != nullptr) {
        int32_t cp = bufLen < rank ? bufLen : rank;
        for (int32_t i = 0; i < cp; ++i) shapeBuf[i] = dim[i];
    }
    return rank;
}

MNNWRAP_API int32_t yuyi_backend_module_set_input_float(
    YuYiMnnModuleHandle m, int32_t inputIdx,
    const int32_t* shape, int32_t shapeLen,
    const float* data, size_t elemCount)
{
    if (m == nullptr || data == nullptr || elemCount == 0) return MNNWRAP_ERR_INVALID;
    if (inputIdx < 0 || inputIdx >= (int32_t)m->inputNames.size()) return MNNWRAP_ERR_INVALID;

    std::lock_guard<std::mutex> g(m->lock);

    INTS dims;
    if (shape != nullptr && shapeLen > 0) {
        dims.assign(shape, shape + shapeLen);
    } else {
        // fallback:用模型自带的 input shape
        const Module::Info* info = m->mod->getInfo();
        if (info != nullptr && inputIdx < (int32_t)info->inputs.size()) {
            dims = info->inputs[inputIdx].dim;
        }
    }

    VARP v = _Input(dims, NCHW, halide_type_of<float>());
    if (v.get() == nullptr) return MNNWRAP_ERR_OOM;
    v->setName(m->inputNames[inputIdx]);

    float* dst = v->writeMap<float>();
    if (dst == nullptr) return MNNWRAP_ERR_OOM;
    size_t total = 1;
    for (int d : dims) total *= (size_t)(d > 0 ? d : 1);
    if (elemCount > total) elemCount = total;
    std::memcpy(dst, data, elemCount * sizeof(float));

    m->inputs[inputIdx] = v;
    return MNNWRAP_OK;
}

MNNWRAP_API int32_t yuyi_backend_module_forward(YuYiMnnModuleHandle m) {
    if (m == nullptr || m->mod == nullptr) return MNNWRAP_ERR_INVALID;
    std::lock_guard<std::mutex> g(m->lock);

    // 校验所有 input 都被设置
    for (size_t i = 0; i < m->inputs.size(); ++i) {
        if (m->inputs[i].get() == nullptr) return MNNWRAP_ERR_INVALID;
    }
    // forward 走 owning runtime 的独立 Executor scope,确保 Express 计算用对的 GPU
    // (避免落到全局单例缓存的"第一个 OpenCL platform"runtime)
    std::unique_ptr<ExecutorScope> scope;
    if (m->owningRt != nullptr && m->owningRt->executor) {
        scope.reset(new ExecutorScope(m->owningRt->executor));
    }
    auto outs = m->mod->onForward(m->inputs);
    if (outs.empty() && !m->outputNames.empty()) return MNNWRAP_ERR_FORWARD;

    // ── GPU output 布局规整 ─────────────────────────────────────────────
    // MNN GPU backend 内部把所有 tensor 都包装成 NC4HW4 (channel 维 4 对齐),
    // readMap<float> 拿到的是 packed 顺序 — 必须 _Convert 到 NCHW 才能给 C#
    // 端按 row-major 解析。
    //
    // 4D (face 三尺度 score/bbox/landmarks):_Convert 路径成熟,直接 OK。
    //
    // 3D (obj_raw [1,8400,6] / similar detection anchor 输出):MNN 内部
    // tensorShapeFormat() 把 3D 强制 coerce 为 4D [N, C=dim1, H=dim2, W=1]
    // 喂给 NC4HW4 -> NCHW 解包 kernel。Intel UHD OpenCL Buffer mode 在 W=1 这种
    // 退化形状上 work-group 步长有 bug(实测 bbox 整体偏移),NVIDIA dGPU 同
    // kernel 巧合上无症状。
    //
    // 修复:对非 4D 输出,显式 _Reshape 到 [d0, d1, ..., 1, ..., 1] 4D(末维补 1),
    // 让 _Convert 走的是「真 4D」语义而不是「coerce-from-non-4D」语义,
    // 并 preserve 原 dim → C# 端 GetOutputShape 仍看到 3D 原形(_Reshape 不改
    // 总元素数,_Convert 做完再 _Reshape 回原 dim)。
    auto reshapeTo4D = [](const std::vector<int>& d) {
        std::vector<int> out{1, 1, 1, 1};
        for (size_t i = 0; i < d.size() && i < 4; ++i) out[i] = d[i];
        return out;
    };
    for (auto& v : outs) {
        if (v.get() == nullptr) continue;
        auto info = v->getInfo();
        if (info == nullptr) continue;
        if (info->order == NCHW && info->dim.size() != 4) {
            // CPU path: order 已经是 NCHW 且非 4D — 无 NC4HW4 packing,跳过 _Convert.
            continue;
        }
        const auto origDim = info->dim;
        if (origDim.size() != 4) {
            // 1D/2D/3D/5D+: reshape 到 4D 走标准 image convert 路径
            v = _Reshape(v, reshapeTo4D(origDim), NCHW);
        }
        v = _Convert(v, NCHW);
        if (origDim.size() != 4) {
            // squeeze 回原 dim,让 output_shape API 返回 [1, 8400, 6] 等原形
            v = _Reshape(v, origDim, NCHW);
        }
    }
    m->outputs = std::move(outs);
    return MNNWRAP_OK;
}

MNNWRAP_API int32_t yuyi_backend_module_output_shape(YuYiMnnModuleHandle m, int32_t idx, int32_t* shapeBuf, int32_t bufLen) {
    if (m == nullptr || idx < 0 || idx >= (int32_t)m->outputs.size()) return -1;
    auto var = m->outputs[idx];
    if (var.get() == nullptr) return -1;
    const Variable::Info* info = var->getInfo();
    if (info == nullptr) return -1;
    int32_t rank = (int32_t)info->dim.size();
    if (shapeBuf != nullptr) {
        int32_t cp = bufLen < rank ? bufLen : rank;
        for (int32_t i = 0; i < cp; ++i) shapeBuf[i] = info->dim[i];
    }
    return rank;
}

MNNWRAP_API int64_t yuyi_backend_module_output_size(YuYiMnnModuleHandle m, int32_t idx) {
    if (m == nullptr || idx < 0 || idx >= (int32_t)m->outputs.size()) return -1;
    auto var = m->outputs[idx];
    if (var.get() == nullptr) return -1;
    const Variable::Info* info = var->getInfo();
    if (info == nullptr) return -1;
    int64_t total = 1;
    for (int d : info->dim) total *= (int64_t)(d > 0 ? d : 1);
    return total;
}

MNNWRAP_API int64_t yuyi_backend_module_output_data_float(
    YuYiMnnModuleHandle m, int32_t idx, float* dst, size_t dstElemCount)
{
    if (m == nullptr || dst == nullptr || idx < 0 || idx >= (int32_t)m->outputs.size()) return -1;
    auto var = m->outputs[idx];
    if (var.get() == nullptr) return -1;
    const Variable::Info* info = var->getInfo();
    if (info == nullptr) return -1;
    int64_t total = 1;
    for (int d : info->dim) total *= (int64_t)(d > 0 ? d : 1);
    if (total <= 0) return 0;
    int64_t copyN = (int64_t)dstElemCount < total ? (int64_t)dstElemCount : total;

    const float* src = var->readMap<float>();
    if (src == nullptr) return -1;
    std::memcpy(dst, src, copyN * sizeof(float));
    return copyN;
}

MNNWRAP_API void yuyi_backend_module_clear_cache(YuYiMnnModuleHandle m) {
    if (m == nullptr || m->mod == nullptr) return;
    std::lock_guard<std::mutex> g(m->lock);
    m->mod->clearCache();
}

} // extern "C"
