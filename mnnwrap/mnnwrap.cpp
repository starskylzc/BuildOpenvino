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

extern "C" void yuyi_backend_native_log(const char* fmt, ...) {
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
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) {
        buf[--len] = '\0';
    }
    cb(buf);
}

// ============================== 内部结构 ==============================

struct YuYiMnnRuntime_s {
    // 每个 RuntimeManager 配独立 Executor + 独立 MNNDeviceContext。
    // GPU 路径用 MNNDeviceContext.platformId 显式指定 OpenCL platform,
    // 绕开 MNN OpenCLRuntime 的 envPlatId getenv 路径 + globalContext 缓存
    // (那条路径 process 级共享,会让选 iGPU 实际跑 dGPU)。
    std::shared_ptr<Executor> executor;
    std::shared_ptr<Executor::RuntimeManager> rt;
    MNNDeviceContext devCtx;   // 持有 backendConfig.sharedContext 指向的内容
    MNNForwardType actualType = MNN_FORWARD_CPU;
    std::mutex lock;
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

// ============================== API ==============================

extern "C" {

MNNWRAP_API const char* yuyi_backend_version(void) {
    return getVersion();
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

    ScheduleConfig sc;
    sc.type       = toMnnForward(cfg->forwardType);
    sc.numThread  = cfg->numThread > 0 ? cfg->numThread : 1;
    sc.backupType = MNN_FORWARD_CPU;

    BackendConfig bc;
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

    // ── 提前分配 runtime handle,持有 MNNDeviceContext + Executor 生命周期 ──
    auto* h = new YuYiMnnRuntime_s();
    h->actualType = sc.type;

    // ── GPU 路径:用 MNNDeviceContext.platformId 直接指定 OpenCL platform ──
    // 通过 BackendConfig.sharedContext 传给 MNN,OpenCLBackend.cpp 直接用这个
    // platformId 给 OpenCLRuntime ctor,**完全绕开 envPlatId getenv 路径** +
    // **跨 RuntimeManager 共享 cl::Context 全局缓存的副作用**。
    // 比 setenv("MNN_OPENCL_PLATFORM_ID")可靠:env 是 process 单例,多 GPU 切换
    // 时容易踩 once-only 陷阱;sharedContext 是 per-RuntimeManager 显式参数。
    if (sc.type == MNN_FORWARD_OPENCL || sc.type == MNN_FORWARD_CUDA) {
        h->devCtx.platformId   = (uint32_t)(cfg->gpuDeviceId >= 0 ? cfg->gpuDeviceId : 0);
        h->devCtx.deviceId     = 0;
        h->devCtx.platformSize = 0;     // 0 = MNN 自动探测平台数量
        h->devCtx.contextPtr   = nullptr; // null = MNN 内部 clCreateContext(用我们指定的 platform)
        bc.sharedContext = (void*)&h->devCtx;
    }

    // ── 独立 Executor + ExecutorScope:绕开全局 Executor 的 mRuntimeInfo
    // 按 forwardType 缓存 runtime(导致两 OpenCL RuntimeManager 共享同 runtime)。
    // newExecutor 内部 onCreate 时 sharedContext 还没传(via newExecutor 不接受 sc),
    // 所以 newExecutor 创的 runtime 仍可能用默认 platform — 但下面 createRuntimeManager
    // 会用 ScheduleConfig 重建 runtime,带 sharedContext.platformId,真正生效。
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
