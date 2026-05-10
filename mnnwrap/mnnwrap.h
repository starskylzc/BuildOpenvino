// =====================================================================
// mnnwrap — MNN C++ → C ABI wrapper for .NET P/Invoke (跨平台稳定符号)
//
// MNN 主库导出的是 C++ 类(MNN::Interpreter / MNN::Express::Module),C# P/Invoke
// 没法跨编译器(MSVC / clang / gcc)稳定 mangling。本 wrapper 把 Module API 包成
// 干净的 C 函数,产物 mnnwrap.dll / libmnnwrap.so / libmnnwrap.dylib 跟 MNN 主库
// 同 RID 编一份,8 RID 覆盖 win/mac/linux + x64/x86/arm64/loongarch64。
//
// 设计原则:
//   1. 全 C ABI (extern "C"),零 STL 跨边界
//   2. 不抛异常(MNN 自身 -fno-exceptions),错误码返回
//   3. Handle 不透明(opaque),C# 拿 IntPtr,生命周期 explicit
//   4. 输入/输出走 caller-provided buffer,wrapper 不分配返还(避免 marshal 抖动)
//   5. 字符串 UTF-8,长度通过两次调用模式获得(先 size_t,再 buf)
// =====================================================================

#ifndef MNNWRAP_H
#define MNNWRAP_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) || defined(_WIN64)
  #ifdef MNNWRAP_BUILDING
    #define MNNWRAP_API __declspec(dllexport)
  #else
    #define MNNWRAP_API __declspec(dllimport)
  #endif
#else
  #define MNNWRAP_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// ----------------------------- 错误码 -----------------------------
#define MNNWRAP_OK              0
#define MNNWRAP_ERR_INVALID    -1
#define MNNWRAP_ERR_NOT_FOUND  -2
#define MNNWRAP_ERR_LOAD       -3
#define MNNWRAP_ERR_FORWARD    -4
#define MNNWRAP_ERR_OOM        -5
#define MNNWRAP_ERR_NO_RUNTIME -6

// ----------------------------- 枚举 -----------------------------
// 跟 MNN_FORWARD_TYPE 对齐(MNNForwardType.h)
typedef enum {
    MNNWRAP_FORWARD_AUTO   = 4,  // MNN_FORWARD_AUTO,自动按 schedule 选最优
    MNNWRAP_FORWARD_CPU    = 0,
    MNNWRAP_FORWARD_OPENCL = 3,
    MNNWRAP_FORWARD_METAL  = 1,
    MNNWRAP_FORWARD_CUDA   = 2,
    MNNWRAP_FORWARD_VULKAN = 7,
    MNNWRAP_FORWARD_NN     = 5,  // CoreML on Mac
} MnnWrapForwardType;

typedef enum {
    MNNWRAP_PRECISION_NORMAL = 0,
    MNNWRAP_PRECISION_HIGH   = 1,  // fp32 计算
    MNNWRAP_PRECISION_LOW    = 2,  // fp16 计算
    MNNWRAP_PRECISION_LOW_BF16 = 3,
} MnnWrapPrecision;

typedef enum {
    MNNWRAP_MEMORY_NORMAL = 0,
    MNNWRAP_MEMORY_HIGH   = 1,
    MNNWRAP_MEMORY_LOW    = 2,  // 推荐:省 RAM
} MnnWrapMemoryMode;

typedef enum {
    MNNWRAP_POWER_NORMAL = 0,
    MNNWRAP_POWER_HIGH   = 1,  // 抢线程 / GPU 高频
    MNNWRAP_POWER_LOW    = 2,  // 节能
} MnnWrapPowerMode;

// ----------------------------- Handle -----------------------------
typedef struct YuYiMnnRuntime_s* YuYiMnnRuntimeHandle;
typedef struct YuYiMnnModule_s*  YuYiMnnModuleHandle;

// ----------------------------- 配置 -----------------------------
typedef struct {
    int32_t forwardType;     // MnnWrapForwardType
    int32_t numThread;       // CPU 线程数 / GPU mode 标志(GPU 用 mode_id 表示 tuning level)
    int32_t precision;       // MnnWrapPrecision
    int32_t memory;          // MnnWrapMemoryMode
    int32_t power;           // MnnWrapPowerMode
    int32_t gpuDeviceId;     // OpenCL platform_id / CUDA device_id;0 默认
    int32_t reserved0;       // 4-byte pad,保持 32-byte 对齐
    int32_t reserved1;
} YuYiMnnRuntimeConfig;

// ----------------------------- API -----------------------------

/// 库版本字符串("3.5.0" 等)。
MNNWRAP_API const char* yuyi_backend_version(void);

/// MNN 编译期开启的 backend 类型集合 — 调用者传 buf 接收 MnnWrapForwardType 枚举数组,
/// 返回 backend 数量。可用于 .NET 探测当前 native 是否支持 OpenCL / Metal 等。
MNNWRAP_API int32_t yuyi_backend_available_backends(int32_t* outBuf, int32_t bufLen);

/// 创建 RuntimeManager(可被多个 Module 共享,显著节省内存 / 缓存复用)。
/// 返回 handle 或 NULL(失败)。
MNNWRAP_API YuYiMnnRuntimeHandle yuyi_backend_runtime_create(const YuYiMnnRuntimeConfig* cfg);

/// 设置 cache 文件路径(用于自动 tune cache,GPU schedule 复用),create_module 之前调。
MNNWRAP_API int32_t yuyi_backend_runtime_set_cache(YuYiMnnRuntimeHandle rt, const char* cacheFilePath);

/// 触发 cache 写盘(在所有 module 加载完后调)。
MNNWRAP_API int32_t yuyi_backend_runtime_update_cache(YuYiMnnRuntimeHandle rt);

// HintMode 整数对齐 MNN::Interpreter::HintMode(详见 Interpreter.hpp)
//   0 MAX_TUNING_NUMBER       GPU async tuning op 数量
//   1 STRICT_CHECK_MODEL      默认 1=校验模型;0=跳过(更快启动)
//   2 MEM_ALLOCATOR_TYPE      内存分配器类型
//   3 WINOGRAD_MEMORY_LEVEL   默认 3;0=最少候选(省内存,慢)
//   4 GEOMETRY_COMPUTE_MASK   默认 0xFFFF;子掩码 1=FUSEREGION 2=FUSEREGION_MULTI 4=USELOOP 8=OPENCACHE
//   5 DYNAMIC_QUANT_OPTIONS   动态量化(本项目不用)
//   6 CPU_LITTLECORE_DECREASE_RATE  big.LITTLE CPU(移动端)
//   9 OP_ENCODER_NUMBER_FOR_COMMIT  Metal/CUDA op 提交批量
//  13 INIT_THREAD_NUMBER      模型并行加载线程数,默认 0=单线程加载
//  16 CPU_ENABLE_KLEIDIAI     ARM KleidiAI
MNNWRAP_API int32_t yuyi_backend_runtime_set_hint(YuYiMnnRuntimeHandle rt, int32_t hintId, int32_t value);

// SessionMode 整数对齐 MNN::Interpreter::SessionMode:
//   0/1   Session_Debug / Session_Release
//   2/3   Session_Input_Inside / Session_Input_User
//   4/5   Session_Output_Inside / Session_Output_User
//   6/7   Session_Resize_Direct / Session_Resize_Defer
//   8/9   Session_Backend_Fix / Session_Backend_Auto
//   10/11 Session_Memory_Collect / Session_Memory_Cache
//   12/13 Session_Codegen_Disable / Session_Codegen_Enable
//   14/15 Session_Resize_Check / Session_Resize_Fix
//   16/17 Module_Forward_Separate / Module_Forward_Combine
MNNWRAP_API int32_t yuyi_backend_runtime_set_mode(YuYiMnnRuntimeHandle rt, int32_t modeValue);

/// 实际使用的 forward type(GPU 失败 fallback CPU 后的真实值)。返回 MnnWrapForwardType 或负数错误。
MNNWRAP_API int32_t yuyi_backend_runtime_actual_forward_type(YuYiMnnRuntimeHandle rt);

/// 销毁 runtime。所有 module 必须先销毁。
MNNWRAP_API void yuyi_backend_runtime_destroy(YuYiMnnRuntimeHandle rt);

/// **主路径**: 从内存解密的 byte[] 加载 module。runtime 可为 NULL(创建独立 runtime)。
/// dynamic=0 静态(更快,推荐),shapeMutable=0 输入形状固定(更省内存)。
/// 返回 handle 或 NULL。
MNNWRAP_API YuYiMnnModuleHandle yuyi_backend_module_load_from_memory(
    YuYiMnnRuntimeHandle rt,
    const uint8_t* buffer, size_t size,
    int32_t dynamic, int32_t shapeMutable, int32_t rearrange);

/// 从文件路径加载 module(诊断 / 测试用,生产走 from_memory)。
MNNWRAP_API YuYiMnnModuleHandle yuyi_backend_module_load_from_file(
    YuYiMnnRuntimeHandle rt,
    const char* filePath,
    int32_t dynamic, int32_t shapeMutable, int32_t rearrange);

/// 销毁 module。
MNNWRAP_API void yuyi_backend_module_destroy(YuYiMnnModuleHandle m);

/// 输入张量个数。
MNNWRAP_API int32_t yuyi_backend_module_input_count(YuYiMnnModuleHandle m);
/// 输出张量个数。
MNNWRAP_API int32_t yuyi_backend_module_output_count(YuYiMnnModuleHandle m);

/// 取第 idx 个输入名字(UTF-8,NUL-terminated)。返回**包含 NUL 的字节数**(包括需要的);
/// buf=NULL 或 bufSize=0 时仅返回需要长度,不写。
MNNWRAP_API size_t yuyi_backend_module_input_name(YuYiMnnModuleHandle m, int32_t idx, char* buf, size_t bufSize);
MNNWRAP_API size_t yuyi_backend_module_output_name(YuYiMnnModuleHandle m, int32_t idx, char* buf, size_t bufSize);

/// 取第 idx 个输入的形状(rank 维度数)。shapeBuf 接收 rank 个 int32(若 bufLen >= rank);
/// 返回 rank;rank>bufLen 时返回 rank 但不写满。-1 表示 idx 越界。
MNNWRAP_API int32_t yuyi_backend_module_input_shape(YuYiMnnModuleHandle m, int32_t idx, int32_t* shapeBuf, int32_t bufLen);

/// **核心**: 设置第 inputIdx 个输入的 NCHW float32 数据。shape 给当前形状(动态尺寸),
/// 若 shape=NULL 则保留模型原 shape;data 为 caller buffer,wrapper 内部拷贝。
MNNWRAP_API int32_t yuyi_backend_module_set_input_float(
    YuYiMnnModuleHandle m,
    int32_t inputIdx,
    const int32_t* shape, int32_t shapeLen,
    const float* data, size_t elemCount);

/// **核心**: 跑一帧推理。返回 MNNWRAP_OK 或负数错误。
MNNWRAP_API int32_t yuyi_backend_module_forward(YuYiMnnModuleHandle m);

/// 取第 outputIdx 输出的 shape。返回 rank;-1 越界。
MNNWRAP_API int32_t yuyi_backend_module_output_shape(YuYiMnnModuleHandle m, int32_t idx, int32_t* shapeBuf, int32_t bufLen);

/// 取第 outputIdx 输出的 float 元素数(rank shape 各维相乘)。-1 越界 / 0 = 空。
MNNWRAP_API int64_t yuyi_backend_module_output_size(YuYiMnnModuleHandle m, int32_t idx);

/// 把第 outputIdx 输出的 float 数据拷到 caller buffer。dstElemCount 必须 ≥ output_size,否则截断到 dstElemCount。
/// 返回实际写入的元素数;<0 错误。
MNNWRAP_API int64_t yuyi_backend_module_output_data_float(
    YuYiMnnModuleHandle m, int32_t idx, float* dst, size_t dstElemCount);

/// 释放 module 的中间缓存(慢但省内存,通常不需要在热路径调)。
MNNWRAP_API void yuyi_backend_module_clear_cache(YuYiMnnModuleHandle m);

#ifdef __cplusplus
}
#endif

#endif // MNNWRAP_H
