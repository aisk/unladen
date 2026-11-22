const TOKEN_KEY = 'unladen.adminToken';
const SET_ASIDE_KEY = 'unladen.setAside';
const THEME_KEY = 'unladen.theme';
const HIDDEN = /^<hidden (key-[0-9a-f]{8})>$/;
// Each usage grouping's names and their color slot, kept while the panel
// is open; outside the panel's state, as charts assign them as they draw.
const SERIES_SLOTS = {};
// The sections the forms edit. `listen` and `panel` are set in the file
// alone and carried back as they are.
const SECTIONS = ['accounts', 'models', 'clients', 'advanced'];
const ADVANCED = ['strict', 'keepalive', 'head_timeout', 'idle_timeout', 'max_request_bytes', 'fallback_max_context'];
// The names a provider's own models go by, offered as models when an
// account of it is added.
// What a first start sends every name to, until an account takes them.
const PLACEHOLDER = 'kilo/kilo-auto/free';
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
// The saves to the file: the last one queued, how many are queued or
// running, and a count of failures, which drop the saves queued before them.
let saveQueue = Promise.resolve();
let pendingSaves = 0;
let saveRound = 0;

function panel() {
  return {
    token: localStorage.getItem(TOKEN_KEY) || '',
    // The models providers list, once asked (by `listKey`): names, or
    // `null` while asking. The gateway keeps them too.
    providerModels: {},
    tokenInput: '',
    signInError: '',
    // The last request did not reach the gateway.
    unreachable: false,
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
      { id: 'models', label: 'Model routing', icon: 'ti-route', about: 'The model names clients ask for, and who answers them, in what order.' },
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
      { name: 'fallback_max_context', label: 'Longest conversation to move', placeholder: 'off', help: 'A conversation under way with more context than this (in tokens, such as 64k) is not moved to the next target of its route: it waits for the one holding its prompt cache. A route may set its own. off: no limit.' },
    ],
    apps: [
      { id: 'claude', label: 'Claude Code' }, { id: 'codex', label: 'Codex' }, { id: 'gemini', label: 'Gemini CLI' }, { id: 'pi', label: 'pi' }, { id: 'opencode', label: 'OpenCode' },
      { id: 'paimon', label: 'Paimon' }, { id: 'dsh', label: 'DeepSeek Harness' },
      { id: 'openai', label: 'OpenAI-compatible' }, { id: 'curl', label: 'curl' },
    ],
    app: 'claude',
    path: null,
    hash: null,
    original: null,
    model: null,
    status: null,
    // The things needing attention this browser was told to leave out.
    setAside: storedList(SET_ASIDE_KEY),
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
    // The add dialog's first question: `pick` (what kind of route) or
    // `provider` (whose models).
    routeIntent: null,
    routeIntents: [
      { id: 'provider', icon: 'ti-building-store', label: 'A provider\'s models', about: 'By their own names: tick the ones to offer.' },
      { id: 'name', icon: 'ti-tag', label: 'A short name for a model', about: 'Such as fast, answered by a model you choose.' },
      { id: 'chain', icon: 'ti-arrows-down', label: 'Several models tried in order', about: 'One name: the next model answers when the one before fails.' },
      { id: 'rest', icon: 'ti-asterisk', label: 'Every other name', about: 'What no route takes goes to one model.' },
      { id: 'pattern', icon: 'ti-regex', label: 'A name with a star', about: 'claude-* takes every name that starts with claude-.' },
    ],
    // The Model routing page: the name being tried and what it leads to,
    // and the providers whose models are shown, with their search.
    tryName: '',
    tryClient: '',
    tryResult: null,
    openProviders: {},
    providerFilter: {},
    // The account being signed in: {provider, account, id, url, callback, error, busy}.
    signing: null,
    settings: null,
    jsonText: '',
    jsonError: '',
    activity: null,
    session: null,
    sessionRequests: [],
    // The open session's summary, turns and placements.
    sessionDetail: null,
    // The conversation of the session the chart shows: `subagent\0model`.
    conversation: null,
    // What the mouse is over in a chart: {chart, i, x, y}.
    hover: null,
    usageMetric: 'tokens',
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
      { id: 'routes', label: 'Route' },
    ],

    async start() {
      // The page's state lives in the URL's fragment, so a reload or a
      // shared link opens the same view: #usage?days=7&by=models.
      this.readHash();
      window.addEventListener('hashchange', () => this.readHash());
      for (const name of ['tab', 'usageDays', 'usageBy', 'session']) this.$watch(name, () => this.writeHash());
      this.every(5000, () => ['home', 'accounts'].includes(this.tab), () => this.refreshTab());
      this.every(10000, () => this.tab === 'models', () => this.refreshStatus());
      this.every(2000, () => this.tab === 'activity', () => this.refreshActivity());
      this.every(10000, () => this.tab === 'usage', () => this.refreshUsage());
      // A first read that failed is tried again.
      this.every(5000, () => !this.model, () => this.load());
      this.$watch('tab', () => { this.navOpen = false; this.refreshTab(); });
      if (this.token) {
        try { await this.load(); } catch (e) { console.error(e); }
      }
      this.refreshTab();
    },

    // Runs `run` every `ms` while signed in and `when()` holds; what it
    // throws is logged, not left unhandled.
    every(ms, when, run) {
      setInterval(() => {
        if (!this.token || !when()) return;
        Promise.resolve().then(run).catch(e => console.error(e));
      }, ms);
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
      if (this.tab === 'models') this.runTry();
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
        this.sessionDetail = null;
        this.conversation = null;
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
        if (requests.status === 200) {
          this.sessionRequests = requests.json.requests || [];
          this.sessionDetail = requests.json;
          const keys = this.conversations().map(c => c.key);
          if (!keys.includes(this.conversation)) this.conversation = keys[0] ?? null;
        }
      }
    },

    async openSession(s) {
      this.session = s;
      this.sessionRequests = [];
      this.sessionDetail = null;
      this.conversation = null;
      await this.refreshActivity();
    },

    closeSession() {
      this.session = null;
      this.sessionRequests = [];
      this.sessionDetail = null;
      this.conversation = null;
    },

    // The open session's conversations: its main one and its subagents',
    // each per model name asked for; the busiest first.
    conversations() {
      const groups = new Map();
      for (const turn of this.sessionDetail?.turns || []) {
        const key = (turn.subagent || '') + '\u0000' + turn.model;
        if (!groups.has(key)) groups.set(key, { key, subagent: turn.subagent || null, model: turn.model, turns: [] });
        groups.get(key).turns.push(turn);
      }
      for (const g of groups.values()) {
        g.placement = (this.sessionDetail?.placements || []).find(p => (p.subagent || null) === g.subagent && p.model === g.model.toLowerCase()) || null;
      }
      return [...groups.values()].sort((a, b) => b.turns.length - a.turns.length);
    },
    conversationLabel(c) { return (c.subagent ? 'subagent ' + this.short(c.subagent) : 'main') + ' · ' + c.model; },
    shownConversation() { return this.conversations().find(c => c.key === this.conversation) || null; },
    // Where the conversation stands: what answered it last, how much context
    // it carries, and whether its prompt cache is likely still warm.
    conversationState(c) {
      const last = [...c.turns].reverse().find(t => t.served) || null;
      const lastTokens = [...c.turns].reverse().find(t => t.tokens)?.tokens || null;
      const now = this.activity?.now || Date.now();
      let cache = null;
      if (c.placement) {
        const left = c.placement.cache_until - now;
        cache = left > 0
          ? { warm: true, text: 'Likely warm, about ' + this.minutes(left) + ' left' }
          : { warm: false, text: 'Likely cold: last answered ' + this.ago(c.placement.at, now) };
      }
      return {
        on: c.placement ? c.placement.reference : last?.served || '',
        account: last?.account || '',
        context: c.placement?.reported_input ?? lastTokens?.input ?? null,
        cacheHit: lastTokens ? this.cacheShare(lastTokens) : '',
        cache,
        switches: this.switchesOf(c.turns).length,
        failed: c.turns.filter(t => t.failed).length,
      };
    },
    minutes(ms) { const m = Math.max(1, Math.round(ms / 60000)); return m < 60 ? m + ' min' : Math.floor(m / 60) + 'h ' + (m % 60) + 'min'; },
    // The turns answered by another target than the turn before them.
    switchesOf(turns) {
      const at = [];
      let before = null;
      turns.forEach((t, i) => {
        if (!t.served) return;
        const who = t.served + '@' + (t.account || '');
        if (before && before !== who) at.push(i);
        before = who;
      });
      return at;
    },

    // Charts

    // A stacked column chart as SVG. `columns` holds each column's values,
    // one per layer, bottom first; `colors` each layer's color; `labels`
    // the axis label under each column ('' for none); `markers` the
    // columns to mark with a line, and `failed` those to mark at the base.
    stackChart(chart, columns, colors, labels, markers = [], failed = []) {
      const W = 760, H = 200, left = 46, right = 8, top = 14, bottom = 22;
      const plotW = W - left - right, plotH = H - top - bottom;
      const totals = columns.map(c => c.reduce((a, b) => a + b, 0));
      const max = this.niceMax(Math.max(1, ...totals));
      const n = Math.max(columns.length, 1);
      const band = plotW / n;
      const barW = Math.max(2, Math.min(band - 2, 28));
      const y = v => top + plotH - (v / max) * plotH;
      const parts = [];
      for (const f of [0, 0.5, 1]) {
        const v = max * f, yy = y(v).toFixed(1);
        parts.push(`<line x1="${left}" x2="${W - right}" y1="${yy}" y2="${yy}" class="chart-grid"/>`);
        parts.push(`<text x="${left - 6}" y="${yy}" dy="0.32em" text-anchor="end" class="chart-axis">${this.count(Math.round(v))}</text>`);
      }
      columns.forEach((values, i) => {
        const x = left + i * band + (band - barW) / 2;
        if (markers.includes(i)) {
          const mx = (left + i * band).toFixed(1);
          parts.push(`<line x1="${mx}" x2="${mx}" y1="${top - 6}" y2="${top + plotH}" class="chart-marker"/>`);
        }
        let base = 0;
        const shown = values.map((v, layer) => [v, layer]).filter(([v]) => v > 0);
        shown.forEach(([v, layer], k) => {
          const y0 = y(base), y1 = y(base + v);
          base += v;
          const gap = k > 0 ? 2 : 0;
          const h = Math.max(y0 - y1 - gap, 0.5);
          const isTop = k === shown.length - 1;
          parts.push(`<path d="${this.barPath(x, y1, barW, h, isTop ? Math.min(4, barW / 2, h) : 0)}" fill="var(${colors[layer]})"/>`);
        });
        if (failed.includes(i)) {
          const cx = (x + barW / 2).toFixed(1);
          parts.push(`<circle cx="${cx}" cy="${top + plotH - 5}" r="4" class="chart-failed"/>`);
        }
        if (labels[i]) {
          parts.push(`<text x="${(x + barW / 2).toFixed(1)}" y="${H - 6}" text-anchor="middle" class="chart-axis">${labels[i]}</text>`);
        }
        parts.push(`<rect x="${(left + i * band).toFixed(1)}" y="${top}" width="${band.toFixed(1)}" height="${plotH}" fill="transparent" data-chart="${chart}" data-i="${i}"/>`);
      });
      parts.push(`<line x1="${left}" x2="${W - right}" y1="${top + plotH}" y2="${top + plotH}" class="chart-base"/>`);
      return `<svg viewBox="0 0 ${W} ${H}" class="chart" role="img">${parts.join('')}</svg>`;
    },
    // A bar whose top corners are rounded by `r`, anchored at its base.
    barPath(x, y, w, h, r) {
      if (!r) return `M${x},${y}h${w}v${h}h${-w}Z`;
      return `M${x},${y + h}V${y + r}Q${x},${y} ${x + r},${y}H${x + w - r}Q${x + w},${y} ${x + w},${y + r}V${y + h}Z`;
    },
    niceMax(v) {
      const p = Math.pow(10, Math.floor(Math.log10(v)));
      for (const m of [1, 2, 2.5, 5, 10]) if (m * p >= v) return m * p;
      return 10 * p;
    },
    chartHover(e) {
      const el = e.target.closest('[data-chart]');
      if (!el) { this.hover = null; return; }
      const box = e.currentTarget.getBoundingClientRect();
      this.hover = { chart: el.dataset.chart, i: Number(el.dataset.i), x: e.clientX - box.left, y: e.clientY - box.top, width: box.width };
    },
    tooltipStyle() {
      if (!this.hover) return '';
      const flip = this.hover.x > this.hover.width / 2;
      return `top: ${this.hover.y + 12}px; ` + (flip ? `right: ${this.hover.width - this.hover.x + 12}px` : `left: ${this.hover.x + 12}px`);
    },

    // The session chart: each turn's input, split into what was read from
    // the prompt cache, written to it, and neither.
    sessionLayers: [
      { label: 'Read from cache', color: '--series-1' },
      { label: 'Written to cache', color: '--series-3' },
      { label: 'Not cached', color: '--series-2' },
    ],
    sessionChart(c) {
      const columns = c.turns.map(t => {
        const k = t.tokens;
        if (!k) return [0, 0, 0];
        return [k.cache_read, k.cache_write, Math.max(k.input - k.cache_read - k.cache_write, 0)];
      });
      const step = Math.max(1, Math.ceil(c.turns.length / 10));
      const labels = c.turns.map((t, i) => (i % step === 0 ? String(i + 1) : ''));
      const failed = c.turns.map((t, i) => (t.failed ? i : -1)).filter(i => i >= 0);
      return this.stackChart('session', columns, this.sessionLayers.map(l => l.color), labels, this.switchesOf(c.turns), failed);
    },
    sessionTip(c, i) {
      const t = c?.turns[i];
      if (!t) return null;
      const k = t.tokens;
      const rows = k ? [
        ['Read from cache', this.count(k.cache_read)],
        ['Written to cache', this.count(k.cache_write)],
        ['Not cached', this.count(Math.max(k.input - k.cache_read - k.cache_write, 0))],
        ['Output', this.count(k.output)],
      ] : [];
      const notes = [];
      if (this.switchesOf(c.turns).includes(i)) notes.push('Answered by another target than the turn before');
      if (t.target > 1) notes.push('Fell back to target ' + t.target);
      if (t.kept) notes.push('Kept on its target: long context');
      if (t.failed) notes.push('Failed');
      return { title: 'Turn ' + (i + 1) + ' · ' + this.clock(t.t), who: t.served ? this.who(t.served, t.account) : '', rows, notes };
    },

    // The usage chart: the shown grouping's largest five, the rest as one.
    usageSeries() {
      const trend = this.usage?.trend;
      const lines = trend?.[this.usageBy] || [];
      const metric = this.usageMetric;
      const top = lines.slice(0, 5), rest = lines.slice(5);
      const slots = this.slotsFor(this.usageBy, top.map(l => l.name));
      const series = top.map(l => ({ name: l.name, values: l[metric], color: '--series-' + (slots[l.name] + 1) }));
      if (rest.length) {
        series.push({
          name: rest.length === 1 ? rest[0].name : rest.length + ' others', other: true, color: '--series-other',
          values: (trend.slots || []).map((_, i) => rest.reduce((sum, l) => sum + l[metric][i], 0)),
        });
      }
      return series;
    },
    // A color slot for each of `names` that keeps the slot it had, so
    // a name keeps its color as the period changes.
    slotsFor(grouping, names) {
      const held = SERIES_SLOTS[grouping] || {};
      const kept = {};
      for (const name of names) if (held[name] != null) kept[name] = held[name];
      const used = new Set(Object.values(kept));
      for (const name of names) {
        if (kept[name] != null) continue;
        let slot = 0;
        while (used.has(slot)) slot++;
        kept[name] = slot;
        used.add(slot);
      }
      SERIES_SLOTS[grouping] = { ...held, ...kept };
      for (const [name, slot] of Object.entries(held)) {
        if (kept[name] == null && Object.values(kept).includes(slot)) delete SERIES_SLOTS[grouping][name];
      }
      return kept;
    },
    slotLabel(slot) {
      if (this.usage?.days === 1) return String(slot).padStart(2, '0') + ':00';
      const s = String(slot);
      return Number(s.slice(4, 6)) + '/' + Number(s.slice(6, 8));
    },
    usageChart() {
      const slots = this.usage?.trend?.slots || [];
      const series = this.usageSeries();
      const columns = slots.map((_, i) => series.map(s => s.values[i] || 0));
      const step = this.usage?.days === 1 ? 3 : Math.max(1, Math.ceil(slots.length / 8));
      const labels = slots.map((slot, i) => (i % step === 0 ? this.slotLabel(slot) : ''));
      return this.stackChart('usage', columns, series.map(s => s.color), labels);
    },
    usageTip(i) {
      const slot = this.usage?.trend?.slots?.[i];
      if (slot == null) return null;
      const series = this.usageSeries();
      const value = v => (this.usageMetric === 'tokens' ? this.count(v) : String(v));
      const rows = series.filter(s => s.values[i]).map(s => [s.name, value(s.values[i]), s.color]).reverse();
      const total = series.reduce((sum, s) => sum + (s.values[i] || 0), 0);
      return {
        title: this.usage.days === 1 ? this.slotLabel(slot) + '–' + String((slot + 1) % 24).padStart(2, '0') + ':00' : this.slotLabel(slot),
        rows, total: value(total),
      };
    },
    // A row's share of the period's tokens, in percent.
    shareOf(row) {
      const t = this.usage?.total?.tokens;
      const all = t ? t.input + t.output : 0;
      return all ? (100 * (row.tokens.input + row.tokens.output)) / all : 0;
    },
    // A route's targets' shares of its requests, with their colors by place.
    targetShares(row) {
      const total = (row.targets || []).reduce((sum, t) => sum + t.requests, 0);
      return (row.targets || []).map(t => ({
        ...t, share: total ? (100 * t.requests) / total : 0, color: '--series-' + Math.min(t.position, 5),
      }));
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
        if (result.status === 200) { this.quotas = result.json.accounts || []; this.pruneAside(); }
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
    // A candidate as the panel names it: the model, and the account when
    // it is not named after its provider.
    who(reference, account) {
      const provider = (reference || '').split('/')[0];
      return account && account !== provider ? reference + '@' + account : reference;
    },
    // Which of its route's targets answered: `First choice`, `Target 2 of 3`.
    targetBadge(r) {
      const n = (r.targets || []).length;
      if (n < 2 || !r.target) return '';
      return r.target === 1 ? 'First choice' : 'Target ' + r.target + ' of ' + n;
    },
    // How the request was routed, as sentences: why it did not go to the
    // targets before the one that answered, or why it did not move on.
    routeStory(r) {
      const lines = [];
      const kept = r.kept;
      if (kept) {
        if (kept.stored_reply) lines.push('Not moved: the conversation builds on a reply kept by ' + kept.reference);
        else if (kept.reported != null) lines.push('Not moved: about ' + this.count(kept.context) + ' tokens of context (' + this.count(kept.reported) + ' reported for the last turn), over ' + this.count(kept.limit));
        else lines.push('Not moved: about ' + this.count(kept.context) + ' tokens of context (estimated), over ' + this.count(kept.limit));
      }
      const failed = (r.attempt_list || []).filter(a => a.outcome !== 'ok');
      const passed = (r.passed_over || []).filter(p => p.why !== 'kept');
      if (!failed.length && !passed.length) return lines;
      if (r.target > 1) lines.push('Fell back to target ' + r.target + ' of ' + r.targets.length);
      else if (r.served) lines.push('Another account answered');
      else if (!kept) lines.push('No target answered');
      for (const p of passed) {
        const name = this.who(p.reference, p.account);
        if (p.why === 'disabled') lines.push(name + ': disabled after repeated refusals');
        else lines.push(name + ': cooling, ' + this.duration(p.seconds * 1000) + ' left' + (p.last ? ' (after ' + p.last + ')' : ''));
      }
      for (const a of failed) lines.push(this.who(a.model, a.account) + ' failed: ' + a.outcome);
      return lines;
    },
    // Whether the story tells of something gone wrong, or only how it went.
    storyIsTrouble(r) { return !!r.failed || r.status >= 400; },
    // The headers went out before any content (older records say so in their note).
    heldHeaders(r) { return !!r.held_headers || r.note === 'headers sent before the first content'; },
    // The note, unless it only says the headers went out early.
    noteOf(r) { return r.note && r.note !== 'headers sent before the first content' ? r.note : ''; },
    changeCount(r) { return (r.changes || []).reduce((n, c) => n + c.count, 0) || r.warnings || 0; },
    changeLabel(code) {
      return {
        unknown_field: 'Kept a field it does not know',
        opaque_content: 'Kept content it does not know, as it is',
        dropped_field: 'Dropped a field the target cannot take',
        dropped_content: 'Dropped content the target cannot take',
        lossy_conversion: 'Converted, not exactly',
        unsupported_value: 'Ignored a value it does not understand',
        malformed_stream: 'The stream broke its protocol',
        adjusted: 'Adjusted to fit the model',
        unsupported_by_model: 'Left out a setting the model does not take',
      }[code] || code;
    },
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

    // A request that does not reach the gateway answers with status 0
    // and sets `unreachable` until a request reaches it again.
    async api(method, path, body) {
      let response;
      try {
        response = await fetch('/admin/api/' + path, {
          method,
          headers: { 'Authorization': 'Bearer ' + this.token, 'Content-Type': 'application/json' },
          body: body === undefined ? undefined : JSON.stringify(body),
        });
      } catch {
        this.unreachable = true;
        return { status: 0, json: { error: 'cannot reach the gateway' } };
      }
      this.unreachable = false;
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
      const accounts = JSON.stringify(this.original?.accounts);
      this.original = config.json.document || {};
      this.model = fromDocument(this.original);
      // A provider's list holds while its accounts do.
      if (JSON.stringify(this.original.accounts) !== accounts) this.providerModels = {};
      this.settings = null;
      if (this.tab === 'settings') this.showSettings();
      await this.refreshStatus();
      this.runTry();
    },

    async refreshStatus() {
      const result = await this.api('GET', 'status');
      if (result.status === 200) {
        this.status = result.json;
        this.pruneAside();
        this.presets = result.json.presets || [];
        this.keylessPresets = result.json.keyless_presets || [];
      }
    },

    // Writes the forms (or `document`) to the file, which is then in
    // force. A refusal puts the forms back as the file has them and is
    // told in `saveError`; a file changed elsewhere asks what to do.
    async persist(document) {
      document = document || toDocument(this.model, this.original);
      return this.write(document, false);
    },

    // Saves run one at a time, in the order they were asked for, each
    // with the hash the one before it left. One that fails drops those
    // queued behind it, which were made on top of it.
    write(document, overwrite) {
      const round = saveRound;
      pendingSaves++;
      this.saving = true;
      const run = async () => {
        try {
          return round === saveRound ? await this.send(document, overwrite) : false;
        } finally {
          pendingSaves--;
          this.saving = pendingSaves > 0;
        }
      };
      const result = saveQueue.then(run);
      saveQueue = result.catch(() => {});
      return result;
    },

    async send(document, overwrite) {
      this.saveError = '';
      const result = await this.api('PUT', 'config', overwrite ? { document, overwrite: true } : { document, hash: this.hash });
      if (result.status === 200) {
        this.conflict = null;
        if (result.json.hash) this.hash = result.json.hash;
        // A provider's list holds while its accounts do.
        if (JSON.stringify(document.accounts) !== JSON.stringify(this.original?.accounts)) this.providerModels = {};
        this.original = document;
        const warnings = result.json.warnings || [];
        if (warnings.length) this.say('warning', 'Saved, with a warning', warnings.join('\n'));
        // The last save queued reads the file back; one with saves behind
        // it leaves the forms holding their changes.
        if (pendingSaves === 1) await this.load();
        return true;
      }
      saveRound++;
      this.model = fromDocument(this.original);
      if (result.status === 409) {
        this.draft = this.accountEdit = this.modelEdit = this.clientEdit = this.question = null;
        this.conflict = { document };
      } else if (result.status !== 401) {
        const where = result.json.location ? result.json.location + ': ' : '';
        this.saveError = where + (result.json.error || 'HTTP ' + result.status);
      }
      return false;
    },

    // A change made outside a dialog: a refusal is told in a message.
    async apply() {
      if (!(await this.persist()) && this.saveError) this.say('danger', 'Not saved', this.saveError);
    },

    // The answers to a file changed elsewhere.
    async overwrite() {
      const document = this.conflict.document;
      if (await this.write(document, true)) this.say('success', 'Saved over the file', '');
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
      this.providerModels = {};
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

    // What needs attention and was not set aside.
    attention() { return this.problems().filter(item => !this.setAside.includes(item.id)); },
    // How many of them are set aside.
    asideCount() { return this.problems().filter(item => this.setAside.includes(item.id)).length; },
    // Leaves `item` out, in this browser, for as long as it stays true:
    // once it is over it is forgotten, and shows again if it comes back.
    dismiss(item) { this.keepAside([...this.setAside, item.id]); },
    showAside() { this.keepAside([]); },
    keepAside(ids) {
      this.setAside = ids;
      try { localStorage.setItem(SET_ASIDE_KEY, JSON.stringify(ids)); } catch { /* kept for this visit only */ }
    },
    // Forgets what was set aside and is over. An allowance not read yet
    // says nothing about its account.
    pruneAside() {
      if (!this.status || !this.setAside.length) return;
      const now = new Set(this.problems().map(item => item.id));
      const unread = id => id.startsWith('quota:') && !(this.quotas || []).some(q => id.startsWith('quota:' + q.provider + '/' + q.account + ':'));
      const kept = this.setAside.filter(id => now.has(id) || unread(id));
      if (kept.length !== this.setAside.length) this.keepAside(kept);
    },
    // What is wrong or about to be, each with what to do about it.
    problems() {
      const items = [];
      for (const a of this.status?.accounts || []) {
        const who = a.provider + '/' + a.name;
        if (a.sign_in && a.sign_in.state !== 'signed in') {
          items.push({
            id: 'sign-in:' + who, kind: 'danger', icon: 'ti-login-2', text: who + (a.sign_in.state === 'lapsed' ? ': the sign-in has lapsed' : ': not signed in yet'),
            action: 'Sign in', run: () => this.startSignIn(a.provider, a.name),
          });
        } else if (a.state === 'disabled') {
          items.push({
            id: 'disabled:' + who, kind: 'danger', icon: 'ti-key-off', text: who + ': the key was refused repeatedly and is no longer tried',
            action: 'Try it again', run: () => this.resetKey(a.provider, a.name),
          });
        } else if (a.state === 'cooling') {
          items.push({ id: 'cooling:' + who, kind: 'warning', icon: 'ti-snowflake', text: who + ': cooling down, tried again in ' + a.cooling_seconds + 's', action: 'Try it now', run: () => this.resetKey(a.provider, a.name) });
        }
        for (const w of this.quotaOf(a.provider, a.name)?.windows || []) {
          if (w.used >= 90) items.push({ id: 'quota:' + who + ':' + w.name, kind: 'warning', icon: 'ti-gauge', text: who + ': ' + Math.round(100 - w.used) + '% left of ' + t(w.name), action: '', run: null });
        }
      }
      for (const c of this.status?.cooling || []) {
        items.push({ id: 'provider:' + c.provider + ':' + c.what, kind: 'warning', icon: 'ti-plug-connected-x', text: c.provider + ': ' + c.what + ', retried in ' + c.cooling_seconds + 's', action: '', run: null });
      }
      const unserved = this.unserved();
      if (unserved.length) {
        items.push({
          id: 'unserved:' + unserved.map(u => u.name).sort().join(' '), kind: 'warning', icon: 'ti-route-off',
          text: unserved.length === 1 ? 'A model name was asked for and nothing answers it: ' + unserved[0].name : unserved.length + ' model names were asked for and nothing answers them',
          action: 'Choose who answers', run: () => this.go('models'),
        });
      }
      if (this.exposed()) {
        items.push({
          id: 'exposed', kind: 'warning', icon: 'ti-lock-open', text: 'No client key is set: anyone who reaches the gateway can spend from your accounts.',
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
      // The other tools ask for the models they are told of:
      // the names on the Model routing page.
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
      if (app === 'paimon') {
        return 'export UNLADEN_API_KEY=' + key + '\npaimon login --model anthropic:' + listed[0] + ' --api-base ' + base + ' --api-key-env UNLADEN_API_KEY\npaimon';
      }
      if (app === 'dsh') {
        const models = listed.map(name => '          - id: ' + JSON.stringify(name)).join('\n');
        return '# ~/.dsh/profiles/cli/cordis.patch.yml\n- id: llm-pi-ai\n  config:\n    providers:\n      unladen:\n        apiKeyEnv: UNLADEN_API_KEY\n'
          + '        api: openai-completions\n        baseURL: ' + base + '/v1\n        models:\n' + models + '\n\n# shell\nexport UNLADEN_API_KEY=' + key;
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
        paimon: 'Paimon speaks the Anthropic protocol here. paimon login keeps the address and the key, and makes the model the default; name another with --model anthropic:NAME or paimon model.',
        dsh: 'For dsh in the terminal; dsh web reads ~/.dsh/profiles/web instead. If the file already has an llm-pi-ai entry, put unladen under its providers: an entry replaces the whole of its config. List the models dsh may ask for under models, then choose one in the model picker.',
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
      this.ask('Remove ' + a.name + '?', 'The account is taken out of the configuration file. Routes that point at it stay, and fail until they point elsewhere.', 'Remove', async () => {
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
    // A new name follows the rules a new account's does: the file keys
    // accounts by name, so a name taken by another would replace it.
    accountProblem() {
      const e = this.accountEdit;
      if (!e) return '';
      const name = e.name.trim();
      if (!name) return 'Give the account a name.';
      if (name === e.original) return '';
      if (/[\/*]/.test(name) || name.startsWith('@')) return 'A name cannot contain / or * or start with @.';
      if (this.model.accounts.some(a => a.name !== e.original && a.name.trim() === name)) return 'Another account has this name.';
      if (!e.custom && name !== e.provider && this.presets.includes(name)) return name + ' is a provider: give this account another name.';
      return '';
    },
    async saveAccount() {
      const e = this.accountEdit;
      if (this.accountProblem()) return;
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
      this.draft = { step: 'pick', query: '', provider: '', name: '', autoName: '', key: '', preset: '', protocol: 'chat', url: '', suggestions: [], picked: [] };
    },
    // `provider`: a preset or an address of your own; empty: a new address.
    pickProvider(provider) {
      this.draft.provider = provider;
      this.draft.suggestions = [];
      this.draft.picked = [];
      this.draft.step = 'details';
      this.draftChanged(true);
    },
    // A name that follows the provider until it is typed over, and the
    // routes to add: those the provider's family suggests, and the models
    // picked from its list.
    draftChanged(fresh) {
      const d = this.draft;
      if (fresh || d.autoName === d.name) {
        const taken = new Set(this.model.accounts.map(a => a.name.trim()));
        const base = d.provider || 'relay';
        let name = base, n = 2;
        while (taken.has(name)) name = base + '-' + n++;
        d.name = d.autoName = name;
      }
      const provider = this.draftProvider();
      const before = new Map(d.suggestions.map(s => [s.name, s.chosen]));
      d.suggestions = [];
      const add = (name, picked) => {
        if (d.suggestions.some(s => s.name === name)) return;
        const existing = this.model.models.find(r => r.name.trim() === name);
        const current = existing ? (existing.raw === undefined ? existing.targets.join(', ') : JSON.stringify(existing.raw)) : '';
        if (existing && current === provider) return;
        d.suggestions.push({ name, target: provider, current, chosen: before.get(name) ?? (picked || !existing) });
      };
      for (const name of FAMILIES[d.provider] || []) add(name, false);
      // A provider whose names share no family takes every other name,
      // while none does or only the first start's free model.
      const rest = this.restRoute();
      const free = !rest || (rest.raw === undefined && rest.targets.length === 1 && rest.targets[0].trim() === PLACEHOLDER);
      if (!(FAMILIES[d.provider] || []).length && provider && provider !== 'kilo' && free) add('*', true);
      for (const name of d.picked) add(name, true);
    },
    // The provider the account being added belongs to.
    draftProvider() { return this.draft.provider || this.draft.name.trim(); },
    // The account the add dialog adds.
    draftAccount() {
      const d = this.draft, name = d.name.trim();
      const account = { uid: 0, name, provider: '', key: this.signsIn(d.provider) ? '' : d.key.trim(), enabled: true, custom: false, preset: '', endpoints: [], headers: [], rest: {} };
      if (d.provider) {
        account.provider = d.provider === name ? '' : d.provider;
      } else {
        account.custom = true;
        account.preset = d.preset;
        account.endpoints = [{ uid: 0, protocol: d.protocol, url: d.url.trim() }];
      }
      return account;
    },
    // The accounts with the one being added, to ask its provider for its
    // models before it is saved.
    draftAccounts() {
      return toDocument({ ...this.model, accounts: [...this.model.accounts, this.draftAccount()] }, this.original).accounts || {};
    },
    draftModels() { return this.modelsOf(this.draftProvider(), this.draftAccounts()); },
    askDraftModels() { if (this.draftProvider()) this.askModels(this.draftProvider(), this.draftAccounts()); },
    // Whether a model of the list is to be added as a route.
    draftPicks(name) { return this.draft.suggestions.some(s => s.name === name && s.chosen); },
    pickDraftModel(name) {
      const d = this.draft, row = d.suggestions.find(s => s.name === name);
      if (row) { row.chosen = !row.chosen; return; }
      d.picked.push(name);
      this.draftChanged();
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
      const account = this.draftAccount();
      account.uid = ++counter;
      for (const e of account.endpoints) e.uid = ++counter;
      this.model.accounts.push(account);
      for (const s of d.suggestions.filter(s => s.chosen)) {
        const existing = this.model.models.find(r => r.name.trim() === s.name);
        if (existing) Object.assign(existing, { targets: [s.target], limit: '', raw: undefined });
        else this.model.models.push({ uid: ++counter, name: s.name, targets: [s.target], limit: '', raw: undefined });
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
          this.providerModels = {};
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
    // The models `provider` lists: names, `null` while asking, or
    // `undefined` before. `accounts`: in place of the accounts in force.
    modelsOf(provider, accounts) { return this.providerModels[listKey(provider, accounts)]; },
    // Asks the gateway once for the models `provider` lists.
    async askModels(provider, accounts) {
      const key = listKey(provider, accounts);
      if (!provider || key in this.providerModels) return;
      this.providerModels[key] = null;
      const result = await this.api('POST', 'models', accounts === undefined ? { provider } : { provider, accounts });
      this.providerModels[key] = result.status === 200 ? result.json.models || [] : [];
    },
    // The longest conversation a model moves to its next target: its own, else Settings'.
    limitOf(r) { return (r.limit || '').trim() || String(this.model.advanced.fallback_max_context || '').trim() || 'off'; },
    // The route of this very name, a star's included.
    routeNamed(name) {
      const key = name.trim().toLowerCase();
      return this.model.models.find(r => r.name.trim().toLowerCase() === key) || null;
    },
    // The route with a star that takes `name`, as the gateway chooses it:
    // the one with the most letters of its own, then by name.
    patternFor(name) {
      const letters = r => r.name.replace(/\*/g, '').length;
      return this.model.models
        .filter(r => r.name.includes('*') && r.name.trim() !== '*' && globMatches(r.name.trim(), name))
        .sort((a, b) => letters(b) - letters(a) || (a.name < b.name ? -1 : 1))[0] || null;
    },
    // The provider a route offers the models of by their own names: one
    // target, the provider asked for the name the client asked for.
    offerOf(r) {
      const name = r.name.trim();
      if (r.raw !== undefined || r.targets.length !== 1 || (r.limit || '').trim()) return '';
      const parts = this.targetParts(r.targets[0]);
      if (parts.kind !== 'provider' || !parts.provider) return '';
      const same = !parts.upstream || parts.upstream === '$model' || (!name.includes('*') && parts.upstream.toLowerCase() === name.toLowerCase());
      return same ? parts.provider : '';
    },
    // The providers the page lists: those with an account, and those routes offer.
    offerProviders() {
      const providers = new Set(this.targetProviders());
      for (const r of this.model.models) { const p = this.offerOf(r); if (p) providers.add(p); }
      return [...providers].sort();
    },
    offerCount(p) { return this.model.models.filter(r => !r.name.includes('*') && this.offerOf(r) === p).length; },
    starOffers(p) { return this.model.models.filter(r => r.name.includes('*') && this.offerOf(r) === p).map(r => r.name.trim()); },
    // The routes that are not a provider's model by its own name, nor `*`.
    ownRoutes() { return this.model.models.filter(r => r.name.trim() !== '*' && !this.offerOf(r)); },
    restRoute() { return this.model.models.find(r => r.name.trim() === '*') || null; },
    // Who answers `name` now, as a row of provider `p` shows it: ticked
    // when `p` does; locked when ticking cannot change it here.
    nameState(p, name) {
      const exact = this.routeNamed(name);
      const rest = this.restRoute();
      const r = exact || (name.includes('*') ? null : this.patternFor(name));
      if (!r) return rest && !name.includes('*') && this.offerOf(rest) === p ? { checked: true, locked: true, note: 'through', who: '*' } : { checked: false };
      const first = r.raw === undefined ? this.targetParts(r.targets[0]) : null;
      const here = !!first && first.kind === 'provider' && first.provider === p;
      const who = r.raw === undefined ? r.targets.join(', ') : '';
      if (exact) {
        if (this.offerOf(r) === p) return { checked: true };
        if (name === '*') return { checked: false, note: 'now answered by', who: who || 'a route of its own', taken: true };
        if (here) return { checked: true, locked: true, note: 'in a route of its own', edit: r };
        return { checked: false, locked: true, note: who ? 'answered by' : 'answered by a route of its own', who, edit: r };
      }
      if (here) return { checked: true, locked: true, note: 'through', who: r.name.trim() };
      return { checked: false, note: 'now answered by', who, through: r.name.trim() };
    },
    // A provider's rows: its names with a star, in force or suggested,
    // the models it lists, and those offered that it does not list.
    providerRows(p) {
      const listed = this.modelsOf(p), rows = [], seen = new Set();
      const add = (name, more) => {
        const key = name.toLowerCase();
        if (seen.has(key)) return;
        seen.add(key);
        rows.push({ ...this.nameState(p, name), name, ...more });
      };
      add('*', { star: true });
      for (const name of this.starOffers(p)) add(name, { star: true });
      for (const name of FAMILIES[p] || []) add(name, { star: true });
      for (const name of listed || []) add(name, {});
      for (const r of this.model.models) if (!r.name.includes('*') && this.offerOf(r) === p) add(r.name.trim(), { unlisted: !!(listed && listed.length) });
      return rows;
    },
    filteredRows(p) {
      const words = (this.providerFilter[p] || '').toLowerCase().split(/\s+/).filter(Boolean);
      return this.providerRows(p).filter(row => words.every(w => row.name.toLowerCase().includes(w)));
    },
    shownRows(p) { return this.filteredRows(p).slice(0, 150); },
    // The rows in view that ticking would offer, and those it would take back.
    offerable(p) { return this.filteredRows(p).filter(row => !row.star && !row.checked && !row.locked); },
    withdrawable(p) { return this.filteredRows(p).filter(row => !row.star && row.checked && !row.locked); },
    offer(p, name) {
      const r = this.routeNamed(name);
      if (r) Object.assign(r, { targets: [p], limit: '', raw: undefined });
      else this.model.models.push({ uid: ++counter, name, targets: [p], limit: '', raw: undefined });
    },
    withdraw(p, name) {
      const r = this.routeNamed(name);
      if (r && this.offerOf(r) === p) this.model.models.splice(this.model.models.indexOf(r), 1);
    },
    async toggleOffer(p, row, event) {
      if (row.locked) return;
      if (row.taken) {
        // Another route has every other name: taking them is asked first.
        this.ask('Give every other name to ' + this.brandName(p) + '?', 'They now go to ' + row.who + '.', 'Give them', async () => {
          this.offer(p, row.name);
          await this.apply();
        });
        if (event) event.target.checked = false;
        return;
      }
      if (row.checked) this.withdraw(p, row.name); else this.offer(p, row.name);
      await this.apply();
    },
    async offerAll(p) {
      for (const row of this.offerable(p)) this.offer(p, row.name);
      await this.apply();
    },
    offerNone(p) {
      const rows = this.withdrawable(p);
      this.ask('Stop offering ' + rows.length + ' models of ' + this.brandName(p) + '?', 'Clients that ask for these names are refused, unless another route takes them.', 'Stop offering', async () => {
        for (const row of rows) this.withdraw(p, row.name);
        await this.apply();
      });
    },
    // The add dialog's first answer.
    pickIntent(id) {
      if (id !== 'provider') { this.routeIntent = null; this.startModel(null, id); return; }
      const providers = this.offerProviders();
      if (providers.length === 1) this.showProvider(providers[0]); else this.routeIntent = 'provider';
    },
    showProvider(p) {
      this.routeIntent = null;
      this.openProviders[p] = true;
    },
    intentTitle(intent) { return (this.routeIntents.find(c => c.id === intent) || this.routeIntents[1]).label; },

    // What a name leads to, asked of the gateway: the configuration in force.
    async runTry() {
      const name = this.tryName.trim();
      if (!name || !this.token) { this.tryResult = null; return; }
      const result = await this.api('POST', 'resolve', this.tryClient ? { model: name, client: this.tryClient } : { model: name });
      if (name !== this.tryName.trim()) return;
      this.tryResult = result.status === 200 ? result.json : null;
    },
    // Names clients asked for that nothing answers.
    unserved() { return this.status?.unserved || []; },
    async forgetUnserved(u) {
      await this.api('POST', 'unserved/forget', { name: u.name });
      await this.refreshStatus();
    },

    // The models to pick a target from: other routes, the providers alone
    // for a name with a star, and every provider's models.
    targetChoices() {
      const e = this.modelEdit, items = [];
      if (!e) return items;
      for (const name of this.aliasNames()) if (!this.offerOf(this.routeNamed(name))) items.push('@' + name);
      const providers = this.targetProviders();
      if (e.name.includes('*')) items.push(...providers);
      for (const p of providers) for (const name of this.modelsOf(p) || []) items.push(p + '/' + name);
      return items;
    },
    loadTargets() { for (const p of this.targetProviders()) this.askModels(p); },
    targetsLoading() { return this.targetProviders().some(p => this.modelsOf(p) == null); },
    // `intent`: what the dialog is for (`name`, `chain`, `rest`, `pattern`);
    // a route being edited tells its own. `name`: the name to start with.
    startModel(r, intent, name) {
      this.saveError = '';
      if (r) intent = r.name.trim() === '*' ? 'rest' : r.name.includes('*') ? 'pattern' : r.targets.length > 1 ? 'chain' : 'name';
      const targets = r && r.targets.length ? r.targets : intent === 'chain' ? ['', ''] : [''];
      this.modelEdit = {
        original: r ? r.name : null, name: r ? r.name : intent === 'rest' ? '*' : name || '', raw: r?.raw, limit: r?.limit || '', intent,
        targets: targets.map(text => ({ uid: ++counter, text })),
      };
    },
    addTarget() { this.modelEdit.targets.push({ uid: ++counter, text: '' }); },
    moveTarget(i, by) {
      const targets = this.modelEdit.targets;
      [targets[i], targets[i + by]] = [targets[i + by], targets[i]];
    },
    removeTarget(i) { this.modelEdit.targets.splice(i, 1); },
    // The names a target may stand for: the models without a star, but this one.
    aliasNames() { return this.menuNames().filter(n => !n.includes('*') && n !== this.modelEdit.original); },
    modelProblem() {
      const e = this.modelEdit;
      if (!e) return '';
      const name = e.name.trim();
      if (!name) return 'Give the name clients ask for.';
      if (name.startsWith('@')) return 'A name cannot start with @.';
      if (name !== e.original && this.menuNames().includes(name)) return 'Another route has this name.';
      if (e.raw !== undefined) return '';
      const targets = e.targets.map(t => t.text.trim());
      if (targets.some(t => !t)) return 'Choose who answers.';
      if (targets.some(t => t.startsWith('@') && !this.aliasNames().includes(t.slice(1)))) return 'Choose the route it stands for.';
      const limit = e.limit.trim().toLowerCase();
      if (limit && limit !== 'off' && !/^[1-9][0-9]*\s*[km]?$/.test(limit)) return 'Give the length in tokens, such as 64000 or 64k, or off.';
      return '';
    },
    async saveModel() {
      const e = this.modelEdit, name = e.name.trim();
      const targets = e.targets.map(t => t.text.trim());
      const existing = this.model.models.find(r => r.name === e.original);
      const entry = e.raw === undefined ? { name, targets, limit: e.limit.trim() } : { name };
      if (existing) Object.assign(existing, entry);
      else this.model.models.push({ uid: ++counter, raw: undefined, ...entry });
      if (await this.persist()) this.modelEdit = null;
    },
    removeModel(r) {
      this.ask('Remove ' + r.name + '?', 'Clients that ask for this name are refused, unless another route takes it.', 'Remove', async () => {
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

// A name against a name with stars, each star any run of characters;
// letters alike in either case.
function globMatches(pattern, name) {
  const parts = pattern.toLowerCase().split('*').map(part => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  return new RegExp('^' + parts.join('.*') + '$').test(name.toLowerCase());
}

// Where a provider's model list is kept: by provider, and by the accounts
// it was asked with, if not those in force.
function listKey(provider, accounts) {
  return provider + '\n' + (accounts === undefined ? '' : JSON.stringify(accounts));
}

// A text field with a searchable list under it. `config`: `items()` (names,
// `null` while asking, `undefined` before) and `load()`; then `get()` and
// `set(value)` for one value that may also be typed, or `multi`,
// `chosen(name)` and `pick(name)` to pick several.
const COMBO_SHOWN = 100;
function combo(config) {
  return {
    open: false, typed: false, active: -1, query: '',
    get text() { return config.multi ? this.query : config.get() || ''; },
    set text(value) {
      if (config.multi) this.query = value; else config.set(value);
      this.typed = this.open = true;
      this.active = -1;
    },
    get loading() { return config.items() == null; },
    get count() { return (config.items() || []).length; },
    // Each word typed in the name, in any order.
    get matches() {
      const words = this.typed ? this.text.toLowerCase().split(/\s+/).filter(Boolean) : [];
      return (config.items() || []).filter(name => words.every(w => name.toLowerCase().includes(w)));
    },
    get shown() { return this.matches.slice(0, COMBO_SHOWN); },
    chosen(name) { return config.multi ? config.chosen(name) : name === config.get(); },
    show() {
      config.load();
      if (this.open) return;
      this.open = true;
      this.typed = false;
      this.active = -1;
    },
    move(by) {
      this.show();
      const n = this.shown.length;
      if (!n) return;
      this.active = this.active < 0 ? (by > 0 ? 0 : n - 1) : (this.active + by + n) % n;
      this.$nextTick(() => this.$refs.list?.querySelector('.active')?.scrollIntoView({ block: 'nearest' }));
    },
    choose(name) {
      if (config.multi) { config.pick(name); return; }
      config.set(name);
      this.open = false;
    },
    enter() {
      const name = this.shown[this.active];
      if (this.open && name !== undefined) this.choose(name);
      else this.open = false;
    },
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
    const entry = menuEntry(r);
    model.models.push(entry ? { uid: ++counter, name, ...entry, raw: undefined } : { uid: ++counter, name, targets: [], limit: '', raw: r });
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

// A models entry the form can edit: a target, a list of them, or `try`
// with `fallback_max_context`; `null` for anything else, kept as written.
// A list of strings kept in the browser, empty when there is none.
function storedList(key) {
  try {
    const list = JSON.parse(localStorage.getItem(key) || '[]');
    return Array.isArray(list) ? list.filter(id => typeof id === 'string') : [];
  } catch { return []; }
}

function menuEntry(value) {
  const targets = v => typeof v === 'string' ? [v] : Array.isArray(v) && v.length && v.every(t => typeof t === 'string') ? v : null;
  if (typeof value === 'string' || Array.isArray(value)) {
    const list = targets(value);
    return list && { targets: list, limit: '' };
  }
  if (value && typeof value === 'object' && Object.keys(value).every(k => k === 'try' || k === 'fallback_max_context')) {
    const list = targets(value.try);
    const limit = value.fallback_max_context;
    return list && { targets: list, limit: limit === undefined ? '' : limit === false ? 'off' : String(limit) };
  }
  return null;
}

// The entry as the file writes it: the simplest form that holds it.
function menuValue(r) {
  if (r.raw !== undefined) return r.raw;
  const targets = r.targets.map(t => t.trim()).filter(Boolean);
  const limit = (r.limit || '').trim();
  if (limit) return { try: targets, fallback_max_context: scalar(limit) };
  return targets.length === 1 ? targets[0] : targets;
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
  for (const r of model.models) models[r.name.trim()] = menuValue(r);
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
