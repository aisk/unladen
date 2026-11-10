const TOKEN_KEY = 'unladen.adminToken';
const THEME_KEY = 'unladen.theme';
const HIDDEN = /^<hidden (key-[0-9a-f]{8})>$/;
// The sections the forms edit. `listen` and `panel` are set in the file
// alone and carried back as they are.
const SECTIONS = ['accounts', 'models', 'clients', 'advanced'];
const ADVANCED = ['strict', 'keepalive', 'head_timeout', 'idle_timeout', 'max_request_bytes'];
// The names a provider's own models go by, offered as models when an
// account of it is added.
const FAMILIES = {
  anthropic: ['claude-*'], openai: ['gpt-*', 'o3*', 'o4*'], gemini: ['gemini-*'], deepseek: ['deepseek-*'],
  xai: ['grok-*'], moonshot: ['kimi-*'], mistral: ['mistral-*', 'codestral-*'], chatgpt: ['gpt-*'],
  'moonshot-cn': ['kimi-*'], 'kimi-code': ['kimi-*'], 'kimi-code-cn': ['kimi-*'],
  zai: ['glm-*'], 'zai-coding': ['glm-*'], zhipu: ['glm-*'], 'zhipu-coding': ['glm-*'],
  minimax: ['MiniMax-*'], 'minimax-cn': ['MiniMax-*'], 'step-plan': ['step-*'], 'step-plan-cn': ['step-*'],
  'ark-coding': ['ark-*', 'doubao-*'], 'bailian-token-plan': ['qwen*'],
  longcat: ['LongCat-*'], mimo: ['mimo-*'], 'mimo-plan': ['mimo-*'], 'mimo-plan-sgp': ['mimo-*'], 'mimo-plan-ams': ['mimo-*'],
  dashscope: ['qwen*'], 'dashscope-cn': ['qwen*'], qwencloud: ['qwen*'], 'qwen-token-plan': ['qwen*'], 'qwencloud-token-plan': ['qwen*'],
  stepfun: ['step-*'], 'stepfun-cn': ['step-*'], ark: ['doubao-*'], 'ark-agent': ['doubao-*'],
};
// Providers whose accounts sign in instead of holding a key, and those of
// them whose accounts never hold one.
const SIGN_IN = ['chatgpt', 'antigravity'];
const KEYLESS = ['antigravity'];
// Shown first among the providers an account is added of.
const FEATURED = ['anthropic', 'openai', 'gemini', 'deepseek', 'openrouter', 'xai'];
// Providers' names and icons (files of @lobehub/icons-static-svg), by id.
// A provider not listed goes by its id and its initials.
const ICONS = 'https://cdn.jsdelivr.net/npm/@lobehub/icons-static-svg@1.102.0/icons/';
const BRANDS = {
  openai: ['OpenAI', 'openai'], chatgpt: ['ChatGPT', 'openai'], anthropic: ['Anthropic', 'claude-color'],
  gemini: ['Gemini', 'gemini-color'], antigravity: ['Antigravity', 'antigravity-color'], deepseek: ['DeepSeek', 'deepseek-color'],
  moonshot: ['Moonshot', 'moonshot'], 'moonshot-cn': ['Moonshot China', 'moonshot'],
  'kimi-code': ['Kimi Code', 'kimi-color'], 'kimi-code-cn': ['Kimi Code China', 'kimi-color'],
  zai: ['Z.ai', 'zai'], 'zai-coding': ['Z.ai Coding Plan', 'zai'],
  zhipu: ['Zhipu', 'zhipu-color'], 'zhipu-coding': ['Zhipu Coding Plan', 'zhipu-color'],
  minimax: ['MiniMax', 'minimax-color'], 'minimax-cn': ['MiniMax China', 'minimax-color'],
  'step-plan': ['Step Plan', 'stepfun-color'], 'step-plan-cn': ['Step Plan China', 'stepfun-color'],
  stepfun: ['StepFun', 'stepfun-color'], 'stepfun-cn': ['StepFun China', 'stepfun-color'],
  ark: ['Volcengine Ark', 'volcengine-color'], 'ark-coding': ['Ark Coding Plan', 'volcengine-color'], 'ark-agent': ['Ark Agent Plan', 'volcengine-color'],
  'bailian-token-plan': ['Bailian Token Plan', 'bailian-color'],
  openrouter: ['OpenRouter', 'openrouter'], 'opencode-zen': ['OpenCode Zen', 'opencode'], 'opencode-go': ['OpenCode Go', 'opencode'],
  kilo: ['Kilo', 'kilocode'], groq: ['Groq', 'groq'], mistral: ['Mistral', 'mistral-color'], xai: ['xAI', 'xai'],
  together: ['Together', 'together-color'], nvidia: ['NVIDIA', 'nvidia-color'], modelscope: ['ModelScope', 'modelscope-color'],
  siliconflow: ['SiliconFlow', 'siliconcloud-color'], 'siliconflow-global': ['SiliconFlow Global', 'siliconcloud-color'],
  longcat: ['LongCat', 'longcat-color'], 'ollama-cloud': ['Ollama Cloud', 'ollama'], ollama: ['Ollama', 'ollama'],
  fireworks: ['Fireworks', 'fireworks-color'], nous: ['Nous Research', 'nousresearch'],
  mimo: ['Xiaomi MiMo', 'xiaomimimo'], 'mimo-plan': ['MiMo Token Plan', 'xiaomimimo'],
  'mimo-plan-sgp': ['MiMo Token Plan Singapore', 'xiaomimimo'], 'mimo-plan-ams': ['MiMo Token Plan Europe', 'xiaomimimo'],
  qianfan: ['Baidu Qianfan', 'baiducloud-color'], 'qianfan-plan': ['Qianfan Token Plan', 'baiducloud-color'],
  'qianfan-plan-team': ['Qianfan Token Plan Team', 'baiducloud-color'],
  tokenhub: ['Tencent TokenHub', 'tencentcloud-color'], 'tokenhub-intl': ['Tencent TokenHub Global', 'tencentcloud-color'],
  'tencent-plan': ['Tencent Token Plan', 'tencentcloud-color'], 'tencent-plan-intl': ['Tencent Token Plan Global', 'tencentcloud-color'],
  'huawei-maas': ['Huawei Cloud MaaS', 'huaweicloud-color'], 'huawei-plan': ['Huawei Token Plan', 'huaweicloud-color'],
  'qwen-token-plan': ['Qwen Token Plan', 'qwen-color'], 'qwencloud-token-plan': ['Qwen Cloud Token Plan', 'qwen-color'],
  dashscope: ['DashScope', 'alibabacloud-color'], 'dashscope-cn': ['DashScope China', 'alibabacloud-color'], qwencloud: ['Qwen Cloud', 'qwen-color'],
  commandcode: ['Command Code', 'commandcode'], aihubmix: ['AiHubMix', 'aihubmix-color'], '302ai': ['302.AI', 'ai302-color'],
  cherryin: ['CherryIN', 'cherrystudio-color'], pipellm: ['PipeLLM', ''], lmstudio: ['LM Studio', 'lmstudio'],
};
let counter = 0;

function panel() {
  return {
    token: localStorage.getItem(TOKEN_KEY) || '',
    tokenInput: '',
    signInError: '',
    tab: 'home',
    languages: LANGUAGES,
    language,
    theme: document.documentElement.getAttribute('data-bs-theme') || 'light',
    origin: location.origin,
    // The pages, under their headings (entries without an id).
    navigation: [
      { id: 'home', label: 'Home', icon: 'ti-home', about: 'What needs you, and how tools connect.' },
      { label: 'Set up' },
      { id: 'accounts', label: 'Accounts', icon: 'ti-wallet', about: 'The provider accounts the gateway spends from.' },
      { id: 'models', label: 'Models', icon: 'ti-route', about: 'The names clients ask for, and who answers them.' },
      { id: 'clients', label: 'Clients', icon: 'ti-key', about: 'The keys your tools present to the gateway.' },
      { label: 'Observe' },
      { id: 'activity', label: 'Activity', icon: 'ti-activity', about: 'Requests as they happen, and the sessions of the last 7 days.' },
      { id: 'usage', label: 'Usage', icon: 'ti-chart-bar', about: 'Tokens as the providers reported them, by local day.' },
      { label: 'Gateway' },
      { id: 'settings', label: 'Settings', icon: 'ti-settings', about: 'How the gateway behaves, and its configuration file.' },
    ],
    protocols: ['chat', 'responses', 'anthropic', 'gemini'],
    settingFields: [
      { name: 'head_timeout', label: 'Wait for a reply to start', placeholder: '240s', help: 'How long an account may take to send its first content before the next one is tried. off: no limit.' },
      { name: 'idle_timeout', label: 'Longest silence in a stream', placeholder: '300s', help: 'A stream that stays silent this long is ended. off: no limit.' },
      { name: 'keepalive', label: 'Keepalive interval', placeholder: '15s', help: 'How often a stream that is waiting is kept alive.' },
      { name: 'max_request_bytes', label: 'Largest request', placeholder: '64MiB', help: 'A request with a larger body is refused.' },
    ],
    apps: [
      { id: 'claude', label: 'Claude Code' }, { id: 'codex', label: 'Codex' }, { id: 'gemini', label: 'Gemini CLI' }, { id: 'pi', label: 'pi' }, { id: 'opencode', label: 'OpenCode' },
      { id: 'openai', label: 'OpenAI-compatible' }, { id: 'curl', label: 'curl' },
    ],
    app: 'claude',
    path: null,
    hash: null,
    original: null,
    model: null,
    status: null,
    presets: [],
    // Presets that serve some models to accounts without a key.
    keylessPresets: [],
    messages: [],
    saving: false,
    // Why the last save was refused, shown in the dialog that asked for it.
    saveError: '',
    // The file changed elsewhere: {document}, what was being saved.
    conflict: null,
    // A question before something is removed: {title, text, action, run}.
    question: null,
    navOpen: false,
    // The add dialog's account, the accounts, models and clients being edited.
    draft: null,
    accountEdit: null,
    modelEdit: null,
    clientEdit: null,
    // The account being signed in: {provider, account, id, url, callback, error, busy}.
    signing: null,
    settings: null,
    jsonText: '',
    jsonError: '',
    activity: null,
    session: null,
    sessionRequests: [],
    expanded: {},
    usage: null,
    today: null,
    quotas: null,
    quotasBusy: false,
    usageDays: 1,
    usageBy: 'accounts',
    usageGroups: [
      { id: 'accounts', label: 'Account' }, { id: 'clients', label: 'Client' },
      { id: 'programs', label: 'Program' }, { id: 'models', label: 'Model' },
    ],

    async start() {
      // The page's state lives in the URL's fragment, so a reload or a
      // shared link opens the same view: #usage?days=7&by=models.
      this.readHash();
      window.addEventListener('hashchange', () => this.readHash());
      for (const name of ['tab', 'usageDays', 'usageBy', 'session']) this.$watch(name, () => this.writeHash());
      if (this.token) await this.load();
      this.refreshTab();
      setInterval(() => { if (this.token && ['home', 'accounts'].includes(this.tab)) this.refreshTab(); }, 5000);
      setInterval(() => { if (this.token && this.tab === 'activity') this.refreshActivity(); }, 2000);
      setInterval(() => { if (this.token && this.tab === 'usage') this.refreshUsage(); }, 10000);
      this.$watch('tab', () => { this.navOpen = false; this.refreshTab(); });
    },

    pages() { return this.navigation.filter(p => p.id); },
    page() { return this.pages().find(p => p.id === this.tab); },
    go(tab) { this.tab = tab; },

    // What the page in view shows, read again.
    refreshTab() {
      if (!this.token || !this.model) return;
      if (this.tab === 'home') { this.refreshStatus(); this.refreshActivity(); this.refreshToday(); this.refreshQuotas(false); }
      if (this.tab === 'accounts') { this.refreshStatus(); this.refreshQuotas(false); }
      if (this.tab === 'models' || this.tab === 'clients') this.refreshStatus();
      if (this.tab === 'activity') this.refreshActivity();
      if (this.tab === 'usage') this.refreshUsage();
      if (this.tab === 'settings') this.showSettings();
    },

    readHash() {
      const fragment = location.hash.slice(1);
      const mark = fragment.indexOf('?');
      const name = decodeURIComponent(mark < 0 ? fragment : fragment.slice(0, mark));
      const params = new URLSearchParams(mark < 0 ? '' : fragment.slice(mark + 1));
      this.tab = this.pages().some(p => p.id === name) ? name : 'home';
      const days = Number(params.get('days'));
      if ([1, 7, 30].includes(days) && days !== this.usageDays) { this.usageDays = days; if (this.model) this.refreshUsage(); }
      const by = params.get('by');
      if (this.usageGroups.some(g => g.id === by)) this.usageBy = by;
      const session = params.get('session');
      if (session !== (this.session?.id ?? null)) {
        this.session = session ? { id: session } : null;
        this.sessionRequests = [];
        if (this.model && this.tab === 'activity') this.refreshActivity();
      }
    },

    writeHash() {
      const params = new URLSearchParams();
      if (this.tab === 'usage') {
        if (this.usageDays !== 1) params.set('days', this.usageDays);
        if (this.usageBy !== 'accounts') params.set('by', this.usageBy);
      }
      if (this.tab === 'activity' && this.session) params.set('session', this.session.id);
      const query = params.toString();
      const hash = '#' + this.tab + (query ? '?' + query : '');
      if (location.hash !== hash) history.replaceState(null, '', hash);
    },

    setTheme(theme) {
      this.theme = theme;
      document.documentElement.setAttribute('data-bs-theme', theme);
      try { localStorage.setItem(THEME_KEY, theme); } catch { /* the choice is not kept */ }
    },

    // Activity and usage

    async refreshActivity() {
      const result = await this.api('GET', 'activity');
      if (result.status === 200) this.activity = result.json;
      if (this.session) {
        const requests = await this.api('GET', 'sessions/' + encodeURIComponent(this.session.id));
        if (requests.status === 200) this.sessionRequests = requests.json.requests || [];
      }
    },

    async openSession(s) {
      this.session = s;
      this.sessionRequests = [];
      await this.refreshActivity();
    },

    shownRequests() {
      if (this.session) return this.sessionRequests;
      return this.activity?.recent || [];
    },

    async refreshUsage() {
      const result = await this.api('GET', 'usage?days=' + this.usageDays);
      if (result.status === 200) this.usage = result.json;
    },

    async refreshToday() {
      const result = await this.api('GET', 'usage?days=1');
      if (result.status === 200) this.today = result.json;
    },

    async refreshQuotas(refresh) {
      if (this.quotasBusy) return;
      this.quotasBusy = true;
      try {
        const result = await this.api('GET', 'quotas' + (refresh ? '?refresh=1' : ''));
        if (result.status === 200) this.quotas = result.json.accounts || [];
      } finally {
        this.quotasBusy = false;
      }
    },

    quotaOf(provider, name) { return (this.quotas || []).find(q => q.provider === provider && q.account === name) || null; },
    quotaBarClass(used) { return used >= 90 ? 'bg-red' : used >= 70 ? 'bg-yellow' : 'bg-green'; },
    // The window with the least left, as the home page shows an account.
    tightest(provider, name) {
      const windows = this.quotaOf(provider, name)?.windows || [];
      return windows.reduce((worst, w) => (!worst || w.used > worst.used ? w : worst), null);
    },
    resetsIn(t) {
      if (!t) return '';
      const m = Math.max(0, Math.round((t - Date.now()) / 60000));
      if (m < 60) return 'resets in ' + m + 'm';
      if (m < 2880) return 'resets in ' + Math.floor(m / 60) + 'h ' + (m % 60) + 'm';
      return 'resets in ' + Math.floor(m / 1440) + 'd ' + Math.floor((m % 1440) / 60) + 'h';
    },

    tiles(usage) {
      const t = usage?.total;
      return [
        { label: 'Requests', icon: 'ti-arrows-exchange', value: t ? String(t.requests) : '–', note: t?.failures ? t.failures + ' failed' : '' },
        { label: 'Input tokens', icon: 'ti-arrow-bar-to-down', value: t ? this.count(t.tokens.input) : '–', note: '' },
        { label: 'Output tokens', icon: 'ti-arrow-bar-up', value: t ? this.count(t.tokens.output) : '–', note: '' },
        { label: 'Cache hit', icon: 'ti-bolt', value: (t && this.cacheShare(t.tokens)) || '–', note: '' },
      ];
    },

    accountOf(r) { return r.provider ? r.provider + '/' + (r.account || '-') : ''; },
    count(n) {
      if (n == null) return '';
      if (n >= 1e9) return (n / 1e9).toFixed(2) + 'B';
      if (n >= 1e6) return (n / 1e6).toFixed(2) + 'M';
      if (n >= 1e4) return (n / 1e3).toFixed(1) + 'k';
      return String(n);
    },
    cacheShare(t) { return t && t.input ? Math.round(100 * t.cache_read / t.input) + '%' : ''; },
    duration(ms) {
      if (ms == null) return '';
      if (ms < 1000) return ms + 'ms';
      if (ms < 60000) return (ms / 1000).toFixed(1) + 's';
      return Math.floor(ms / 60000) + 'm' + Math.round((ms % 60000) / 1000) + 's';
    },
    clock(t) {
      const d = new Date(t), now = new Date();
      const time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
      return d.toDateString() === now.toDateString() ? time : d.toLocaleDateString([], { month: 'short', day: 'numeric' }) + ' ' + time;
    },
    ago(t, now) {
      const s = Math.max(0, Math.round(((now || this.activity?.now || Date.now()) - t) / 1000));
      if (s < 60) return s + 's ago';
      if (s < 3600) return Math.floor(s / 60) + 'm ago';
      if (s < 86400) return Math.floor(s / 3600) + 'h ago';
      return Math.floor(s / 86400) + 'd ago';
    },
    short(id) { return id && id.length > 14 ? id.slice(0, 12) + '…' : id; },

    // The panel's own sign-in, and the file

    async api(method, path, body) {
      const response = await fetch('/admin/api/' + path, {
        method,
        headers: { 'Authorization': 'Bearer ' + this.token, 'Content-Type': 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      let json = {};
      try { json = await response.json(); } catch (e) {}
      if (response.status === 401) { this.signOut('The panel token was refused.'); }
      return { status: response.status, json };
    },

    async signIn() {
      this.token = this.tokenInput.trim();
      this.tokenInput = '';
      await this.load();
      this.refreshTab();
    },

    signOut(reason) {
      localStorage.removeItem(TOKEN_KEY);
      this.token = '';
      this.model = null;
      this.signInError = typeof reason === 'string' ? reason : '';
    },

    // Reads the file as it is on disk; what the forms showed is dropped.
    async load() {
      const config = await this.api('GET', 'config');
      if (config.status !== 200) {
        if (config.status !== 401) this.signInError = config.json.error || ('HTTP ' + config.status);
        return;
      }
      localStorage.setItem(TOKEN_KEY, this.token);
      this.signInError = '';
      this.path = config.json.path;
      this.hash = config.json.hash;
      this.original = config.json.document || {};
      this.model = fromDocument(this.original);
      this.settings = null;
      if (this.tab === 'settings') this.showSettings();
      await this.refreshStatus();
    },

    async refreshStatus() {
      const result = await this.api('GET', 'status');
      if (result.status === 200) {
        this.status = result.json;
        this.presets = result.json.presets || [];
        this.keylessPresets = result.json.keyless_presets || [];
      }
    },

    // Writes the forms (or `document`) to the file, which is then in
    // force. A refusal puts the forms back as the file has them and is
    // told in `saveError`; a file changed elsewhere asks what to do.
    async persist(document) {
      document = document || toDocument(this.model, this.original);
      return this.write({ document, hash: this.hash }, document);
    },

    async write(body, document) {
      this.saving = true;
      this.saveError = '';
      try {
        const result = await this.api('PUT', 'config', body);
        if (result.status === 200) {
          this.conflict = null;
          const warnings = result.json.warnings || [];
          if (warnings.length) this.say('warning', 'Saved, with a warning', warnings.join('\n'));
          await this.load();
          return true;
        }
        this.model = fromDocument(this.original);
        if (result.status === 409) {
          this.draft = this.accountEdit = this.modelEdit = this.clientEdit = this.question = null;
          this.conflict = { document };
        } else if (result.status !== 401) {
          const where = result.json.location ? result.json.location + ': ' : '';
          this.saveError = where + (result.json.error || 'HTTP ' + result.status);
        }
        return false;
      } finally {
        this.saving = false;
      }
    },

    // A change made outside a dialog: a refusal is told in a message.
    async apply() {
      if (!(await this.persist()) && this.saveError) this.say('danger', 'Not saved', this.saveError);
    },

    // The answers to a file changed elsewhere.
    async overwrite() {
      const document = this.conflict.document;
      if (await this.write({ document, overwrite: true }, document)) this.say('success', 'Saved over the file', '');
      else if (this.saveError) { this.conflict = null; this.say('danger', 'Not saved', this.saveError); }
    },
    async takeFile() {
      this.conflict = null;
      await this.load();
    },

    async reloadFile() {
      const result = await this.api('POST', 'reload');
      if (result.status === 200) this.say('success', 'The file was read again and is in force', '');
      else if (result.status !== 401) this.say('danger', 'The file does not load', result.json.error || '');
      await this.load();
    },

    // A message in the corner. The same one said again takes the place of
    // the first; all but refusals go away by themselves.
    say(kind, title, text) {
      const id = ++counter;
      this.messages = this.messages.filter(m => !(m.kind === kind && m.title === title && m.text === text));
      this.messages.push({ id, kind, title, text });
      if (kind !== 'danger') setTimeout(() => { this.messages = this.messages.filter(m => m.id !== id); }, kind === 'warning' ? 12000 : 5000);
    },
    messageIcon(kind) { return { success: 'ti-circle-check text-success', warning: 'ti-alert-triangle text-warning', danger: 'ti-alert-circle text-danger' }[kind] || 'ti-info-circle text-info'; },

    ask(title, text, action, run) { this.question = { title, text, action, run }; },
    async answer() {
      const run = this.question.run;
      this.question = null;
      await run();
    },

    async copy(text) {
      try {
        await navigator.clipboard.writeText(text);
      } catch {
        // No clipboard on a plain http address: the old way.
        const area = document.createElement('textarea');
        area.value = text;
        document.body.appendChild(area);
        area.select();
        document.execCommand('copy');
        area.remove();
      }
      this.say('success', 'Copied', '');
    },

    // Providers

    brandName(id) { return BRANDS[id]?.[0] || id; },
    brandIcon(id) { const icon = BRANDS[id]?.[1]; return icon ? ICONS + icon + '.svg' : ''; },
    initials(id) { return (id || '?').replace(/[^a-zA-Z0-9]/g, '').slice(0, 2).toUpperCase() || '?'; },
    signsIn(provider) { return SIGN_IN.includes(provider); },
    takesKeys(provider) { return !KEYLESS.includes(provider); },
    // The key may stay empty: the provider serves some models without one.
    keyOptional(provider) { return this.keylessPresets.includes(provider); },
    antigravityRisk: 'Not supported by Google: Antigravity\'s sign-in is meant for Antigravity alone, and Google may suspend an account it sees used elsewhere. Use an account you can afford to lose. Use at your own risk.',

    // Home

    // What is wrong or about to be, each with what to do about it.
    attention() {
      const items = [];
      for (const a of this.status?.accounts || []) {
        const who = a.provider + '/' + a.name;
        if (a.sign_in && a.sign_in.state !== 'signed in') {
          items.push({
            kind: 'danger', icon: 'ti-login-2', text: who + (a.sign_in.state === 'lapsed' ? ': the sign-in has lapsed' : ': not signed in yet'),
            action: 'Sign in', run: () => this.startSignIn(a.provider, a.name),
          });
        } else if (a.state === 'disabled') {
          items.push({
            kind: 'danger', icon: 'ti-key-off', text: who + ': the key was refused repeatedly and is no longer tried',
            action: 'Try it again', run: () => this.resetKey(a.provider, a.name),
          });
        } else if (a.state === 'cooling') {
          items.push({ kind: 'warning', icon: 'ti-snowflake', text: who + ': cooling down, tried again in ' + a.cooling_seconds + 's', action: 'Try it now', run: () => this.resetKey(a.provider, a.name) });
        }
        for (const w of this.quotaOf(a.provider, a.name)?.windows || []) {
          if (w.used >= 90) items.push({ kind: 'warning', icon: 'ti-gauge', text: who + ': ' + Math.round(100 - w.used) + '% left of ' + t(w.name), action: '', run: null });
        }
      }
      for (const c of this.status?.cooling || []) {
        items.push({ kind: 'warning', icon: 'ti-plug-connected-x', text: c.provider + ': ' + c.what + ', retried in ' + c.cooling_seconds + 's', action: '', run: null });
      }
      if (this.exposed()) {
        items.push({
          kind: 'warning', icon: 'ti-lock-open', text: 'No client key is set: anyone who reaches the gateway can spend from your accounts.',
          action: 'Add a client key', run: () => { this.go('clients'); this.startClient(null); },
        });
      }
      return items;
    },
    // No client key, on an address other machines reach.
    exposed() {
      const host = (this.status?.listen || '').replace(/:\d+$/, '');
      return this.status && !this.model.clients.some(c => c.enabled) && !['127.0.0.1', 'localhost', '[::1]', '::1'].includes(host);
    },
    // The three steps to a working gateway.
    steps() {
      return [
        { label: 'Add an account', done: this.model.accounts.length > 0 || (this.status?.accounts || []).length > 0 },
        { label: 'Give your tools a key', done: this.model.clients.length > 0 },
        { label: 'Connect a tool', done: (this.activity?.sessions || []).length > 0 || (this.today?.total?.requests || 0) > 0 },
      ];
    },
    // What a tool is given to reach the gateway. A client's key is
    // readable only while it is entered: the file's own are hidden.
    snippet(app) {
      const base = this.origin, key = this.model.clients.length ? 'YOUR_CLIENT_KEY' : 'unladen';
      if (app === 'claude') return 'export ANTHROPIC_BASE_URL=' + base + '\nexport ANTHROPIC_AUTH_TOKEN=' + key + '\nclaude';
      if (app === 'codex') {
        return '# ~/.codex/config.toml\nmodel_provider = "unladen"\n\n[model_providers.unladen]\nname = "unladen"\nbase_url = "' + base + '/v1"\n'
          + 'wire_api = "responses"\nenv_key = "UNLADEN_API_KEY"\n\n# shell\nexport UNLADEN_API_KEY=' + key;
      }
      // Gemini CLI, pi and OpenCode ask for the models they are told of:
      // the names on the Models page.
      const names = this.menuNames().filter(name => !name.includes('*'));
      const listed = names.length ? names : ['MODEL_NAME'];
      if (app === 'gemini') return 'export GOOGLE_GEMINI_BASE_URL=' + base + '\nexport GEMINI_API_KEY=' + key + '\ngemini -m ' + listed[0];
      if (app === 'pi') {
        const models = listed.map(name => '{ "id": ' + JSON.stringify(name) + ' }').join(',\n        ');
        return '{\n  "providers": {\n    "unladen": {\n      "baseUrl": "' + base + '/v1",\n      "api": "openai-completions",\n'
          + '      "apiKey": "' + key + '",\n      "models": [\n        ' + models + '\n      ]\n    }\n  }\n}';
      }
      if (app === 'opencode') {
        const models = listed.map(name => JSON.stringify(name) + ': {}').join(',\n        ');
        return '{\n  "$schema": "https://opencode.ai/config.json",\n  "provider": {\n    "unladen": {\n      "npm": "@ai-sdk/openai-compatible",\n'
          + '      "name": "Unladen",\n      "options": {\n        "baseURL": "' + base + '/v1",\n        "apiKey": "' + key + '"\n      },\n'
          + '      "models": {\n        ' + models + '\n      }\n    }\n  }\n}';
      }
      if (app === 'openai') return 'Base URL: ' + base + '/v1\nAPI key:  ' + key;
      return 'curl ' + base + '/v1/models \\\n  -H "Authorization: Bearer ' + key + '"';
    },
    appNote(app) {
      return {
        claude: 'Claude Code speaks the Anthropic protocol; the gateway answers it with any model you set up.',
        codex: 'Codex speaks the Responses protocol.',
        gemini: 'Gemini CLI speaks the Gemini protocol. If it asks how to sign in, choose the Gemini API key; -m names the model to ask for.',
        opencode: 'Goes in ~/.config/opencode/opencode.json, or opencode.json in a project. List the models OpenCode may ask for under models, then choose one with /models.',
        pi: 'Goes in ~/.pi/agent/models.json. List the models pi may ask for under models, then choose one with /model.',
        openai: 'For any tool that takes an OpenAI base URL and key. Anthropic and Gemini clients use the same address without /v1.',
        curl: 'Lists the models this key may ask for.',
      }[app];
    },

    // Accounts

    accountProvider(a) { return a.custom ? a.name : (a.provider || a.name); },
    // Accounts by provider, in the file's order: a provider's accounts are
    // its pool. Accounts from the environment come after the file's.
    accountGroups() {
      const groups = [], byProvider = {};
      const group = provider => byProvider[provider] || (groups.push(byProvider[provider] = { provider, accounts: [], fromEnvironment: [] }), byProvider[provider]);
      for (const a of this.model.accounts) group(this.accountProvider(a).trim()).accounts.push(a);
      for (const s of this.status?.accounts || []) if (s.source === 'environment') group(s.provider).fromEnvironment.push(s);
      return groups;
    },
    // The account as the gateway has it in force, when it has.
    inForce(a) {
      const name = a.name.trim(), provider = this.accountProvider(a).trim();
      return (this.status?.accounts || []).find(s => s.provider === provider && s.name === name) || null;
    },
    // How an account is doing, in one word and a colour.
    accountState(a, live) {
      if (a && !a.enabled) return { color: 'secondary', label: 'turned off' };
      if (!live) return { color: 'secondary', label: 'not in force' };
      if (live.sign_in && live.sign_in.state !== 'signed in') {
        return live.sign_in.state === 'lapsed' ? { color: 'red', label: 'sign-in lapsed' } : { color: 'orange', label: 'not signed in' };
      }
      if (live.state === 'disabled') return { color: 'red', label: 'key refused' };
      if (live.state === 'cooling') return { color: 'yellow', label: 'cooling down' };
      return { color: 'green', label: 'ready' };
    },
    poolOf(provider) { return this.model.pools[provider] || 'order'; },
    async setPool(provider, pick) {
      this.model.pools[provider] = pick;
      await this.apply();
    },
    // Moves an account among its provider's: earlier is tried first.
    canMove(group, a, by) { const i = group.accounts.indexOf(a) + by; return i >= 0 && i < group.accounts.length; },
    async moveAccount(group, a, by) {
      const other = group.accounts[group.accounts.indexOf(a) + by];
      const all = this.model.accounts, i = all.indexOf(a), j = all.indexOf(other);
      [all[i], all[j]] = [all[j], all[i]];
      await this.apply();
    },
    async setAccountEnabled(a, enabled) {
      a.enabled = enabled;
      await this.apply();
    },
    removeAccount(a) {
      this.ask('Remove ' + a.name + '?', 'The account is taken out of the configuration file. Models that point at it stay, and fail until they point elsewhere.', 'Remove', async () => {
        this.model.accounts.splice(this.model.accounts.indexOf(a), 1);
        await this.apply();
      });
    },
    async resetKey(provider, key) {
      await this.api('POST', 'keys/reset', { provider, key });
      await this.refreshStatus();
    },

    startAccount(a) {
      this.saveError = '';
      this.accountEdit = {
        original: a.name, name: a.name, key: a.key, enabled: a.enabled, custom: a.custom, preset: a.preset,
        provider: this.accountProvider(a),
        endpoints: a.endpoints.map(e => ({ ...e })), headers: a.headers.map(h => ({ ...h })),
      };
    },
    async saveAccount() {
      const e = this.accountEdit;
      const a = this.model.accounts.find(a => a.name === e.original);
      if (!a) { this.accountEdit = null; return; }
      const name = e.name.trim();
      // An account named after its provider keeps the provider once renamed.
      if (!a.custom && !a.provider && name !== a.name) a.provider = a.name;
      Object.assign(a, { name, key: e.key, enabled: e.enabled, endpoints: e.endpoints, headers: e.headers });
      if (await this.persist()) this.accountEdit = null;
    },

    // Presets, and the accounts that are providers of their own.
    providerIds() {
      const ids = new Set(this.presets);
      for (const a of this.model.accounts) if (a.custom && a.name.trim()) ids.add(a.name.trim());
      return [...ids].sort();
    },
    // The add dialog's providers, as the search narrows them: those that
    // sign in, those of your own addresses, and the rest.
    providerChoices() {
      const query = (this.draft?.query || '').trim().toLowerCase();
      const own = this.model.accounts.filter(a => a.custom && a.name.trim()).map(a => a.name.trim());
      const matches = id => !query || id.toLowerCase().includes(query) || this.brandName(id).toLowerCase().includes(query);
      // The providers most come for, then the rest by name.
      const first = id => { const i = FEATURED.indexOf(id); return i < 0 ? FEATURED.length : i; };
      const byName = (a, b) => first(a) - first(b) || this.brandName(a).localeCompare(this.brandName(b));
      return [
        { label: 'Sign in with a subscription', ids: SIGN_IN.filter(id => this.presets.includes(id) && matches(id)) },
        { label: 'Your own addresses', ids: own.filter(matches) },
        { label: 'With an API key', ids: this.presets.filter(id => !SIGN_IN.includes(id) && !own.includes(id) && matches(id)).sort(byName) },
      ].filter(group => group.ids.length);
    },

    startAdding() {
      this.saveError = '';
      this.draft = { step: 'pick', query: '', provider: '', name: '', autoName: '', key: '', preset: '', protocol: 'chat', url: '', suggestions: [] };
    },
    // `provider`: a preset or an address of your own; empty: a new address.
    pickProvider(provider) {
      this.draft.provider = provider;
      this.draft.step = 'details';
      this.draftChanged(true);
    },
    // A name that follows the provider until it is typed over, and the
    // models the provider's family suggests.
    draftChanged(fresh) {
      const d = this.draft;
      if (fresh || d.autoName === d.name) {
        const taken = new Set(this.model.accounts.map(a => a.name.trim()));
        const base = d.provider || 'relay';
        let name = base, n = 2;
        while (taken.has(name)) name = base + '-' + n++;
        d.name = d.autoName = name;
      }
      const provider = d.provider || d.name.trim();
      d.suggestions = [];
      for (const name of FAMILIES[d.provider] || []) {
        const existing = this.model.models.find(r => r.name.trim() === name);
        const current = existing ? (existing.raw === undefined ? existing.target.trim() : JSON.stringify(existing.raw)) : '';
        if (existing && current === provider) continue;
        d.suggestions.push({ name, target: provider, current, chosen: !existing });
      }
    },
    draftProblem() {
      const d = this.draft;
      if (!d) return '';
      const name = d.name.trim();
      if (!name) return 'Give the account a name.';
      if (/[\/*]/.test(name) || name.startsWith('@')) return 'A name cannot contain / or * or start with @.';
      if (this.model.accounts.some(a => a.name.trim() === name)) return 'Another account has this name.';
      if (d.provider && name !== d.provider && this.presets.includes(name)) return name + ' is a provider: give this account another name.';
      if (d.provider && !this.signsIn(d.provider) && !this.keyOptional(d.provider) && !d.key.trim()) return 'Enter the key.';
      if (!d.provider && !/^https?:\/\//.test(d.url.trim())) return 'Enter the endpoint address (http:// or https://).';
      return '';
    },
    // The add dialog signs the account in when it has no key to give.
    draftSignsIn() { return this.signsIn(this.draft.provider) && !this.draft.key.trim(); },
    async addAccount() {
      const d = this.draft, name = d.name.trim();
      const account = { uid: ++counter, name, provider: '', key: this.signsIn(d.provider) ? '' : d.key.trim(), enabled: true, custom: false, preset: '', endpoints: [], headers: [], rest: {} };
      if (d.provider) {
        account.provider = d.provider === name ? '' : d.provider;
      } else {
        account.custom = true;
        account.preset = d.preset;
        account.endpoints = [{ uid: ++counter, protocol: d.protocol, url: d.url.trim() }];
      }
      this.model.accounts.push(account);
      for (const s of d.suggestions.filter(s => s.chosen)) {
        const existing = this.model.models.find(r => r.name.trim() === s.name);
        if (existing) { existing.target = s.target; existing.raw = undefined; }
        else this.model.models.push({ uid: ++counter, name: s.name, target: s.target, raw: undefined });
      }
      if (await this.persist()) {
        this.draft = null;
        this.say('success', 'Added ' + name, '');
        this.refreshQuotas(true);
      }
    },

    // `adding`: the account is the add dialog's, added once signed in.
    async startSignIn(provider, account, adding = false) {
      const result = await this.api('POST', 'sign-in/start', { provider, account });
      if (result.status === 200) this.signing = { provider, account, adding, id: result.json.id, url: result.json.url, redirect: result.json.redirect, callback: '', error: '', busy: false };
      else if (result.status !== 401) this.say('danger', 'Cannot sign in', result.json.error || 'HTTP ' + result.status);
    },
    async finishSignIn() {
      const s = this.signing;
      s.busy = true;
      s.error = '';
      try {
        const result = await this.api('POST', 'sign-in/finish', { id: s.id, callback: s.callback.trim() });
        if (result.status === 200) {
          this.signing = null;
          this.say('success', 'Signed in ' + s.provider + '/' + s.account, result.json.user + (result.json.plan ? ' (' + result.json.plan + ')' : ''));
          if (s.adding) await this.addAccount();
          await this.refreshStatus();
          this.refreshQuotas(true);
        } else if (result.status !== 401) {
          s.error = result.json.error || 'HTTP ' + result.status;
        }
      } finally {
        s.busy = false;
      }
    },
    forgetSignIn(provider, account) {
      this.ask('Forget the sign-in of ' + provider + '/' + account + '?', 'The account stays, and cannot be used until it signs in again.', 'Forget', async () => {
        await this.api('POST', 'sign-in/forget', { provider, account });
        await this.refreshStatus();
      });
    },

    // Models

    menuNames() { return this.model.models.map(r => r.name.trim()).filter(Boolean); },
    // Who may answer a model: the providers with an account.
    targetProviders() {
      const providers = new Set(this.model.accounts.map(a => this.accountProvider(a).trim()).filter(Boolean));
      for (const a of this.status?.accounts || []) providers.add(a.provider);
      if (this.modelEdit?.provider) providers.add(this.modelEdit.provider);
      return [...providers].sort();
    },
    // A target as its parts: `@name`, `provider` or `provider/model`.
    targetParts(target) {
      const text = (target || '').trim();
      if (text.startsWith('@')) return { kind: 'alias', alias: text.slice(1), provider: '', upstream: '' };
      const slash = text.indexOf('/');
      return { kind: 'provider', alias: '', provider: slash < 0 ? text : text.slice(0, slash), upstream: slash < 0 ? '' : text.slice(slash + 1) };
    },
    // What the gateway resolves a name to, once in force.
    resolved(name) { return (this.status?.models || []).find(r => r.name === name)?.targets || []; },
    startModel(r) {
      this.saveError = '';
      const parts = this.targetParts(r?.target);
      this.modelEdit = {
        original: r ? r.name : null, name: r ? r.name : '', raw: r?.raw,
        kind: parts.kind, alias: parts.alias, provider: parts.provider || this.targetProviders()[0] || '', upstream: parts.upstream,
      };
    },
    modelProblem() {
      const e = this.modelEdit;
      if (!e) return '';
      const name = e.name.trim();
      if (!name) return 'Give the model a name.';
      if (name !== e.original && this.menuNames().includes(name)) return 'Another model has this name.';
      if (e.raw !== undefined) return '';
      if (e.kind === 'alias' && !e.alias) return 'Choose the model it stands for.';
      if (e.kind === 'provider' && !e.provider) return 'Add an account first: a model needs a provider to answer it.';
      return '';
    },
    async saveModel() {
      const e = this.modelEdit, name = e.name.trim();
      const target = e.kind === 'alias' ? '@' + e.alias : e.provider + (e.upstream.trim() ? '/' + e.upstream.trim() : '');
      const existing = this.model.models.find(r => r.name === e.original);
      if (existing) Object.assign(existing, e.raw === undefined ? { name, target } : { name });
      else this.model.models.push({ uid: ++counter, name, target, raw: undefined });
      if (await this.persist()) this.modelEdit = null;
    },
    removeModel(r) {
      this.ask('Remove ' + r.name + '?', 'Clients that ask for this name are refused, unless another model takes it.', 'Remove', async () => {
        this.model.models.splice(this.model.models.indexOf(r), 1);
        await this.apply();
      });
    },

    // Clients

    startClient(c) {
      this.saveError = '';
      this.clientEdit = c
        ? { original: c.name, name: c.name, key: c.key, access: c.access, chosen: [...c.chosen], extra: c.extra, enabled: c.enabled }
        : { original: null, name: '', key: generateSecret(), access: 'menu', chosen: [], extra: '', enabled: true };
    },
    clientProblem() {
      const e = this.clientEdit;
      if (!e) return '';
      const name = e.name.trim();
      if (!name) return 'Give the client a name.';
      if (name !== e.original && this.model.clients.some(c => c.name.trim() === name)) return 'Another client has this name.';
      if (!e.key.trim()) return 'Enter the key.';
      return '';
    },
    async saveClient() {
      const e = this.clientEdit;
      const fields = { name: e.name.trim(), key: e.key.trim(), access: e.access, chosen: e.chosen, extra: e.extra, enabled: e.enabled };
      const existing = this.model.clients.find(c => c.name === e.original);
      if (existing) Object.assign(existing, fields);
      else this.model.clients.push({ uid: ++counter, rest: {}, ...fields });
      if (await this.persist()) this.clientEdit = null;
    },
    async setClientEnabled(c, enabled) {
      c.enabled = enabled;
      await this.apply();
    },
    removeClient(c) {
      const last = this.model.clients.length === 1;
      this.ask('Remove ' + c.name + '?', last ? 'With no client key left, anyone who reaches the gateway may use it.' : 'Tools that present this key are refused.', 'Remove', async () => {
        this.model.clients.splice(this.model.clients.indexOf(c), 1);
        await this.apply();
      });
    },
    accessSummary(c) {
      if (c.access === 'menu') return 'Every model';
      if (c.access === 'all') return 'Everything, provider/model too';
      const names = [...c.chosen, ...globs(c.extra)];
      return names.length ? names.join(', ') : 'No model';
    },

    // Settings

    showSettings() {
      if (!this.model) return;
      if (!this.settings) this.settings = { ...this.model.advanced };
      this.jsonText = JSON.stringify(this.original, null, 2);
      this.jsonError = '';
    },
    settingsChanged() { return !!this.settings && JSON.stringify(this.settings) !== JSON.stringify(this.model.advanced); },
    async saveSettings() {
      this.model.advanced = { ...this.settings };
      if (await this.persist()) this.say('success', 'Saved and in force', '');
      else if (this.saveError) this.say('danger', 'Not saved', this.saveError);
    },
    jsonChanged() { return this.jsonText !== JSON.stringify(this.original, null, 2); },
    async saveJSON() {
      let document;
      try {
        document = JSON.parse(this.jsonText);
        if (typeof document !== 'object' || document === null || Array.isArray(document)) throw new Error('expected an object');
      } catch (e) {
        this.jsonError = 'Not valid JSON: ' + e.message;
        return;
      }
      this.jsonError = '';
      if (await this.persist(document)) this.say('success', 'Saved and in force', '');
      else this.jsonError = this.saveError;
    },

    // Helpers

    isHidden(value) { return typeof value === 'string' && HIDDEN.test(value); },
    hiddenName(value) { return value.match(HIDDEN)[1]; },
    toggle(items, value) { const i = items.indexOf(value); if (i < 0) items.push(value); else items.splice(i, 1); },
    uid() { return ++counter; },
    generateSecret,
  };
}

function generateSecret() {
  const bytes = new Uint8Array(24);
  crypto.getRandomValues(bytes);
  return 'sk-unladen-' + Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
}

// The document (the file as JSON) ↔ what the forms edit. Fields the forms
// do not know are carried in `rest` (or `raw`) and written back as they were.

function omit(object, keys) {
  const rest = {};
  for (const [k, v] of Object.entries(object || {})) if (!keys.includes(k)) rest[k] = v;
  return rest;
}

function list(value) {
  if (value === undefined || value === null) return [];
  return Array.isArray(value) ? value : [value];
}

function text(value) {
  return value === undefined || value === null ? '' : String(value);
}

function fromDocument(doc) {
  const advanced = doc.advanced || {};
  const model = {
    advanced: {},
    advancedRest: omit(advanced, [...ADVANCED, 'pools']),
    pools: { ...(advanced.pools || {}) },
    accounts: [], models: [], clients: [],
  };
  for (const field of ADVANCED) model.advanced[field] = field === 'strict' ? advanced.strict === true : text(advanced[field]);

  for (const [name, a] of Object.entries(doc.accounts || {})) {
    if (typeof a !== 'object' || a === null) {
      model.accounts.push({ uid: ++counter, name, provider: '', key: text(a), enabled: true, custom: false, preset: '', endpoints: [], headers: [], rest: {} });
      continue;
    }
    model.accounts.push({
      uid: ++counter, name,
      provider: a.provider && a.provider !== name ? a.provider : '',
      key: text(a.key),
      enabled: a.enabled !== false,
      custom: 'preset' in a || 'endpoints' in a || 'headers' in a,
      preset: a.preset || '',
      endpoints: Object.entries(a.endpoints || {}).map(([protocol, url]) => ({ uid: ++counter, protocol, url: String(url) })),
      headers: Object.entries(a.headers || {}).map(([name, value]) => ({ uid: ++counter, name, value: String(value) })),
      rest: omit(a, ['provider', 'key', 'enabled', 'preset', 'endpoints', 'headers']),
    });
  }

  for (const [name, r] of Object.entries(doc.models || {})) {
    const simple = typeof r === 'string';
    model.models.push({ uid: ++counter, name, target: simple ? r : '', raw: simple ? undefined : r });
  }
  const menu = model.models.map(r => r.name);

  for (const [name, c] of Object.entries(doc.clients || {})) {
    const client = c || {};
    const models = client.models === undefined ? null : list(client.models).map(String);
    const access = models === null ? 'menu' : models.includes('*') ? 'all' : 'some';
    model.clients.push({
      uid: ++counter, name,
      key: text(client.key),
      access,
      chosen: access === 'some' ? models.filter(m => menu.includes(m)) : [],
      extra: access === 'some' ? models.filter(m => !menu.includes(m)).join(', ') : '',
      enabled: client.enabled !== false,
      rest: omit(client, ['key', 'models', 'enabled']),
    });
  }
  return model;
}

function globs(value) {
  return value.split(',').map(s => s.trim()).filter(Boolean);
}

function scalar(value) {
  const t = String(value).trim();
  return /^[0-9]+$/.test(t) ? Number(t) : t;
}

function toDocument(model, original) {
  const sections = {};

  const accounts = {};
  for (const a of model.accounts) {
    const name = a.name.trim();
    const key = a.key.trim();
    if (!a.custom && !a.provider && a.enabled && key && !Object.keys(a.rest).length) { accounts[name] = key; continue; }
    const entry = {};
    if (a.provider && !a.custom) entry.provider = a.provider;
    if (a.custom) {
      if (a.preset) entry.preset = a.preset;
      if (a.endpoints.length) entry.endpoints = Object.fromEntries(a.endpoints.map(e => [e.protocol, e.url.trim()]));
      const headers = a.headers.filter(h => h.name.trim());
      if (headers.length) entry.headers = Object.fromEntries(headers.map(h => [h.name.trim(), h.value]));
    }
    if (key) entry.key = key;
    if (!a.enabled) entry.enabled = false;
    accounts[name] = { ...entry, ...a.rest };
  }
  if (model.accounts.length) sections.accounts = accounts;

  const models = {};
  for (const r of model.models) models[r.name.trim()] = r.raw === undefined ? r.target.trim() : r.raw;
  if (model.models.length) sections.models = models;

  const clients = {};
  for (const c of model.clients) {
    const entry = { key: c.key.trim() };
    if (c.access === 'all') entry.models = '*';
    if (c.access === 'some') entry.models = [...c.chosen, ...globs(c.extra)];
    if (!c.enabled) entry.enabled = false;
    clients[c.name.trim()] = { ...entry, ...c.rest };
  }
  if (model.clients.length) sections.clients = clients;

  let advanced = {};
  for (const field of ADVANCED) {
    if (field === 'strict') { if (model.advanced.strict) advanced.strict = true; continue; }
    if (String(model.advanced[field]).trim() !== '') advanced[field] = scalar(model.advanced[field]);
  }
  const pools = Object.fromEntries(Object.entries(model.pools).filter(([, pick]) => pick && pick !== 'order'));
  if (Object.keys(pools).length) advanced.pools = pools;
  advanced = { ...advanced, ...model.advancedRest };
  if (Object.keys(advanced).length) sections.advanced = advanced;

  // The file's order of sections, then the usual one; sections the forms
  // do not edit (listen, panel, and any the panel does not know) are kept.
  const doc = {};
  const order = Object.keys(original || {});
  for (const key of SECTIONS) if (!order.includes(key)) order.push(key);
  for (const key of order) {
    if (key in sections) doc[key] = sections[key];
    else if (!SECTIONS.includes(key)) doc[key] = original[key];
  }
  return doc;
}
