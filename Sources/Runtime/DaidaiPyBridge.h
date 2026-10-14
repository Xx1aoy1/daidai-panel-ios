//
//  DaidaiPyBridge.h
//  daidai-panel
//
//  刻意不 include <Python/Python.h>：这个头文件会被 Bridging Header 引入到
//  Swift，而 CPython 的大量宏无法被 Swift 正确导入。所有 Python C API 调用都
//  封装在 .c 里，Swift 只看到不透明句柄。
//

#ifndef DAIDAI_PY_BRIDGE_H
#define DAIDAI_PY_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// stdout / stderr 回调。text 是 UTF-8 C 字符串，不要长期持有。
typedef void (*DaidaiPyWriteHook)(const char *text, int is_stderr);

/// 通用回调：返回 malloc 分配的 UTF-8 字符串，由桥接层 free。
typedef char *(*DaidaiPyCallHook)(const char *op, const char *a, const char *b);

/// 注册回调。必须在 daidai_py_bootstrap 之前调用。
void daidai_py_set_hooks(DaidaiPyWriteHook write_hook, DaidaiPyCallHook call_hook);

/// 启动解释器、注册 daidai_bridge 模块、把 sys.stdout/stderr 重定向到回调。
/// 返回 0 表示成功，非 0 表示失败。
int daidai_py_bootstrap(void);

/// 解释器是否已就绪
int daidai_py_ready(void);

/// 当前线程获取 / 释放 GIL（内部配对使用，基于 PyGILState）
void daidai_py_acquire_gil(void);
void daidai_py_release_gil(void);

/// 在已持有 GIL 的前提下执行源码。filename 仅用于 traceback 显示。
/// 返回 0 成功，非 0 失败（失败时已把 traceback 打到回调）。
int daidai_py_exec(const char *source, const char *filename);

/// 设置 os.environ（需已持有 GIL）
void daidai_py_set_env(const char *key, const char *value);

/// 释放解释器（一般不用调用）
void daidai_py_finalize(void);

#ifdef __cplusplus
}
#endif

#endif /* DAIDAI_PY_BRIDGE_H */
