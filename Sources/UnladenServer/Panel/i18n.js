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
      // Sign-in to the panel
      'Control panel': '控制面板',
      'Panel token': '面板令牌',
      'The value of panel.token in the configuration file.': '配置文件里 panel.token 的值。',
      'Sign in': '登录',
      'Sign out': '退出',
      'The panel token was refused.': '面板令牌被拒绝。',

      // Navigation
      'Menu': '菜单',
      'Home': '首页',
      'Set up': '配置',
      'Accounts': '账号',
      'Models': '模型',
      'Clients': '客户端',
      'Observe': '观察',
      'Activity': '活动',
      'Usage': '用量',
      'Gateway': '网关',
      'Settings': '设置',
      'Light theme': '浅色主题',
      'Dark theme': '深色主题',
      'What needs you, and how tools connect.': '需要你处理的事，以及工具如何接入。',
      'The provider accounts the gateway spends from.': '网关用来付费的服务商账号。',
      'The names clients ask for, and who answers them.': '客户端请求的名字，以及由谁来回答。',
      'The keys your tools present to the gateway.': '你的工具向网关出示的 key。',
      'Requests as they happen, and the sessions of the last 7 days.': '实时的请求，以及最近 7 天的会话。',
      'Tokens as the providers reported them, by local day.': '服务商报告的 token 用量，按本地日期统计。',
      'How the gateway behaves, and its configuration file.': '网关的行为，以及它的配置文件。',
      'Add account': '添加账号',
      'Add model': '添加模型',
      'Add client': '添加客户端',

      // Home
      'Getting started': '开始使用',
      'Add an account': '添加账号',
      'Give your tools a key': '给工具发一个 key',
      'Connect a tool': '接入工具',
      "An account is a provider's API key, or a subscription you sign in to. The gateway spends from it to answer your tools.":
        '账号是服务商的 API key，或者一个登录使用的订阅。网关用它来回答你的工具。',
      'A client key is what your tools present to the gateway. Without one, anyone who reaches the gateway may use it.':
        '客户端 key 是你的工具向网关出示的凭证。一个都没有时，能连到网关的任何人都可以使用它。',
      'Point a tool at the gateway with the settings below. This card goes away with the first request.':
        '用下面的配置让工具连到网关。收到第一个请求后这张卡片就会消失。',
      'Add a client key': '添加客户端 key',
      'Needs attention': '需要处理',
      'Try it again': '重试',
      'Try it now': '立即重试',
      'No client key is set: anyone who reaches the gateway can spend from your accounts.': '没有设置客户端 key：能连到网关的任何人都可以花你账号的额度。',
      'Today': '今天',
      'Requests': '请求数',
      'Input tokens': '输入 token',
      'Output tokens': '输出 token',
      'Cache hit': '缓存命中',
      'OpenAI-compatible': 'OpenAI 兼容',
      'Claude Code speaks the Anthropic protocol; the gateway answers it with any model you set up.': 'Claude Code 使用 Anthropic 协议；网关可以用你配置的任何模型来回答。',
      'Codex speaks the Responses protocol.': 'Codex 使用 Responses 协议。',
      'Gemini CLI speaks the Gemini protocol. If it asks how to sign in, choose the Gemini API key; -m names the model to ask for.': 'Gemini CLI 使用 Gemini 协议。如果它问怎么登录，选 Gemini API key；-m 指定要请求的模型。',
      'Goes in ~/.config/opencode/opencode.json, or opencode.json in a project. List the models OpenCode may ask for under models, then choose one with /models.': '写入 ~/.config/opencode/opencode.json，或项目里的 opencode.json。把 OpenCode 可以请求的模型列在 models 里，再用 /models 选择。',
      'Goes in ~/.pi/agent/models.json. List the models pi may ask for under models, then choose one with /model.': '写入 ~/.pi/agent/models.json。把 pi 可以请求的模型列在 models 里，再用 /model 选择。',
      'For any tool that takes an OpenAI base URL and key. Anthropic and Gemini clients use the same address without /v1.':
        '适用于任何可以填 OpenAI base URL 和 key 的工具。Anthropic 和 Gemini 客户端用同一个地址，不带 /v1。',
      'Lists the models this key may ask for.': '列出这个 key 可以请求的模型。',
      "Put a client's key in place of YOUR_CLIENT_KEY.": '把 YOUR_CLIENT_KEY 换成某个客户端的 key。',
      'Client keys': '客户端 key',
      'No client key is set, so any value is taken as the key.': '没有设置客户端 key，所以 key 填什么都可以。',
      'The address is the one this page was opened at; another machine may reach the gateway at a different one.':
        '这是打开本页面所用的地址；其他机器访问网关的地址可能不同。',
      'Manage': '管理',
      'No account yet': '还没有账号',
      'Copy': '复制',
      'Copied': '已复制',

      // How an account is doing
      'ready': '可用',
      'turned off': '已停用',
      'not in force': '未生效',
      'sign-in lapsed': '登录已失效',
      'not signed in': '未登录',
      'key refused': 'key 被拒绝',
      'cooling down': '冷却中',

      // Accounts
      'Accounts are used': '账号使用方式',
      'In order: the next account is used only when the one before fails. In turn: each request starts at the next account, which spreads load but breaks prompt caches.':
        '按顺序：前一个账号失败时才用下一个。轮流：每个请求从下一个账号开始，分摊负载，但会让提示缓存失效。',
      'in order': '按顺序',
      'in turn': '轮流',
      'own address': '自定义地址',
      'More': '更多',
      'Edit': '编辑',
      'Sign in again': '重新登录',
      'Forget the sign-in': '忘记登录',
      'Use earlier': '提前使用',
      'Use later': '延后使用',
      'Turn off': '停用',
      'Turn on': '启用',
      'Remove': '删除',
      'Balance': '余额',
      'Credits': '月度点数',
      'Month': '每月',
      'Day': '每天',
      'MCP calls · month': 'MCP 调用 · 每月',
      'Allowance': '额度',
      'This key has no limit; AiHubMix tells a key only what is left on it.': '这个 key 没有设上限，而 AiHubMix 只告诉 key 它自己还剩多少。',
      "OpenAI shows this plan's usage only on its own site.": 'OpenAI 只在自己的网站上显示这个套餐的用量。',
      'This key has no Coding Plan.': '这个 key 没有 Coding Plan。',
      'Open the usage page': '打开用量页面',
      'from the environment': '来自环境变量',
      'The key comes from an environment variable, not from the configuration file.': 'key 来自环境变量，不在配置文件里。',
      'Plans and balances are as the providers report them, read at most once in three minutes.': '套餐和余额由服务商报告，每三分钟最多读取一次。',
      'Refresh': '刷新',
      "Add a provider's API key, or sign in to a subscription, and the gateway can answer your tools with it.":
        '添加服务商的 API key，或者登录一个订阅，网关就能用它来回答你的工具。',

      // Adding and editing an account
      'Add your own address': '添加自定义地址',
      'Search providers': '搜索服务商',
      'Sign in with a subscription': '登录订阅',
      'Your own addresses': '你的自定义地址',
      'With an API key': '使用 API key',
      'Not in the list': '不在列表里',
      'Your own address': '自定义地址',
      'A relay or a local server that speaks one of the usual protocols.': '中转站或本地服务，只要使用常见协议之一。',
      'Name': '名称',
      'Key': 'Key',
      'Tells this account from the others, here and in the logs.': '用来在这里和日志里区分各个账号。',
      'May stay empty for an address without authentication.': '地址不需要鉴权时可以留空。',
      'May stay empty: the free models need no key.': '可以留空：免费模型不需要 key。',
      'Or leave it empty and sign in instead. For your own use only: the plan is personal.': '也可以留空，改为登录。仅限自己使用：订阅套餐属于个人。',
      'Address': '地址',
      'Addresses': '地址',
      'The protocol the address speaks, and where it is.': '这个地址使用的协议，以及地址本身。',
      'Behaves like': '行为模板',
      'nothing built in': '不用内置模板',
      "Borrows a provider's quirks.": '沿用某个服务商的特殊处理。',
      'Models to answer with this account': '由这个账号回答的模型',
      'Clients that ask for these names are answered by this provider.': '客户端请求这些名字时，由这个服务商回答。',
      'Back': '返回',
      'Add': '添加',
      'Sign in and add': '登录并添加',
      'Cancel': '取消',
      'Save': '保存',
      'Undo': '撤销',
      'Replace': '替换',
      'A sign-in belongs to the name: a renamed account signs in again.': '登录是跟着名字走的：改名后需要重新登录。',
      'none: signs in': '无：使用登录',
      'Headers sent with each request': '每个请求附带的请求头',
      'Header': '请求头',
      'Give the account a name.': '给账号起个名字。',
      'A name cannot contain / or * or start with @.': '名字不能包含 / 或 *，也不能以 @ 开头。',
      'Another account has this name.': '已有账号用了这个名字。',
      'Enter the key.': '请填写 key。',
      'Enter the endpoint address (http:// or https://).': '请填写地址（http:// 或 https://）。',
      'The account is taken out of the configuration file. Models that point at it stay, and fail until they point elsewhere.':
        '账号会从配置文件里删除。指向它的模型会保留，在改指向别处之前会失败。',
      'The account stays, and cannot be used until it signs in again.': '账号会保留，但重新登录之前无法使用。',
      'Forget': '忘记',

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
      'Clients ask for': '客户端请求的名字',
      'Answered by': '由谁回答',
      'every other name': '其他所有名字',
      'the same as': '等同于',
      'as': '作为',
      'No model yet': '还没有模型',
      'A model gives clients a name to ask for and says which provider answers it. Without any, clients must name both, as provider/model.':
        '模型给客户端一个可以请求的名字，并指定由哪个服务商回答。一个都没有时，客户端必须把两者都写出来：provider/model。',
      'Add a model': '添加模型',
      'A star stands for any run of characters: claude-* takes every name that starts with claude-, and a star alone takes every name no other model takes.':
        '星号代表任意一串字符：claude-* 匹配所有以 claude- 开头的名字，单独一个星号匹配其他模型都不匹配的名字。',
      'This model has more than one target: change them under Settings, in the file as JSON.': '这个模型有多个目标：请在“设置”里以 JSON 修改。',
      'A provider': '服务商',
      'Another model': '另一个模型',
      'Model the provider is asked for': '向服务商请求的模型',
      'Leave it empty to pass on the name the client asked for.': '留空则把客户端请求的名字原样转过去。',
      'Asking for this name is the same as asking for that one.': '请求这个名字等同于请求那个名字。',
      'Give the model a name.': '给模型起个名字。',
      'Another model has this name.': '已有模型用了这个名字。',
      'Choose the model it stands for.': '请选择它代表的模型。',
      'Add an account first: a model needs a provider to answer it.': '请先添加账号：模型需要一个服务商来回答。',
      'Clients that ask for this name are refused, unless another model takes it.': '请求这个名字的客户端会被拒绝，除非有别的模型匹配它。',

      // Clients
      'Client': '客户端',
      'May use': '可以使用',
      'Enabled': '启用',
      'No client key': '没有客户端 key',
      'Anyone who reaches the gateway may use it. Add a key, and only the tools that present one are answered.':
        '能连到网关的任何人都可以使用它。添加 key 之后，只有出示 key 的工具才会得到回答。',
      'Add a client': '添加客户端',
      'Who holds the key: a person, a machine or a tool. Usage is counted under it.': '谁持有这个 key：一个人、一台机器或一个工具。用量按它统计。',
      'Generate': '生成',
      'Copy it now: once saved, the panel shows only its fingerprint.': '现在就复制：保存之后，面板只显示它的指纹。',
      'Every model': '所有模型',
      'The names on the Models page.': '“模型”页上的名字。',
      'Some models': '部分模型',
      'Only the ones you choose.': '只有你选中的那些。',
      'Everything, provider/model too': '全部，包括 provider/model',
      'Any model of any account, named directly.': '任何账号的任何模型，可以直接点名。',
      'No model': '没有模型',
      'Give the client a name.': '给客户端起个名字。',
      'Another client has this name.': '已有客户端用了这个名字。',
      'With no client key left, anyone who reaches the gateway may use it.': '一个客户端 key 都不剩时，能连到网关的任何人都可以使用它。',
      'Tools that present this key are refused.': '出示这个 key 的工具会被拒绝。',

      // Activity
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
      'Time': '时间',
      'Model': '模型',
      'Account': '账号',
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
      'Failed': '失败',
      'Total': '合计',

      // Usage
      'By account': '按账号',
      'By client': '按客户端',
      'By program': '按程序',
      'By model': '按模型',
      'Program': '程序',
      'No request in this period.': '这段时间没有请求。',

      // Settings
      'Read the file again': '重新读取文件',
      'Use it after editing the file by hand.': '手动改过文件之后使用。',
      'Listens on': '监听地址',
      'Configuration file': '配置文件',
      'Set in the file': '在文件里设置',
      'The address and the panel token are changed in the configuration file alone. A new address takes effect after a restart.':
        '监听地址和面板令牌只能在配置文件里修改。新的监听地址重启后生效。',
      'Behaviour': '行为',
      'Wait for a reply to start': '等待开始回复',
      'How long an account may take to send its first content before the next one is tried. off: no limit.': '一个账号多久没发出首个内容就换下一个。off：不限。',
      'Longest silence in a stream': '流的最长静默',
      'A stream that stays silent this long is ended. off: no limit.': '流静默这么久就会被结束。off：不限。',
      'Keepalive interval': '保活间隔',
      'How often a stream that is waiting is kept alive.': '等待中的流多久保活一次。',
      'Largest request': '请求体上限',
      'A request with a larger body is refused.': '请求体更大的请求会被拒绝。',
      'Strict': '严格模式',
      'Refuse a request the model cannot take exactly as it is, where the gateway would otherwise adapt it.': '模型无法原样接受的请求直接拒绝，而不是由网关改写后再发。',
      'The file as JSON': '以 JSON 查看文件',
      'Everything the pages edit, and what they do not. Keys are hidden behind a fingerprint and kept as they are when saved. Comments in the file are not kept.':
        '各页面编辑的内容，以及它们不涉及的部分。key 显示为指纹，保存时保持原值。文件里的注释不会保留。',

      // The file changed elsewhere
      'The configuration file changed': '配置文件已被修改',
      'It was edited outside the panel after this page read it. Load the file to see it as it is now, without your change; or save your change over it, and what was edited there is lost.':
        '本页面读取之后，文件在面板之外被改过。可以读取文件查看现在的内容，你的这次修改会丢弃；也可以用你的修改覆盖它，文件里改过的内容会丢失。',
      'Load the file': '读取文件',
      'Save over it': '覆盖保存',

      // Placeholders
      'also, comma-separated: deepseek/*, openai/gpt-4o': '还可以写，逗号分隔：deepseek/*, openai/gpt-4o',
      'key or ${ENV_VAR}': 'key 或 ${ENV_VAR}',
      'value or ${ENV_VAR}': '值或 ${ENV_VAR}',
      'sk-… or ${ENV_VAR}': 'sk-… 或 ${ENV_VAR}',

      // Messages
      'Saved and in force': '已保存并生效',
      'Saved, with a warning': '已保存，但有警告',
      'Saved over the file': '已覆盖保存',
      'Not saved': '未保存',
      'The file was read again and is in force': '文件已重新读取并生效',
      'The file does not load': '文件无法加载',
      'the file changed since it was loaded': '文件在读取之后被修改了',
      'the configuration is larger than 4 MiB': '配置超过 4 MiB',
    },
    // Text built from parts: a pattern, and the translation with the
    // parts it captured ($1…), themselves translated when they can be.
    patterns: [
      [/^(\d+) days$/, '$1 天'],
      [/^granted (\S+) · topped up (\S+)$/, '赠送 $1 · 充值 $2'],
      [/^(\S+) \/ (\S+) credits \+ (\S+) extra$/, '$1 / $2 点 + 额外 $3'],
      [/^(\S+) \/ (\S+) credits$/, '$1 / $2 点'],
      [/^(\d+) hours$/, '$1 小时'],
      [/^(\d+) minutes$/, '$1 分钟'],
      [/^(\d+) months$/, '$1 个月'],
      [/^(\d+) models$/, '$1 个模型'],
      [/^(\S+) models$/, '$1 模型'],
      [/^(\d+)% left$/, '剩余 $1%'],
      [/^resets in (.+)$/, '$1 后重置'],
      [/^(\d+)([smhd]) ago$/, '$1$2 前'],
      [/^(\d+) in flight$/, '$1 个进行中'],
      [/^(\d+) failed$/, '$1 次失败'],
      [/^Requests of session (.+)$/, '会话 $1 的请求'],
      [/^(\S+): the sign-in has lapsed$/, '$1：登录已失效'],
      [/^(\S+): not signed in yet$/, '$1：还没有登录'],
      [/^(\S+): the key was refused repeatedly and is no longer tried$/, '$1：key 多次被拒绝，已不再尝试'],
      [/^(\S+): cooling down, tried again in (\d+)s$/, '$1：冷却中，$2 秒后重试'],
      [/^(\S+): (\d+)% left of (.+)$/, '$1：$3 只剩 $2%'],
      [/^(.+): (.+), retried in (\d+)s$/, '$1：$2，$3 秒后重试'],
      [/^Signed in (.+)$/, '$1 已登录'],
      [/^Added (.+)$/, '已添加 $1'],
      [/^Add an account of (.+)$/, '添加 $1 账号'],
      [/^Edit (.+)$/, '编辑 $1'],
      [/^Remove (.+)\?$/, '删除 $1？'],
      [/^Sign in (\S+\/\S+)$/, '登录 $1'],
      [/^Forget the sign-in of (.+)\?$/, '忘记 $1 的登录？'],
      [/^Not valid JSON: (.+)$/, 'JSON 无效：$1'],
      [/^behaves like (.+)$/, '行为模板：$1'],
      [/^\((\d+) failed\)$/, '（$1 次失败）'],
      [/^(\d+) switches$/, '$1 次切换'],
      [/^(\d+) tries$/, '$1 次尝试'],
      [/^(.+), streamed$/, '$1，流式'],
      [/^\(now (.+)\)$/, '（当前：$1）'],
      [/^(.+) is a provider: give this account another name\.$/, '$1 是一个 provider：请给这个账号换个名字。'],
      [/^(\S+) endpoint unreachable$/, '$1 端点无法连接'],
      [/^(.+) failing$/, '$1 连续失败'],
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
