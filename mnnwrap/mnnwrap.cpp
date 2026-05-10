// =====================================================================
// mnnwrap — implementation. Wraps MNN::Express::Module API in C ABI.
// =====================================================================

#define MNNWRAP_BUILDING

#include "mnnwrap.h"

#include <MNN/MNNDefine.h>
#include <MNN/MNNForwardType.h>
#include <MNN/expr/Module.hpp>
#include <MNN/expr/Expr.hpp>
#include <MNN/expr/ExprCreator.hpp>
#include <MNN/expr/Executor.hpp>
#include <MNN/expr/NeuralNetWorkOp.hpp>
#include <MNN/Interpreter.hpp>

#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

using namespace MNN;
using namespace MNN::Express;

// ============================== 内部结构 ==============================

struct YuYiMnnRuntime_s {
    std::shared_ptr<Executor::RuntimeManager> rt;
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

MNNWRAP_API const char* yuyi_mnn_version(void) {
    return getVersion();
}

MNNWRAP_API int32_t yuyi_mnn_available_backends(int32_t* outBuf, int32_t bufLen) {
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

MNNWRAP_API YuYiMnnRuntimeHandle yuyi_mnn_runtime_create(const YuYiMnnRuntimeConfig* cfg) {
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

    std::shared_ptr<Executor::RuntimeManager> rt(
        Executor::RuntimeManager::createRuntimeManager(sc),
        Executor::RuntimeManager::destroy);
    if (!rt) return nullptr;

    // GPU device id 在 MNN 中不通过 Hint 设置:
    //   - OpenCL: 走环境变量 MNN_OPENCL_PLATFORM_ID(见 bench 脚本实测,P/Invoke 调用前 setenv)
    //   - CUDA: 走 BackendConfig.sharedContext(本项目编译矩阵未启用 CUDA)
    // 调用方应该在创建 runtime 之前设好 env var(C# 用 Environment.SetEnvironmentVariable)。
    (void)cfg->gpuDeviceId;

    auto* h = new YuYiMnnRuntime_s();
    h->rt = std::move(rt);
    h->actualType = sc.type;
    return h;
}

MNNWRAP_API int32_t yuyi_mnn_runtime_set_cache(YuYiMnnRuntimeHandle rt, const char* cacheFilePath) {
    if (rt == nullptr || rt->rt == nullptr || cacheFilePath == nullptr) return MNNWRAP_ERR_INVALID;
    std::lock_guard<std::mutex> g(rt->lock);
    rt->rt->setCache(std::string(cacheFilePath));
    return MNNWRAP_OK;
}

MNNWRAP_API int32_t yuyi_mnn_runtime_update_cache(YuYiMnnRuntimeHandle rt) {
    if (rt == nullptr || rt->rt == nullptr) return MNNWRAP_ERR_INVALID;
    std::lock_guard<std::mutex> g(rt->lock);
    rt->rt->updateCache();
    return MNNWRAP_OK;
}

MNNWRAP_API int32_t yuyi_mnn_runtime_set_hint(YuYiMnnRuntimeHandle rt, int32_t hintId, int32_t value) {
    if (rt == nullptr || rt->rt == nullptr) return MNNWRAP_ERR_INVALID;
    std::lock_guard<std::mutex> g(rt->lock);
    rt->rt->setHint(static_cast<Interpreter::HintMode>(hintId), value);
    return MNNWRAP_OK;
}

MNNWRAP_API int32_t yuyi_mnn_runtime_set_mode(YuYiMnnRuntimeHandle rt, int32_t modeValue) {
    if (rt == nullptr || rt->rt == nullptr) return MNNWRAP_ERR_INVALID;
    std::lock_guard<std::mutex> g(rt->lock);
    rt->rt->setMode(static_cast<Interpreter::SessionMode>(modeValue));
    return MNNWRAP_OK;
}

MNNWRAP_API int32_t yuyi_mnn_runtime_actual_forward_type(YuYiMnnRuntimeHandle rt) {
    if (rt == nullptr) return MNNWRAP_ERR_INVALID;
    return fromMnnForward(rt->actualType);
}

MNNWRAP_API void yuyi_mnn_runtime_destroy(YuYiMnnRuntimeHandle rt) {
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

MNNWRAP_API YuYiMnnModuleHandle yuyi_mnn_module_load_from_memory(
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
        raw = Module::load({}, {}, buffer, size, rt->rt, &cfg);
    } else {
        raw = Module::load({}, {}, buffer, size, &cfg);
    }
    return createModuleFromVars(rt, raw);
}

MNNWRAP_API YuYiMnnModuleHandle yuyi_mnn_module_load_from_file(
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
        raw = Module::load({}, {}, filePath, rt->rt, &cfg);
    } else {
        raw = Module::load({}, {}, filePath, &cfg);
    }
    return createModuleFromVars(rt, raw);
}

MNNWRAP_API void yuyi_mnn_module_destroy(YuYiMnnModuleHandle m) {
    if (m == nullptr) return;
    // 显式释放 outputs/inputs 引用,再释放 Module
    {
        std::lock_guard<std::mutex> g(m->lock);
        m->inputs.clear();
        m->outputs.clear();
    }
    delete m;
}

MNNWRAP_API int32_t yuyi_mnn_module_input_count(YuYiMnnModuleHandle m) {
    if (m == nullptr) return MNNWRAP_ERR_INVALID;
    return (int32_t)m->inputNames.size();
}

MNNWRAP_API int32_t yuyi_mnn_module_output_count(YuYiMnnModuleHandle m) {
    if (m == nullptr) return MNNWRAP_ERR_INVALID;
    return (int32_t)m->outputNames.size();
}

MNNWRAP_API size_t yuyi_mnn_module_input_name(YuYiMnnModuleHandle m, int32_t idx, char* buf, size_t bufSize) {
    if (m == nullptr || idx < 0 || idx >= (int32_t)m->inputNames.size()) return 0;
    return copyToBuf(m->inputNames[idx], buf, bufSize);
}

MNNWRAP_API size_t yuyi_mnn_module_output_name(YuYiMnnModuleHandle m, int32_t idx, char* buf, size_t bufSize) {
    if (m == nullptr || idx < 0 || idx >= (int32_t)m->outputNames.size()) return 0;
    return copyToBuf(m->outputNames[idx], buf, bufSize);
}

MNNWRAP_API int32_t yuyi_mnn_module_input_shape(YuYiMnnModuleHandle m, int32_t idx, int32_t* shapeBuf, int32_t bufLen) {
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

MNNWRAP_API int32_t yuyi_mnn_module_set_input_float(
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

MNNWRAP_API int32_t yuyi_mnn_module_forward(YuYiMnnModuleHandle m) {
    if (m == nullptr || m->mod == nullptr) return MNNWRAP_ERR_INVALID;
    std::lock_guard<std::mutex> g(m->lock);

    // 校验所有 input 都被设置
    for (size_t i = 0; i < m->inputs.size(); ++i) {
        if (m->inputs[i].get() == nullptr) return MNNWRAP_ERR_INVALID;
    }
    auto outs = m->mod->onForward(m->inputs);
    if (outs.empty() && !m->outputNames.empty()) return MNNWRAP_ERR_FORWARD;

    // GPU backend (OpenCL/Metal/CUDA/Vulkan) 内部用 NC4HW4 packed 格式,
    // readMap<float> 直接读得到 NC4HW4 顺序的数据 — 上层 C# 解析按 NCHW 当
    // [B,N,C] 处理时通道全错(YOLO obj_raw 的 score/bbox 字段都会乱)。
    // 强制 _Convert 到 NCHW,统一输出布局给所有 backend(CPU 也是 NCHW,
    // _Convert noop 通过)。
    for (auto& v : outs) {
        if (v.get() != nullptr) {
            v = _Convert(v, NCHW);
        }
    }
    m->outputs = std::move(outs);
    return MNNWRAP_OK;
}

MNNWRAP_API int32_t yuyi_mnn_module_output_shape(YuYiMnnModuleHandle m, int32_t idx, int32_t* shapeBuf, int32_t bufLen) {
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

MNNWRAP_API int64_t yuyi_mnn_module_output_size(YuYiMnnModuleHandle m, int32_t idx) {
    if (m == nullptr || idx < 0 || idx >= (int32_t)m->outputs.size()) return -1;
    auto var = m->outputs[idx];
    if (var.get() == nullptr) return -1;
    const Variable::Info* info = var->getInfo();
    if (info == nullptr) return -1;
    int64_t total = 1;
    for (int d : info->dim) total *= (int64_t)(d > 0 ? d : 1);
    return total;
}

MNNWRAP_API int64_t yuyi_mnn_module_output_data_float(
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

MNNWRAP_API void yuyi_mnn_module_clear_cache(YuYiMnnModuleHandle m) {
    if (m == nullptr || m->mod == nullptr) return;
    std::lock_guard<std::mutex> g(m->lock);
    m->mod->clearCache();
}

} // extern "C"
