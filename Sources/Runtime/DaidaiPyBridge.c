//
//  DaidaiPyBridge.c
//  daidai-panel
//
//  嵌入 CPython 所需的最小 C 层。
//

#include "DaidaiPyBridge.h"

#include <Python/Python.h>

#include <stdlib.h>
#include <string.h>

static DaidaiPyWriteHook g_write_hook = NULL;
static DaidaiPyCallHook  g_call_hook  = NULL;
static int g_ready = 0;

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
static _Thread_local PyGILState_STATE t_gil_state;
static _Thread_local int t_gil_held = 0;
#else
static PyGILState_STATE t_gil_state;
static int t_gil_held = 0;
#endif

// ---------------------------------------------------------------------------
// 暴露给 Python 的 daidai_bridge 模块
// ---------------------------------------------------------------------------

static PyObject *dd_write(PyObject *self, PyObject *args)
{
    (void)self;
    const char *text = NULL;
    int is_err = 0;
    if (!PyArg_ParseTuple(args, "si", &text, &is_err)) {
        return NULL;
    }
    if (g_write_hook && text) {
        g_write_hook(text, is_err);
    }
    Py_RETURN_NONE;
}

static PyObject *dd_call(PyObject *self, PyObject *args)
{
    (void)self;
    const char *op = NULL;
    const char *a = "";
    const char *b = "";
    if (!PyArg_ParseTuple(args, "s|ss", &op, &a, &b)) {
        return NULL;
    }
    if (!g_call_hook || !op) {
        Py_RETURN_NONE;
    }
    char *out = g_call_hook(op, a, b);
    if (!out) {
        Py_RETURN_NONE;
    }
    PyObject *res = PyUnicode_FromString(out);
    free(out);
    if (!res) {
        return NULL;
    }
    return res;
}

static PyMethodDef dd_methods[] = {
    {"write", dd_write, METH_VARARGS, "把文本送回宿主 App"},
    {"call",  dd_call,  METH_VARARGS, "通用调用（bark / crypto / http / fs）"},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef dd_module = {
    PyModuleDef_HEAD_INIT,
    "daidai_bridge",
    "daidai-panel 宿主桥接",
    -1,
    dd_methods,
    NULL, NULL, NULL, NULL
};

PyMODINIT_FUNC PyInit_daidai_bridge(void)
{
    return PyModule_Create(&dd_module);
}

// ---------------------------------------------------------------------------
// stdout / stderr 重定向（纯 Python 实现，逐次运行共用）
// ---------------------------------------------------------------------------

static const char *kRedirectCode =
"import sys\n"
"try:\n"
"    import daidai_bridge as _ddb\n"
"except Exception:\n"
"    _ddb = None\n"
"\n"
"class _DaidaiStream(object):\n"
"    encoding = 'utf-8'\n"
"    errors = 'replace'\n"
"    def __init__(self, is_err):\n"
"        self._is_err = is_err\n"
"    def write(self, s):\n"
"        if not s:\n"
"            return 0\n"
"        if not isinstance(s, str):\n"
"            s = str(s)\n"
"        if _ddb is not None:\n"
"            try:\n"
"                _ddb.write(s, 1 if self._is_err else 0)\n"
"            except Exception:\n"
"                pass\n"
"        return len(s)\n"
"    def writelines(self, lines):\n"
"        for line in lines:\n"
"            self.write(line)\n"
"    def flush(self):\n"
"        pass\n"
"    def close(self):\n"
"        pass\n"
"    def isatty(self):\n"
"        return False\n"
"    def readable(self):\n"
"        return False\n"
"    def writable(self):\n"
"        return True\n"
"    def seekable(self):\n"
"        return False\n"
"    def fileno(self):\n"
"        raise OSError('daidai-panel 的 stdout 没有文件描述符')\n"
"\n"
"sys.stdout = _DaidaiStream(False)\n"
"sys.stderr = _DaidaiStream(True)\n";

// ---------------------------------------------------------------------------
// 公共 API
// ---------------------------------------------------------------------------

void daidai_py_set_hooks(DaidaiPyWriteHook write_hook, DaidaiPyCallHook call_hook)
{
    g_write_hook = write_hook;
    g_call_hook = call_hook;
}

int daidai_py_ready(void)
{
    return g_ready && Py_IsInitialized();
}

int daidai_py_bootstrap(void)
{
    if (daidai_py_ready()) {
        return 0;
    }

    PyImport_AppendInittab("daidai_bridge", PyInit_daidai_bridge);
    Py_Initialize();

    if (!Py_IsInitialized()) {
        return -1;
    }

    // 此时 GIL 由当前（初始化）线程持有，可以直接调用 C API
    PyObject *modules = PyImport_GetModuleDict();
    if (modules) {
        PyObject *m = PyModule_Create(&dd_module);
        if (m) {
            PyDict_SetItemString(modules, "daidai_bridge", m);
            Py_DECREF(m);
        }
    }

    if (PyRun_SimpleString(kRedirectCode) != 0) {
        PyErr_Print();
    }

    g_ready = 1;

    // 释放 GIL：此后所有工作线程都用 PyGILState_Ensure / Release 配对获取。
    // 不释放的话，其它线程会在 PyGILState_Ensure 上永久阻塞。
    PyEval_SaveThread();

    return 0;
}

void daidai_py_acquire_gil(void)
{
    if (!Py_IsInitialized()) {
        return;
    }
    if (t_gil_held) {
        return;
    }
    t_gil_state = PyGILState_Ensure();
    t_gil_held = 1;
}

void daidai_py_release_gil(void)
{
    if (!Py_IsInitialized()) {
        return;
    }
    if (!t_gil_held) {
        return;
    }
    PyGILState_Release(t_gil_state);
    t_gil_held = 0;
}

int daidai_py_exec(const char *source, const char *filename)
{
    if (!daidai_py_ready() || !source) {
        return -1;
    }

    PyObject *globals = PyDict_New();
    if (!globals) {
        return -1;
    }

    PyObject *v;
    v = PyUnicode_FromString("__main__");
    if (v) { PyDict_SetItemString(globals, "__name__", v); Py_DECREF(v); }

    v = PyUnicode_FromString(filename ? filename : "script.py");
    if (v) { PyDict_SetItemString(globals, "__file__", v); Py_DECREF(v); }

    v = PyUnicode_FromString("daidai-panel");
    if (v) { PyDict_SetItemString(globals, "__package__", v); Py_DECREF(v); }

    PyObject *builtins = PyEval_GetBuiltins();
    if (builtins) {
        PyDict_SetItemString(globals, "__builtins__", builtins);
    }

    int rc = 0;
    PyObject *result = PyRun_String(source, Py_file_input, globals, globals);
    if (result == NULL) {
        PyErr_Print();
        rc = -1;
    } else {
        Py_DECREF(result);
    }

    Py_DECREF(globals);
    return rc;
}

void daidai_py_set_env(const char *key, const char *value)
{
    if (!daidai_py_ready() || !key) {
        return;
    }
    PyObject *os_mod = PyImport_ImportModule("os");
    if (!os_mod) {
        PyErr_Clear();
        return;
    }
    PyObject *environ = PyObject_GetAttrString(os_mod, "environ");
    if (environ) {
        PyObject *k = PyUnicode_FromString(key);
        PyObject *v = PyUnicode_FromString(value ? value : "");
        if (k && v) {
            PyObject_SetItem(environ, k, v);
        }
        Py_XDECREF(k);
        Py_XDECREF(v);
        Py_DECREF(environ);
    }
    PyErr_Clear();
    Py_DECREF(os_mod);
}

void daidai_py_finalize(void)
{
    if (!Py_IsInitialized()) {
        return;
    }
    PyGILState_Ensure();
    Py_FinalizeEx();
    g_ready = 0;
}
