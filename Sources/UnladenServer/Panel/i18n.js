// The panel's languages. Its text is written in English, in panel.html and
// panel.js; another language maps each English text to its own. The page
// is translated as it is drawn: text nodes and the placeholder and title
// attributes whose whole text has a translation, including what Alpine
// draws later. Names, keys and code (`code`, `.mono`, inputs) are left as
// they are. Text built from parts goes through `t`, whose patterns
// translate the parts they know.

const LANGUAGE_KEY = 'unladen.language';
const LANGUAGES = [{ id: 'en', label: 'English' }, { id: 'zh', label: '中文' }];

const TRANSLATIONS = {
  zh: {
    words: {
      // Sign-in to the panel, header and menu
      'Control panel': '控制面板',
      'Panel token': '面板令牌',
      'Sign in': '登录',
      'Sign out': '退出',
      'More': '更多',
      'Reload the file': '重新读取文件',
      'Unsaved changes': '有未保存的修改',
      'Discard': '放弃',
      'Save': '保存',
      'The panel token was refused.': '面板令牌被拒绝。',
      'Language': '语言',

      // Tabs
      'Overview': '概览',
      'Activity': '活动',
      'Usage': '用量',
      'Accounts': '账号',
      'Models': '模型',
      'Clients': '客户端',
      'Settings': '设置',

      // Overview
      'Configuration file:': '配置文件：',
      'none': '无',
      'Refreshed every 5 seconds.': '每 5 秒刷新。',
      'Account': '账号',
      'Provider': '提供方',
      'State': '状态',
      'ready': '可用',
      'cooling': '冷却中',
      'disabled': '已停用',
      'signed in': '已登录',
      'signed out': '未登录',
      'lapsed': '登录已失效',
      'not saved yet': '尚未保存',
      'Reset': '重置',
      'Sign in again': '重新登录',
      'Forget': '忘记',
      'No account: add one on the Accounts page.': '没有账号：在“账号”页添加。',
      'Models in force': '生效的模型',
      'No model: clients name provider/model.': '没有模型：客户端直接写 provider/model。',
      'Clients in force': '生效的客户端',
      'None: any client may use the gateway.': '没有：任何客户端都可以使用网关。',
      'every model': '所有模型',
      'everything, provider/model too': '全部，包括 provider/model',
      'environment': '环境变量',

      // Activity
      'Requests as they happen, refreshed every 2 seconds. Sessions of the last 7 days.': '实时的请求，每 2 秒刷新。会话保留最近 7 天。',
      'In flight': '进行中',
      'Nothing in flight.': '没有进行中的请求。',
      'Recent requests': '最近的请求',
      'Show all recent': '显示全部最近请求',
      'No request recorded since the gateway started.': '网关启动以来还没有请求。',
      'Sessions': '会话',
      'No session yet.': '还没有会话。',
      'Session': '会话',
      'Started': '开始',
      'Last active': '最近活动',
      'Requests': '请求数',
      'Time': '时间',
      'Client': '客户端',
      'Model': '模型',
      'Served by': '服务方',
      'Status': '状态',
      'Phase': '阶段',
      'waiting': '等待中',
      'streaming': '流式中',
      'done': '完成',
      'First content': '首个内容',
      'Elapsed': '耗时',
      'Input': '输入',
      'Output': '输出',
      'Cached': '缓存',
      'Cache read': '缓存读',
      'Cache write': '缓存写',
      'Cache hit': '缓存命中',
      'Failed': '失败',
      'Total': '合计',

      // Usage
      'Tokens as the upstreams reported them, by local day.': '上游报告的 token 用量，按本地日期统计。',
      'Today': '今天',
      'By account': '按账号',
      'By client': '按客户端',
      'By program': '按程序',
      'By model': '按模型',
      'Program': '程序',
      'No request in this period.': '这段时间没有请求。',
      'No client key': '无客户端 key',
      'Plan allowances': '套餐额度',
      'As the providers report them, read at most once a minute.': '由提供方报告，每分钟最多读取一次。',
      'Refresh': '刷新',
      'Month': '每月',
      'Day': '每天',
      'MCP calls · month': 'MCP 调用 · 每月',
      'Allowance': '额度',
      "OpenAI shows this plan's usage only on its own site.": 'OpenAI 只在自己的网站上显示这个套餐的用量。',
      'Open the usage page': '打开用量页面',
      'This key has no Coding Plan.': '这个 key 没有 Coding Plan。',

      // Accounts
      'The upstream accounts the gateway pays with. Accounts of one provider form a pool, tried in this order: the next is used only when the one before fails.':
        '网关用来付费的上游账号。同一提供方的账号组成号池，按这个顺序尝试：前一个失败时才用下一个。',
      'Add account': '添加账号',
      'Add an account': '添加账号',
      'Name': '名称',
      'Key': 'Key',
      'Enabled': '启用',
      'Shown in logs and the overview.': '显示在日志和概览里。',
      'May stay empty for an address without authentication.': '地址不需要鉴权时可以留空。',
      'Or leave it empty and sign in instead. For your own use only: the plan is personal.': '也可以留空，改为登录。仅限自己使用：订阅套餐属于个人。',
      'another address…': '其他地址…',
      'Speaks like': '协议模板',
      'nothing built in': '不用内置模板',
      'Endpoint': '地址',
      'Header': '请求头',
      'Add': '添加',
      'Sign in and add': '登录并添加',
      'Cancel': '取消',
      'Point': '指向',
      'own address': '自定义地址',
      'Replace': '替换',
      'Remove': '删除',
      'Earlier in the pool': '在号池中提前',
      'Later in the pool': '在号池中延后',
      'No account in the file: providers use keys from the environment.': '文件里没有账号：提供方使用环境变量里的 key。',
      'Give the account a name.': '给账号起个名字。',
      'A name cannot contain / or * or start with @.': '名字不能包含 / 或 *，也不能以 @ 开头。',
      'Another account has this name.': '已有账号用了这个名字。',
      'Enter the key.': '请填写 key。',
      'Enter the endpoint address (http:// or https://).': '请填写地址（http:// 或 https://）。',

      // Signing an account in
      'Open': '打开',
      'the sign-in page': '登录页面',
      'and sign in to ChatGPT.': '，登录 ChatGPT。',
      'and sign in with the Google account.': '，用 Google 账号登录。',
      'The browser then goes to an address starting with': '之后浏览器会跳到一个以',
      ", which does not load unless the browser runs on the gateway's machine: the sign-in sends it back only to a loopback address. Copy that whole address from the address bar and paste it here:":
        '开头的地址。除非浏览器就在网关这台机器上，这个页面打不开：登录只会跳回本机地址。把地址栏里的完整地址复制下来，粘贴到这里：',
      "Not supported by Google: Antigravity's sign-in is meant for Antigravity alone, and Google may suspend an account it sees used elsewhere. Use an account you can afford to lose. Use at your own risk.":
        '非 Google 官方支持：Antigravity 的登录只供 Antigravity 自己使用，Google 发现账号在别处使用时可能会封号。请使用丢了也无妨的账号，风险自负（use at your own risk）。',
      'Finish': '完成',
      'Cannot sign in': '无法登录',

      // Models
      'The names clients may ask for, and who answers them. A target is a provider (the name asked for is passed on),':
        '客户端可以请求的名字，以及由谁来回答。目标可以是提供方（把请求的名字原样转过去），',
      ', or': '，或',
      'for another entry. Names may use': '引用另一条。名字可以用',
      'alone answers every other name.': '单独出现时兜底所有其他名字。',
      'Target': '目标',
      'Add model': '添加模型',
      'No model: clients name provider/model directly.': '没有模型：客户端直接写 provider/model。',

      // Clients
      'The keys clients present (Bearer,': '客户端出示的 key（Bearer、',
      'or': '或',
      '). With none, any client may use the gateway.': '）。一个都没有时，任何客户端都可以使用网关。',
      'Any client that reaches the gateway may use it.': '能连到网关的任何客户端都可以使用它。',
      'Add client': '添加客户端',
      'May use': '可以使用',
      'Every model': '所有模型',
      'Some models': '部分模型',
      'Everything, provider/model too': '全部，包括 provider/model',
      'Generate': '生成',
      'Copy': '复制',

      // Settings
      'Opens this panel; at least 16 characters. After a change, sign in again.': '用来打开这个面板，至少 16 个字符。修改后需要重新登录。',
      'Advanced': '高级',
      'How a provider\'s accounts take turns.': '同一提供方的账号如何轮换。',
      ': the next only when one fails.': '：前一个失败时才用下一个。',
      ': each request starts at the next account; it spreads load but breaks prompt caches.': '：每个请求从下一个账号开始，分摊负载，但会让提示缓存失效。',
      'restart': '需重启',
      'Refuse requests a model cannot take exactly': '拒绝模型无法原样接受的请求',
      'Keepalive interval for streams': '流的保活间隔',
      'Upstream connection timeout': '连接上游的超时',
      'Wait for the first content before the next account; off: no limit': '换下一个账号前等待首个内容的时间；off：不限',
      'Longest silence of a forwarded stream; off: no limit': '转发的流最长可以静默多久；off：不限',
      'Largest request body': '请求体的上限',
      'Edit as JSON': '以 JSON 编辑',
      'The whole file as JSON, keys hidden as': '整个文件的 JSON，key 显示为',
      '(kept as they are when saved). Applying fills the pages above; Save writes the file. Comments in the file are not kept.':
        '（保存时保持原值）。“应用”会填到上面各页；“保存”才写入文件。文件里的注释不会保留。',
      'Apply to the form': '应用到表单',
      'Show the current form': '显示当前表单',
      'Edit it under Settings, Edit as JSON': '在“设置”的“以 JSON 编辑”里修改',

      // Placeholders
      'also, comma-separated: deepseek/*, openai/gpt-4o': '还可以写，逗号分隔：deepseek/*, openai/gpt-4o',
      'key or ${ENV_VAR}': 'key 或 ${ENV_VAR}',
      'value or ${ENV_VAR}': '值或 ${ENV_VAR}',
      'sk-… or ${ENV_VAR}': 'sk-… 或 ${ENV_VAR}',

      // Messages
      'Saved and in force': '已保存并生效',
      'The file was changed elsewhere': '文件在别处被修改了',
      'Reload the file from the menu to see it; your changes here would be lost.': '从菜单重新读取文件即可看到；这里的修改会丢失。',
      'Not saved': '未保存',
      'The file was read again and is in force': '文件已重新读取并生效',
      'The file does not load': '文件无法加载',
      'Save to put it in force.': '保存后生效。',
      'Applied': '已应用',
      'Save to write the file.': '保存后写入文件。',
    },
    // Text built from parts: a pattern, and the translation with the
    // parts it captured ($1…), themselves translated when they can be.
    patterns: [
      [/^(\d+) days$/, '$1 天'],
      [/^(\d+) hours$/, '$1 小时'],
      [/^(\d+) minutes$/, '$1 分钟'],
      [/^(\d+) months$/, '$1 个月'],
      [/^(\d+) models$/, '$1 个模型'],
      [/^(\S+) models$/, '$1 模型'],
      [/^(\d+)% left$/, '剩余 $1%'],
      [/^resets in (.+)$/, '$1 后重置'],
      [/^(\d+)([smhd]) ago$/, '$1$2 前'],
      [/^Requests of session (.+)$/, '会话 $1 的请求'],
      [/^(.+): (.+), retried in (\d+)s$/, '$1：$2，$3 秒后重试'],
      [/^Signed in (.+)$/, '$1 已登录'],
      [/^Added (.+)$/, '已添加 $1'],
      [/^Sign in (\S+\/\S+)$/, '登录 $1'],
      [/^Forget the sign-in of (.+)\?$/, '忘记 $1 的登录？'],
      [/^Not valid JSON: (.+)$/, 'JSON 无效：$1'],
      [/^speaks like (.+)$/, '协议模板：$1'],
    ],
  },
};

function storedLanguage() {
  try { return localStorage.getItem(LANGUAGE_KEY); } catch { return null; }
}

/// The language chosen in the panel, else the browser's, else English.
const language = (() => {
  const stored = storedLanguage();
  if (stored && LANGUAGES.some(l => l.id === stored)) return stored;
  return (navigator.languages || [navigator.language || '']).some(l => l.toLowerCase().startsWith('zh')) ? 'zh' : 'en';
})();

function setLanguage(id) {
  try { localStorage.setItem(LANGUAGE_KEY, id); } catch { /* the choice is not kept */ }
  location.reload();
}

/// `text` in the panel's language, or as it is.
function t(text) {
  const table = TRANSLATIONS[language];
  if (!table || typeof text !== 'string') return text;
  const key = text.replace(/\s+/g, ' ').trim();
  if (Object.prototype.hasOwnProperty.call(table.words, key)) return table.words[key];
  for (const [pattern, replacement] of table.patterns) {
    const match = key.match(pattern);
    if (match) return replacement.replace(/\$(\d)/g, (_, i) => t(match[Number(i)]));
  }
  return text;
}

// Left as they are: names, keys and code.
const UNTRANSLATED = 'code, pre, textarea, script, style, .mono';

function translateText(node) {
  const value = node.nodeValue;
  if (!value || !value.trim()) return;
  const parent = node.parentElement;
  if (!parent || parent.closest(UNTRANSLATED)) return;
  const translated = t(value);
  if (translated === value) return;
  const lead = value.match(/^\s*/)[0], trail = value.match(/\s*$/)[0];
  node.nodeValue = lead + translated + trail;
}

function translateAttributes(element) {
  if (element.closest(UNTRANSLATED)) return;
  for (const name of ['placeholder', 'title']) {
    const value = element.getAttribute(name);
    if (value) {
      const translated = t(value);
      if (translated !== value) element.setAttribute(name, translated);
    }
  }
}

function translateTree(root) {
  if (root.nodeType === Node.TEXT_NODE) { translateText(root); return; }
  if (root.nodeType !== Node.ELEMENT_NODE) return;
  translateAttributes(root);
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (node.nodeType === Node.TEXT_NODE) translateText(node);
    else translateAttributes(node);
  }
}

if (language !== 'en') {
  document.documentElement.lang = language;
  document.addEventListener('DOMContentLoaded', () => {
    translateTree(document.body);
    new MutationObserver(mutations => {
      for (const m of mutations) {
        if (m.type === 'characterData') translateText(m.target);
        else if (m.type === 'attributes') translateAttributes(m.target);
        else for (const node of m.addedNodes) translateTree(node);
      }
    }).observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['placeholder', 'title'] });
  });
}
