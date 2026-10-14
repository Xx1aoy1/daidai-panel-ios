/* 代代面板 · 内置前端
   纯浏览器 JS，跑在手机本机的 127.0.0.1:5700 上。 */

var TOKEN = localStorage.getItem('ddp_token') || '';
var state = { tab: 'overview', status: {}, scripts: [], logs: [], env: [], settings: {}, logDetail: null };
var refreshTimer = null;

// ---------------------------------------------------------------- 基础工具

function h(tag, attrs, children) {
  var e = document.createElement(tag);
  attrs = attrs || {};
  Object.keys(attrs).forEach(function (k) {
    if (k === 'class') e.className = attrs[k];
    else if (k === 'html') e.innerHTML = attrs[k];
    else if (k === 'text') e.textContent = attrs[k];
    else if (k.indexOf('on') === 0) e.addEventListener(k.slice(2), attrs[k]);
    else if (attrs[k] !== null && attrs[k] !== undefined) e.setAttribute(k, attrs[k]);
  });
  (children || []).forEach(function (c) {
    if (c === null || c === undefined) return;
    e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
  });
  return e;
}

function toast(msg) {
  var t = h('div', { class: 'toast', text: msg });
  document.body.appendChild(t);
  setTimeout(function () { t.remove(); }, 2200);
}

function api(path, opts) {
  opts = opts || {};
  var headers = { 'Content-Type': 'application/json' };
  if (TOKEN) headers['Authorization'] = 'Bearer ' + TOKEN;
  var url = '/api' + path;
  if (TOKEN) url += (url.indexOf('?') >= 0 ? '&' : '?') + 'token=' + encodeURIComponent(TOKEN);
  return fetch(url, {
    method: opts.method || 'GET',
    headers: headers,
    body: opts.body ? JSON.stringify(opts.body) : undefined
  }).then(function (r) {
    if (r.status === 401) {
      var t = prompt('请输入面板访问 token');
      if (t) { TOKEN = t; localStorage.setItem('ddp_token', t); location.reload(); }
      throw new Error('未授权');
    }
    return r.json();
  });
}

function fmtTime(iso) {
  if (!iso) return '';
  var d = new Date(iso);
  function p(n) { return (n < 10 ? '0' : '') + n; }
  return p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

function statusBadge(s) {
  var map = { success: 'ok', fail: 'fail', timeout: 'timeout', running: 'run' };
  var label = { success: '成功', fail: '失败', timeout: '超时', running: '运行中' };
  return h('span', { class: 'badge ' + (map[s] || ''), text: label[s] || s });
}

// ---------------------------------------------------------------- 加载数据

function loadAll() {
  return Promise.all([
    api('/status'),
    api('/scripts'),
    api('/logs?limit=60'),
    api('/env'),
    api('/settings')
  ]).then(function (res) {
    state.status = res[0];
    state.scripts = res[1].data || [];
    state.logs = res[2].data || [];
    state.env = res[3].data || [];
    state.settings = res[4].data || {};
    render();
  }).catch(function (e) {
    console.error(e);
  });
}

function refreshStatus() {
  return api('/status').then(function (s) {
    state.status = s;
    var line = document.getElementById('status-line');
    if (line) {
      line.innerHTML = '';
      var ok = s.panelEnabled;
      line.appendChild(h('span', { class: 'dot ' + (ok ? 'ok' : 'bad') }));
      line.appendChild(document.createTextNode('端口 ' + s.panelPort + ' · 守护 ' + s.daemons + ' · 运行 ' + s.running));
    }
    if (state.tab === 'overview' || state.tab === 'scripts') render();
  }).catch(function () {});
}

// ---------------------------------------------------------------- 渲染

function render() {
  var main = document.getElementById('main');
  main.innerHTML = '';
  var fn = { overview: renderOverview, scripts: renderScripts, logs: renderLogs, env: renderEnv, settings: renderSettings }[state.tab];
  main.appendChild(fn());

  Array.prototype.forEach.call(document.querySelectorAll('nav button'), function (b) {
    b.className = b.getAttribute('data-tab') === state.tab ? 'active' : '';
  });
}

function renderOverview() {
  var s = state.status || {};
  var frag = document.createDocumentFragment();

  var card = h('div', { class: 'card' }, [h('h2', { text: '运行状态' })]);
  [
    ['本地面板', s.panelEnabled ? '运行中 · 端口 ' + s.panelPort : '已关闭'],
    ['Python 运行时', s.python || '未知'],
    ['脚本数量', (s.scripts || 0) + ' 个（启用 ' + (s.enabled || 0) + '）'],
    ['常驻守护', (s.daemons || 0) + ' 个'],
    ['正在执行', (s.running || 0) + ' 个'],
    ['Bark 推送', s.barkEnabled ? '已开启' : '未开启']
  ].forEach(function (row) {
    card.appendChild(h('div', { class: 'kv' }, [h('span', { text: row[0] }), h('span', { text: String(row[1]) })]));
  });
  if (s.lastHeartbeat) {
    card.appendChild(h('div', { class: 'kv' }, [
      h('span', { text: '后台心跳' }),
      h('span', { text: s.heartbeatAge + ' 秒前' })
    ]));
  }
  if (s.uptimeHours !== undefined) {
    card.appendChild(h('div', { class: 'kv' }, [
      h('span', { text: '已连续运行' }),
      h('span', { text: s.uptimeHours + ' 小时' })
    ]));
  }
  frag.appendChild(card);

  var ops = h('div', { class: 'card' }, [h('h2', { text: '守护进程' })]);
  ops.appendChild(h('div', { class: 'row' }, [
    h('button', { class: 'btn primary', text: '全部启动', onclick: function () {
      api('/daemons/startAll', { method: 'POST' }).then(function () { toast('已请求启动'); refreshStatus(); });
    } }),
    h('button', { class: 'btn danger', text: '全部停止', onclick: function () {
      api('/daemons/stopAll', { method: 'POST' }).then(function () { toast('已请求停止'); refreshStatus(); });
    } }),
    h('button', { class: 'btn', text: '重新扫描脚本目录', onclick: function () {
      api('/import', { method: 'POST' }).then(function (r) {
        toast('导入了 ' + (r.imported || 0) + ' 个脚本'); loadAll();
      });
    } })
  ]));
  frag.appendChild(ops);

  var recent = h('div', { class: 'card' }, [h('h2', { text: '最近日志' })]);
  var list = state.logs.slice(0, 6);
  if (!list.length) recent.appendChild(h('div', { class: 'empty', text: '暂无记录' }));
  list.forEach(function (l) { recent.appendChild(logItem(l)); });
  frag.appendChild(recent);

  return frag;
}

function logItem(l) {
  return h('div', { class: 'log-item', onclick: function () { openLog(l.id); } }, [
    h('div', { style: 'flex:1;min-width:0' }, [
      h('div', { class: 'nm' }, [document.createTextNode(l.scriptName || '系统'), statusBadge(l.status)]),
      h('div', { class: 'sub', text: (l.trigger || '') + ' · ' + fmtTime(l.startedAt) + (l.duration ? ' · ' + l.duration.toFixed(1) + 's' : '') })
    ])
  ]);
}

function renderScripts() {
  var frag = document.createDocumentFragment();
  var bar = h('div', { class: 'card' }, [
    h('div', { class: 'row' }, [
      h('button', { class: 'btn primary', text: '+ 新建 JS', onclick: function () { openEditor(null, 'js'); } }),
      h('button', { class: 'btn', text: '+ 新建 PY', onclick: function () { openEditor(null, 'py'); } })
    ]),
    h('div', { class: 'hint', text: '支持青龙风格的 $ / axios / console.log，Python 内置 requests。' })
  ]);
  frag.appendChild(bar);

  if (!state.scripts.length) {
    frag.appendChild(h('div', { class: 'empty', text: '还没有脚本，点上面新建一个' }));
    return frag;
  }

  state.scripts.forEach(function (s) {
    var badges = [];
    if (s.runMode === 'daemon') badges.push(h('span', { class: 'badge daemon', text: '常驻' }));
    if (s.running) badges.push(h('span', { class: 'badge run', text: '运行中' }));
    if (!s.enabled) badges.push(h('span', { class: 'badge', text: '已停用' }));
    if (s.lastStatus) badges.push(statusBadge(s.lastStatus));

    var item = h('div', { class: 'script-item' }, [
      h('div', { class: 'script-head' }, [
        h('div', { style: 'min-width:0' }, [
          h('div', { class: 'script-name' }, [document.createTextNode(s.name)].concat(badges)),
          h('div', { class: 'script-meta', text: s.filename + ' · ' + (s.cron || '手动') + ' · ' + s.language.toUpperCase() })
        ])
      ]),
      h('div', { class: 'script-actions' }, [
        h('button', { class: 'btn sm primary', text: '运行', onclick: function () {
          api('/scripts/' + s.id + '/run', { method: 'POST' }).then(function (r) { toast(r.message || '已触发'); refreshStatus(); });
        } }),
        h('button', { class: 'btn sm', text: s.runMode === 'daemon' ? '停止守护' : '转常驻', onclick: function () {
          if (s.runMode === 'daemon') {
            api('/scripts/' + s.id + '/daemon', { method: 'POST', body: { start: false } })
              .then(function () { toast('已停止守护'); loadAll(); });
          } else {
            api('/scripts/' + s.id, { method: 'POST', body: { runMode: 'daemon', enabled: true } })
              .then(function () { toast('已转为常驻并启动'); loadAll(); });
          }
        } }),
        h('button', { class: 'btn sm', text: s.enabled ? '停用' : '启用', onclick: function () {
          api('/scripts/' + s.id + '/toggle', { method: 'POST', body: { enabled: !s.enabled } })
            .then(function () { loadAll(); });
        } }),
        h('button', { class: 'btn sm', text: '编辑', onclick: function () { openEditor(s); } }),
        h('button', { class: 'btn sm danger', text: '删除', onclick: function () {
          if (!confirm('确认删除「' + s.name + '」？')) return;
          api('/scripts/' + s.id, { method: 'DELETE' }).then(function () { loadAll(); });
        } })
      ])
    ]);
    frag.appendChild(item);
  });

  return frag;
}

function renderLogs() {
  var frag = document.createDocumentFragment();
  frag.appendChild(h('div', { class: 'card' }, [
    h('div', { class: 'row' }, [
      h('button', { class: 'btn', text: '刷新', onclick: loadAll }),
      h('button', { class: 'btn danger', text: '清空日志', onclick: function () {
        if (!confirm('确认清空所有日志？')) return;
        api('/logs', { method: 'DELETE' }).then(function () { toast('已清空'); loadAll(); });
      } })
    ])
  ]));

  if (!state.logs.length) {
    frag.appendChild(h('div', { class: 'empty', text: '暂无日志' }));
    return frag;
  }
  state.logs.forEach(function (l) { frag.appendChild(logItem(l)); });
  return frag;
}

function openLog(id) {
  api('/logs/' + id).then(function (r) {
    showModal('执行日志', [
      h('pre', { class: 'log', text: r.data || '（没有输出）' }),
      h('div', { class: 'row', style: 'margin-top:12px' }, [
        h('button', { class: 'btn', text: '复制', onclick: function () {
          navigator.clipboard.writeText(r.data || '').then(function () { toast('已复制'); });
        } }),
        h('button', { class: 'btn primary', text: '关闭', onclick: closeModal })
      ])
    ]);
  });
}

function renderEnv() {
  var frag = document.createDocumentFragment();

  var add = h('div', { class: 'card' }, [
    h('h2', { text: '新增变量' }),
    h('label', { class: 'field' }, [h('span', { text: '变量名' }), h('input', { id: 'env-k', placeholder: '例如 TAOBAO_CK' })]),
    h('label', { class: 'field' }, [h('span', { text: '值' }), h('input', { id: 'env-v', placeholder: '变量值' })]),
    h('button', { class: 'btn primary', text: '添加', onclick: function () {
      var k = document.getElementById('env-k').value.trim();
      var v = document.getElementById('env-v').value;
      if (!k) { toast('变量名不能为空'); return; }
      api('/env', { method: 'POST', body: { key: k, value: v } }).then(function () { loadAll(); });
    } })
  ]);
  frag.appendChild(add);

  var card = h('div', { class: 'card' }, [h('h2', { text: '已有变量（' + state.env.length + '）' })]);
  if (!state.env.length) card.appendChild(h('div', { class: 'empty', text: '暂无变量' }));
  state.env.forEach(function (e) {
    card.appendChild(h('div', { style: 'border-bottom:1px solid var(--border);padding:10px 0' }, [
      h('div', { class: 'row', style: 'justify-content:space-between' }, [
        h('strong', { text: e.key + (e.enabled ? '' : '（已停用）') }),
        h('div', { class: 'row' }, [
          h('button', { class: 'btn sm', text: e.enabled ? '停用' : '启用', onclick: function () {
            api('/env/' + e.id, { method: 'POST', body: { key: e.key, value: e.value, enabled: !e.enabled } })
              .then(function () { loadAll(); });
          } }),
          h('button', { class: 'btn sm', text: '改值', onclick: function () {
            var v = prompt('新的值', e.value);
            if (v === null) return;
            api('/env/' + e.id, { method: 'POST', body: { key: e.key, value: v, enabled: e.enabled } })
              .then(function () { loadAll(); });
          } }),
          h('button', { class: 'btn sm danger', text: '删除', onclick: function () {
            if (!confirm('删除 ' + e.key + '？')) return;
            api('/env/' + e.id, { method: 'DELETE' }).then(function () { loadAll(); });
          } })
        ])
      ]),
      e.value ? h('div', { class: 'script-meta', text: e.value.length > 60 ? e.value.slice(0, 60) + '…' : e.value }) : null
    ]));
  });
  frag.appendChild(card);
  return frag;
}

function renderSettings() {
  var s = state.settings;
  var frag = document.createDocumentFragment();

  function field(label, key, type) {
    return h('label', { class: 'field' }, [
      h('span', { text: label }),
      h('input', { id: 'set-' + key, type: type || 'text', value: s[key] === undefined || s[key] === null ? '' : s[key] })
    ]);
  }
  function toggle(label, key) {
    return h('label', { class: 'switch', style: 'margin-bottom:10px;display:flex' }, [
      h('input', { id: 'set-' + key, type: 'checkbox', checked: s[key] ? 'checked' : null }),
      document.createTextNode(label)
    ]);
  }

  frag.appendChild(h('div', { class: 'card' }, [
    h('h2', { text: '面板' }),
    toggle('启用本地面板', 'panelEnabled'),
    field('端口', 'panelPort', 'number'),
    toggle('允许局域网访问', 'allowLAN'),
    field('访问 token（留空不校验）', 'panelToken')
  ]));

  frag.appendChild(h('div', { class: 'card' }, [
    h('h2', { text: '通知（Bark）' }),
    toggle('启用 Bark 推送', 'barkEnabled'),
    field('Bark 地址', 'barkURL'),
    field('分组', 'barkGroup'),
    toggle('仅失败时推送', 'notifyOnlyFailure')
  ]));

  frag.appendChild(h('div', { class: 'card' }, [
    h('h2', { text: '后台保活' }),
    toggle('音频保活（推荐）', 'keepAliveAudio'),
    toggle('定位保活', 'keepAliveLocation'),
    toggle('后台任务续期', 'keepAliveBackgroundTask'),
    toggle('启动时自动运行常驻脚本', 'autoStart')
  ]));

  frag.appendChild(h('div', { class: 'card' }, [
    h('h2', { text: '数据' }),
    field('日志保留条数', 'maxLogs', 'number'),
    field('日志保留天数', 'logKeepDays', 'number')
  ]));

  frag.appendChild(h('div', { class: 'card' }, [
    h('div', { class: 'row' }, [
      h('button', { class: 'btn primary', text: '保存设置', onclick: saveSettings }),
      h('button', { class: 'btn', text: '测试 Bark 推送', onclick: function () {
        api('/notify', { method: 'POST', body: {} }).then(function (r) { toast(r.message || '已发送'); });
      } })
    ])
  ]));

  return frag;
}

function saveSettings() {
  function val(k) { var e = document.getElementById('set-' + k); return e ? e.value : undefined; }
  function chk(k) { var e = document.getElementById('set-' + k); return e ? !!e.checked : undefined; }

  var body = {
    panelEnabled: chk('panelEnabled'),
    panelPort: parseInt(val('panelPort'), 10) || 5700,
    allowLAN: chk('allowLAN'),
    panelToken: val('panelToken') || '',
    barkEnabled: chk('barkEnabled'),
    barkURL: val('barkURL') || '',
    barkGroup: val('barkGroup') || '',
    notifyOnlyFailure: chk('notifyOnlyFailure'),
    keepAliveAudio: chk('keepAliveAudio'),
    keepAliveLocation: chk('keepAliveLocation'),
    keepAliveBackgroundTask: chk('keepAliveBackgroundTask'),
    autoStart: chk('autoStart'),
    maxLogs: parseInt(val('maxLogs'), 10) || 300,
    logKeepDays: parseInt(val('logKeepDays'), 10) || 7
  };

  api('/settings', { method: 'POST', body: body }).then(function () {
    toast('已保存');
    loadAll();
  });
}

// ---------------------------------------------------------------- 弹窗

function showModal(title, children) {
  var root = document.getElementById('modal-root');
  root.innerHTML = '';
  var sheet = h('div', { class: 'sheet' }, [h('h3', { text: title })].concat(children));
  var overlay = h('div', { class: 'modal', onclick: function (e) { if (e.target === overlay) closeModal(); } }, [sheet]);
  root.appendChild(overlay);
}

function closeModal() {
  document.getElementById('modal-root').innerHTML = '';
}

function openEditor(script, lang) {
  var isNew = !script;
  var draft = script ? Object.assign({}, script) : {
    name: '新脚本-' + Date.now(),
    filename: 'script_' + Date.now() + '.' + (lang === 'py' ? 'py' : 'js'),
    language: lang || 'js',
    content: lang === 'py'
      ? '# -*- coding: utf-8 -*-\nimport requests\n\nprint("hello daidai-panel")\n'
      : "// daidai-panel JS 脚本\n(async () => {\n  console.log('hello daidai-panel');\n  const res = await axios.get('https://httpbin.org/get');\n  console.log('status =', res.status);\n})().catch(e => console.error(e));\n",
    cron: '',
    timeout: 300,
    runMode: 'task',
    enabled: true,
    remark: ''
  };

  var nameI = h('input', { value: draft.name });
  var fileI = h('input', { value: draft.filename });
  var langI = h('select', {}, [
    h('option', { value: 'js', text: 'JavaScript', selected: draft.language === 'js' ? 'selected' : null }),
    h('option', { value: 'py', text: 'Python', selected: draft.language === 'py' ? 'selected' : null })
  ]);
  var modeI = h('select', {}, [
    h('option', { value: 'task', text: '定时任务', selected: draft.runMode === 'task' ? 'selected' : null }),
    h('option', { value: 'daemon', text: '常驻守护', selected: draft.runMode === 'daemon' ? 'selected' : null })
  ]);
  var cronI = h('input', { value: draft.cron || '', placeholder: '分 时 日 月 周，例如 0 8 * * *' });
  var timeoutI = h('input', { type: 'number', value: draft.timeout || 300 });
  var markI = h('input', { value: draft.remark || '' });
  var enabledI = h('input', { type: 'checkbox', checked: draft.enabled ? 'checked' : null });
  var contentI = h('textarea', { rows: 16, style: 'min-height:280px' });
  contentI.value = draft.content || '';

  showModal(isNew ? '新建脚本' : '编辑脚本', [
    h('label', { class: 'field' }, [h('span', { text: '名称' }), nameI]),
    h('label', { class: 'field' }, [h('span', { text: '文件名' }), fileI]),
    h('div', { style: 'display:flex;gap:10px' }, [
      h('label', { class: 'field', style: 'flex:1' }, [h('span', { text: '语言' }), langI]),
      h('label', { class: 'field', style: 'flex:1' }, [h('span', { text: '运行方式' }), modeI])
    ]),
    h('div', { style: 'display:flex;gap:10px' }, [
      h('label', { class: 'field', style: 'flex:2' }, [h('span', { text: 'cron' }), cronI]),
      h('label', { class: 'field', style: 'flex:1' }, [h('span', { text: '超时(秒)' }), timeoutI])
    ]),
    h('label', { class: 'field' }, [h('span', { text: '备注' }), markI]),
    h('label', { class: 'switch', style: 'margin-bottom:12px;display:flex' }, [enabledI, document.createTextNode('启用')]),
    h('label', { class: 'field' }, [h('span', { text: '脚本内容' }), contentI]),
    h('div', { class: 'row', style: 'margin-top:14px' }, [
      h('button', { class: 'btn primary', text: '保存', onclick: function () {
        var body = {
          name: nameI.value.trim() || fileI.value.trim(),
          filename: fileI.value.trim(),
          language: langI.value,
          runMode: modeI.value,
          cron: cronI.value.trim(),
          timeout: parseInt(timeoutI.value, 10) || 300,
          remark: markI.value,
          enabled: !!enabledI.checked,
          content: contentI.value
        };
        var p = script ? api('/scripts/' + script.id, { method: 'POST', body: body })
                       : api('/scripts', { method: 'POST', body: body });
        p.then(function (r) {
          if (r.code !== 0) { toast(r.message || '保存失败'); return; }
          toast('已保存'); closeModal(); loadAll();
        });
      } }),
      h('button', { class: 'btn', text: '取消', onclick: closeModal })
    ])
  ]);
}

// ---------------------------------------------------------------- 启动

document.addEventListener('click', function (e) {
  var b = e.target.closest ? e.target.closest('nav button') : null;
  if (b) {
    state.tab = b.getAttribute('data-tab');
    render();
  }
});

loadAll();
refreshTimer = setInterval(refreshStatus, 5000);
