// The panel's languages. Its text is written in English, in panel.html and
// panel.js; another language maps each English text to its own. The page
// is translated as it is drawn: text nodes and the placeholder and title
// attributes whose whole text has a translation, including what Alpine
// draws later. Names, keys and code (`code`, `.mono`, inputs) are left as
// they are; a placeholder or title is the panel's own text, so a `.mono`
// field's is translated too. Text built from parts goes through `t`, whose
// patterns translate the parts they know.

const LANGUAGE_KEY = 'unladen.language';
const LANGUAGES = [{ id: 'en', label: 'English' }, { id: 'zh', label: '中文' }];

const TRANSLATIONS = {
  zh: {
    words: {
      // Sign-in to the panel
      'Control panel': '控制面板',
      'Panel token': '面板令牌',
      'The value of panel.token in the configuration file. On its first start the gateway writes that file and prints the token in its log.':
        '配置文件里 panel.token 的值。网关第一次启动时会写出这个文件，并在日志里打印这个令牌。',
      'Sign in': '登录',
      'Sign out': '退出',
      'The panel token was refused.': '面板令牌被拒绝。',
      "The panel's scripts could not be loaded from cdn.jsdelivr.net. The browser needs to reach it to show the panel.":
        '无法从 cdn.jsdelivr.net 加载面板的脚本。浏览器需要能访问它才能显示面板。',

      // Navigation
      'Menu': '菜单',
      'Home': '首页',
      'Set up': '配置',
      'Accounts': '账号',
      'Model routing': '模型路由',
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
      'The model names clients ask for, and who answers them, in what order.': '客户端请求的模型名，以及按什么顺序由谁回答。',
      'The keys your tools present to the gateway.': '你的工具向网关出示的 key。',
      'Requests as they happen, and the sessions of the last 7 days.': '实时的请求，以及最近 7 天的会话。',
      'Tokens as the providers reported them, by local day.': '服务商报告的 token 用量，按本地日期统计。',
      'How the gateway behaves, and its configuration file.': '网关的行为，以及它的配置文件。',
      'Add account': '添加账号',
      'Add route': '添加路由',
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
      'Set aside': '不再提示',
      'Show again': '重新显示',
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
      'Paimon speaks the Anthropic protocol here. paimon login keeps the address and the key, and makes the model the default; name another with --model anthropic:NAME or paimon model.':
        '这里 Paimon 使用 Anthropic 协议。paimon login 会记下地址和 key，并把这个模型设为默认；换模型用 --model anthropic:名字 或 paimon model。',
      'For dsh in the terminal; dsh web reads ~/.dsh/profiles/web instead. If the file already has an llm-pi-ai entry, put unladen under its providers: an entry replaces the whole of its config. List the models dsh may ask for under models, then choose one in the model picker.':
        '用于终端里的 dsh；dsh web 读的是 ~/.dsh/profiles/web。如果文件里已经有 llm-pi-ai 条目，就把 unladen 加到它的 providers 下：一个条目会整个替换它的配置。把 dsh 可以请求的模型列在 models 里，再在模型选择器里选一个。',
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
      'Routes to answer with this account': '由这个账号回答的路由',
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
      'The account is taken out of the configuration file. Routes that point at it stay, and fail until they point elsewhere.': '账号会从配置文件里删除。指向它的路由会保留，在改指向别处之前会失败。',
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
      'the same as': '等同于',
      'as': '作为',
      'This route is written in a way the form cannot show: change it under Settings, in the file as JSON.': '这条路由的写法表单无法显示：请在“设置”里以 JSON 修改。',
      'First': '首先',
      'Then': '然后',
      'Move up': '上移',
      'Move down': '下移',
      'Add a fallback': '添加备用',
      'Tried in order: the next one answers only when every account of the one before it fails.': '按顺序尝试：前一个的所有账号都失败时，才由下一个回答。',
      'A conversation under way with more context than this (in tokens, such as 64k) is not moved to the next target: it waits for the one holding its prompt cache. Leave it empty to use the one under Settings.':
        '已在进行、上下文超过这个长度（token 数，如 64k）的会话，不会换到下一个目标，而是等待持有它 prompt cache 的那个。留空则使用“设置”里的值。',
      'Give the length in tokens, such as 64000 or 64k, or off.': '请填写 token 数，如 64000 或 64k，或者 off。',
      'Asking the provider for its models…': '正在向服务商查询模型列表…',
      'The provider gave no list.': '服务商没有给出模型列表。',
      'No model matches.': '没有匹配的模型。',
      "Search the provider's models": '搜索服务商的模型',
      'Clients that ask for these names are answered by this provider. Each model picked from the list is a route by its own name.':
        '客户端请求这些名字时，由这个服务商回答。从列表里选中的每个模型都会成为一条同名路由。',
      'Clients that ask for these names are answered by this provider. Once the account is signed in, its models can be picked under Model routing.':
        '客户端请求这些名字时，由这个服务商回答。账号登录之后，可以在「模型路由」里选它的模型。',
      'Try a name a tool asks for, such as claude-sonnet-4-5': '试一个工具会请求的名字，例如 claude-sonnet-4-5',
      'Asked by any client': '任意客户端请求',
      'Taken by the route of that name.': '由同名的路由回答。',
      'Taken by the route': '由这条路由回答：',
      'No route takes it: the provider it names is asked directly.': '没有路由匹配：直接请求名字里写的服务商。',
      'No route takes it: it goes where every other name goes.': '没有路由匹配：交给「其他名字」的去处。',
      'no key needed': '不需要密钥',
      ', cooling down': '，冷却中',
      ', key refused': '，密钥被拒',
      'Nothing answers this name: the client is refused.': '没有人回答这个名字：客户端会被拒绝。',
      'This client may not ask for it.': '这个客户端无权请求它。',
      'Choose who answers': '选择由谁回答',
      'Asked for, not answered': '有人请求，但没人回答',
      'Dismiss': '忽略',
      "Providers' models": '服务商的模型',
      'Tick a model and clients may ask for it by its own name.': '勾选一个模型，客户端就可以用它本来的名字请求。',
      "A provider's models are listed here once it has an account.": '服务商有了账号之后，它的模型会列在这里。',
      'no account': '没有账号',
      'Nothing offered': '未提供',
      'new names too': '含以后新增的',
      'every other name': '其他所有名字',
      'every other name, its models by their own names': '其他所有名字，按原名提供它的模型',
      'Give them': '交给它',
      "not in the provider's list": '不在服务商的列表里',
      'through': '经由',
      'in a route of its own': '在它自己的路由里',
      'answered by': '回答者：',
      'answered by a route of its own': '由它自己的路由回答',
      'now answered by': '现在的回答者：',
      'now answered by a route of its own': '现在由它自己的路由回答',
      'a route of its own': '它自己的路由',
      ', then': '，然后',
      'Names of your own': '你起的名字',
      'A short name for a model, several models tried in order, or a name with a star.': '给模型起的短名字、依次尝试的几个模型，或带星号的名字。',
      'the name asked for': '请求的名字',
      'None yet.': '还没有。',
      'Every other name': '其他名字',
      'What a client asks for and nothing above takes.': '客户端请求了、而上面都不匹配的名字。',
      'Goes to': '交给',
      'Refused: the client is told the model is not served.': '拒绝：告诉客户端没有这个模型。',
      'Choose a model': '选择模型',
      'Which provider?': '哪个服务商？',
      'What should clients be able to ask for?': '想让客户端能请求什么？',
      "A provider's models": '某个服务商的模型',
      'By their own names: tick the ones to offer.': '用它们本来的名字：勾选要提供的。',
      'A short name for a model': '给模型起个短名字',
      'Such as fast, answered by a model you choose.': '例如 fast，由你选的模型回答。',
      'Several models tried in order': '几个模型依次尝试',
      'One name: the next model answers when the one before fails.': '一个名字：前一个模型失败时由下一个回答。',
      'What no route takes goes to one model.': '没有路由匹配的名字，都交给一个模型。',
      'A name with a star': '带星号的名字',
      'claude-* takes every name that starts with claude-.': 'claude-* 匹配所有以 claude- 开头的名字。',
      'Add an account first.': '请先添加账号。',
      'A name no route takes goes here, a mistyped one too.': '没有路由匹配的名字都到这里，打错的名字也是。',
      'A star stands for any run of characters: claude-* takes every name that starts with claude-.': '星号代表任意一串字符：claude-* 匹配所有以 claude- 开头的名字。',
      'The model name a tool is set to ask for.': '工具里设置的、它会请求的模型名。',
      "Search every provider's models": '搜索所有服务商的模型',
      'Asking the providers for their models…': '正在向服务商查询模型列表…',
      'No list to pick from: type provider/model.': '没有可选的列表：直接输入 provider/model。',
      'Pick a model, or type it as provider/model.': '选择一个模型，或输入 provider/model。',
      'A provider alone is asked for the name the client asked for.': '只写服务商时，把客户端请求的名字原样发给它。',
      'Choose who answers.': '请选择由谁回答。',
      'A name cannot start with @.': '名字不能以 @ 开头。',
      'Clients that ask for these names are refused, unless another route takes them.': '请求这些名字的客户端会被拒绝，除非有别的路由匹配。',
      'Stop offering': '不再提供',
      'Give the name clients ask for.': '请填写客户端请求的名字。',
      'Another route has this name.': '已有路由用了这个名字。',
      'Choose the route it stands for.': '请选择它代表的路由。',
      'Clients that ask for this name are refused, unless another route takes it.': '请求这个名字的客户端会被拒绝，除非有别的路由匹配它。',

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
      'The names on the Model routing page.': '“模型路由”页上的名字。',
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
      'Request': '请求',
      'Duration': '耗时',
      'Tokens': 'Token',
      'in': '输入',
      'out': '输出',
      'First choice': '首选',
      'Another account answered': '换了一个账号回答',
      'No target answered': '没有目标回答',
      'Headers sent early': '先回了响应头',
      'No content within 3 s: the headers went out first, and comments kept the client waiting.': '3 秒内没有内容：先回了响应头，再用注释保持连接，客户端感觉不到。',
      'Tried': '尝试',
      'What the gateway changed': '网关做了哪些改动',
      '(request)': '（请求）',
      '(reply)': '（回复）',
      'The details of these changes are kept only for requests since the gateway last started.': '改动明细只保留网关这次启动以来的请求。',
      'Kept a field it does not know': '保留了不认识的字段',
      'Kept content it does not know, as it is': '原样保留了不认识的内容',
      'Dropped a field the target cannot take': '丢弃了目标不支持的字段',
      'Dropped content the target cannot take': '丢弃了目标不支持的内容',
      'Converted, not exactly': '转换了，但不完全等价',
      'Ignored a value it does not understand': '忽略了无法理解的值',
      'The stream broke its protocol': '流不符合协议',
      'Adjusted to fit the model': '为适配模型做了调整',
      'Left out a setting the model does not take': '去掉了模型不接受的设置',
      'ok': '成功',
      'unreachable': '连不上',
      'token refresh failed': '刷新令牌失败',
      'reply cannot be decoded': '回复无法解析',
      'reply too large': '回复过大',
      'cancelled': '已取消',
      'skipped: endpoint unreachable': '跳过：地址连不上',
      'skipped: would lose part of the request (strict)': '跳过：会丢失部分请求（strict）',
      '401: trying again with a refreshed token': '401：用刷新后的令牌重试',
      'failed before any content': '在任何内容之前失败',
      'stream broke off': '流中途断开',
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
      'Status': '状态',
      'Phase': '阶段',
      'waiting': '等待中',
      'streaming': '流式中',
      'done': '完成',
      'Elapsed': '耗时',
      'Input': '输入',
      'Output': '输出',
      'Cache read': '缓存读',
      'Cache write': '缓存写',
      'Failed': '失败',
      'Total': '合计',
      'session': '会话',
      'main': '主对话',
      'subagent': '子代理',

      // Usage
      'By account': '按账号',
      'By client': '按客户端',
      'By program': '按程序',
      'By model': '按模型',
      'By route': '按路由',

      // Session view
      'Close': '关闭',
      'cached': '命中缓存',
      'Answered last by': '最近应答',
      'Context, last turn': '上下文（最近一轮）',
      'Read from cache, last turn': '缓存命中（最近一轮）',
      'Prompt cache': '提示缓存',
      'Not known': '未知',
      'Target changes': '换目标次数',
      'Read from cache': '读自缓存',
      'Written to cache': '写入缓存',
      'Not cached': '未缓存',
      'Another target answered': '换了目标应答',
      'Answered by another target than the turn before': '与上一轮不是同一个目标应答',
      'Kept on its target: long context': '上下文过长，留在原目标',
      'Each column is one request, oldest first, numbered from the oldest kept. Read from cache is cheap; a column mostly not cached after another target answered is the cost of moving the conversation.':
        '每根柱子是一个请求，从最早保留的一个开始编号。读自缓存的部分便宜；换目标之后一根几乎全是未缓存的柱子，就是迁移会话的代价。',
      'No turn of this session is kept.': '这个会话没有保留下来的请求。',

      // Usage trends
      'Tokens by hour': '每小时 token',
      'Tokens by day': '每天 token',
      'Requests by hour': '每小时请求数',
      'Requests by day': '每天请求数',
      'Input and output tokens; input includes what was read from cache.': '输入与输出 token 之和；输入包含读自缓存的部分。',
      'Share': '占比',
      'Route': '路由',
      'Fell back': '回退',
      'Before routes were recorded, or a model named directly': '记录路由之前的请求，或直接指定的模型',
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
      'Longest conversation to move': '可换模型的最长会话',
      'A conversation under way with more context than this (in tokens, such as 64k) is not moved to the next target of its route: it waits for the one holding its prompt cache. A route may set its own. off: no limit.': '已在进行、上下文超过这个长度（token 数，如 64k）的会话，不会换到路由里的下一个目标，而是等待持有它 prompt cache 的那个。每条路由可以单独设置。off：不限。',
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

      // Before the file is first written over
      'Save over the configuration file?': '覆盖保存配置文件？',
      'Saving from the panel writes the whole file again: comments in it are not kept. This is asked once for each file in this browser.':
        '从面板保存会重写整个文件：文件里的注释不会保留。在这个浏览器里，每个文件只问一次。',
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
      'The file was not read again': '文件没有重新读取',
      'The file cannot be read': '无法读取文件',
      'cannot reach the gateway': '连不上网关',
      'The gateway cannot be reached. The page shows what it read last, and changes are not saved.': '连不上网关。页面显示的是最后一次读到的内容，修改不会被保存。',
      'the configuration is larger than 4 MiB': '配置超过 4 MiB',
      'expected an object': '应当是一个对象',
    },
    // Text built from parts: a pattern, and the translation with the
    // parts it captured ($1…), themselves translated when they can be.
    patterns: [
      [/^(\d+) more: type to narrow the list\.$/, '还有 $1 个：继续输入以缩小范围。'],
      [/^Target (\d+) of (\d+)$/, '第 $1 个目标（共 $2 个）'],
      [/^Fell back to target (\d+) of (\d+)$/, '回退到了第 $1 个目标（共 $2 个）'],
      [/^Not moved: about (\S+) tokens of context \((\S+) reported for the last turn\), over (\S+)$/, '没有换目标：上下文约 $1 token（上一轮上游报告 $2），超过 $3'],
      [/^Not moved: about (\S+) tokens of context \(estimated\), over (\S+)$/, '没有换目标：上下文约 $1 token（估算），超过 $2'],
      [/^Not moved: the conversation builds on a reply kept by (\S+)$/, '没有换目标：会话依赖 $1 保存的回复'],
      [/^(.+): disabled after repeated refusals$/, '$1：多次被拒（401）后已停用'],
      [/^(.+): cooling, (\S+) left \(after (.+)\)$/, '$1：冷却中，还剩 $2（起因 $3）'],
      [/^(.+): cooling, (\S+) left$/, '$1：冷却中，还剩 $2'],
      [/^(.+?) failed: (.+)$/, '$1 失败：$2'],
      [/^failed before any content: (.+)$/, '在任何内容之前失败：$1'],
      [/^error: (.+)$/, '出错：$1'],
      [/^(\d+) changes?$/, '改动 $1 处'],
      [/^first (\S+)$/, '首个内容 $1'],
      [/^(\S+) cached$/, '缓存 $1'],
      [/^Route (.+?): (.+)$/, '路由 $1：$2'],
      [/^A conversation longer than (\S+) tokens stays where it is$/, '上下文超过 $1 token 的会话不换目标'],
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
      [/^Session (\S+)$/, '会话 $1'],
      [/^Likely warm, about (\d+) min left$/, '可能仍有效，约剩 $1 分钟'],
      [/^Likely warm, about (\d+)h (\d+)min left$/, '可能仍有效，约剩 $1 小时 $2 分钟'],
      [/^Likely cold: last answered (.+)$/, '可能已失效：最近一次应答在 $1'],
      [/^Turn (\d+) · (.+)$/, '第 $1 轮 · $2'],
      [/^Fell back to target (\d+)$/, '回退到第 $1 个目标'],
      [/^(\S+) tokens$/, '$1 token'],
      [/^· (\d+) failed$/, '· $1 次失败'],
      [/^(\d+) others$/, '其余 $1 项'],
      [/^(\d+) not answered by any target$/, '$1 个没有目标应答'],
      [/^(\d+) in flight$/, '$1 个进行中'],
      [/^(\d+) failed$/, '$1 次失败'],
      [/^Requests of session (.+)$/, '会话 $1 的请求'],
      [/^(.+): the sign-in has lapsed$/, '$1：登录已失效'],
      [/^(.+): not signed in yet$/, '$1：还没有登录'],
      [/^(.+): the key was refused repeatedly and is no longer tried$/, '$1：key 多次被拒绝，已不再尝试'],
      [/^(.+): cooling down, tried again in (\d+)s$/, '$1：冷却中，$2 秒后重试'],
      [/^(.+): (\d+)% left of (.+)$/, '$1：$3 只剩 $2%'],
      [/^(.+): (.+), retried in (\d+)s$/, '$1：$2，$3 秒后重试'],
      [/^Signed in (.+)$/, '$1 已登录'],
      [/^Added (.+)$/, '已添加 $1'],
      [/^Add an account of (.+)$/, '添加 $1 账号'],
      [/^Edit (.+)$/, '编辑 $1'],
      [/^(\d+) requests$/, '$1 个请求'],
      [/^(\d+) offered by name$/, '已提供 $1 个'],
      [/^Give every other name to (.+)\?$/, '把其他所有名字交给 $1？'],
      [/^They now go to (.+)\.$/, '它们现在交给 $1。'],
      [/^(\d+) set aside in this browser$/, '已在此浏览器中隐藏 $1 项'],
      [/^Offer all (\d+)$/, '全部提供（$1 个）'],
      [/^Offer none of (\d+)$/, '全部取消（$1 个）'],
      [/^Stop offering (\d+) models of (.+)\?$/, '不再提供 $2 的 $1 个模型？'],
      [/^A model name was asked for and nothing answers it: (.+)$/, '有一个模型名被请求了，但没人回答：$1'],
      [/^(\d+) model names were asked for and nothing answers them$/, '有 $1 个模型名被请求了，但没人回答'],
      [/^Remove (.+)\?$/, '删除 $1？'],
      [/^Sign in (.+\/.+)$/, '登录 $1'],
      [/^Forget the sign-in of (.+)\?$/, '忘记 $1 的登录？'],
      [/^Not valid JSON: (.+)$/, 'JSON 无效：$1'],
      [/^HTTP (\d+)$/, '请求失败（HTTP $1）'],
      [/^behaves like (.+)$/, '行为模板：$1'],
      [/^\((\d+) failed\)$/, '（$1 次失败）'],
      [/^(\d+) switches$/, '$1 次切换'],
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

// Left as they are: names, keys and code. Attributes are left only in code.
const UNTRANSLATED = 'code, pre, textarea, script, style, .mono';
const UNTRANSLATED_ATTRIBUTES = 'code, pre, script, style';

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
  if (element.closest(UNTRANSLATED_ATTRIBUTES)) return;
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
