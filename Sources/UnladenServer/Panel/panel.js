const TOKEN_KEY = 'unladen.adminToken';
const HIDDEN = /^<hidden (key-[0-9a-f]{8})>$/;
const SECTIONS = ['listen', 'panel', 'accounts', 'models', 'clients', 'advanced'];
const ADVANCED = ['strict', 'keepalive', 'connect_timeout', 'head_timeout', 'idle_timeout', 'max_request_bytes'];
// The names a provider's own models go by, offered as models when an
// account of it is added.
const FAMILIES = {
  anthropic: ['claude-*'], openai: ['gpt-*', 'o3*', 'o4*'], gemini: ['gemini-*'], deepseek: ['deepseek-*'],
  xai: ['grok-*'], moonshot: ['kimi-*'], mistral: ['mistral-*', 'codestral-*'], chatgpt: ['gpt-*'],
};
// Providers whose accounts sign in instead of holding a key.
const SIGN_IN = ['chatgpt'];
let counter = 0;

function panel() {
  return {
    token: localStorage.getItem(TOKEN_KEY) || '',
    tokenInput: '',
    signInError: '',
    tab: 'overview',
    languages: LANGUAGES,
    language,
    tabs: [
      { id: 'overview', label: 'Overview', icon: 'ti-dashboard' },
      { id: 'activity', label: 'Activity', icon: 'ti-activity' },
      { id: 'usage', label: 'Usage', icon: 'ti-chart-bar' },
      { id: 'accounts', label: 'Accounts', icon: 'ti-wallet' },
      { id: 'models', label: 'Models', icon: 'ti-list-details' },
      { id: 'clients', label: 'Clients', icon: 'ti-key' },
      { id: 'settings', label: 'Settings', icon: 'ti-settings' },
    ],
    protocols: ['chat', 'responses', 'anthropic', 'gemini'],
    advancedFields: [
      { name: 'strict', kind: 'bool', help: 'Refuse requests a model cannot take exactly' },
      { name: 'keepalive', placeholder: '15s', help: 'Keepalive interval for streams' },
      { name: 'connect_timeout', placeholder: '10s', help: 'Upstream connection timeout', restart: true },
      { name: 'head_timeout', placeholder: '240s', help: 'Wait for the first content before the next account; off: no limit' },
      { name: 'idle_timeout', placeholder: '300s', help: 'Longest silence of a forwarded stream; off: no limit' },
      { name: 'max_request_bytes', placeholder: '64MiB', help: 'Largest request body' },
    ],
    path: null,
    hash: null,
    original: null,
    model: null,
    pristine: '',
    status: null,
    presets: [],
    messages: [],
    saving: false,
    menu: false,
    adding: false,
    draft: null,
    // The account being signed in: {provider, account, id, url, callback, error, busy}.
    signing: null,
    jsonText: '',
    jsonError: '',
    activity: null,
    session: null,
    sessionRequests: [],
    expanded: {},
    usage: null,
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
      if (this.tab === 'activity') this.refreshActivity();
      if (this.tab === 'usage') this.refreshUsage();
      setInterval(() => { if (this.token && this.tab === 'overview') this.refreshStatus(); }, 5000);
      setInterval(() => { if (this.token && this.tab === 'activity') this.refreshActivity(); }, 2000);
      setInterval(() => { if (this.token && this.tab === 'usage') this.refreshUsage(); }, 10000);
      this.$watch('tab', tab => {
        if (tab === 'activity') this.refreshActivity();
        if (tab === 'usage') this.refreshUsage();
      });
    },

    readHash() {
      const fragment = location.hash.slice(1);
      const mark = fragment.indexOf('?');
      const name = decodeURIComponent(mark < 0 ? fragment : fragment.slice(0, mark));
      const params = new URLSearchParams(mark < 0 ? '' : fragment.slice(mark + 1));
      this.tab = this.tabs.some(t => t.id === name) ? name : 'overview';
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

    usageTiles() {
      const t = this.usage?.total;
      if (!t) return [];
      return [
        { label: 'Requests', value: t.requests + (t.failures ? ' (' + t.failures + ' failed)' : '') },
        { label: 'Input tokens', value: this.count(t.tokens.input) },
        { label: 'Output tokens', value: this.count(t.tokens.output) },
        { label: 'Cache hit', value: this.cacheShare(t.tokens) || '–' },
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
    ago(t) {
      const s = Math.max(0, Math.round(((this.activity?.now || Date.now()) - t) / 1000));
      if (s < 60) return s + 's ago';
      if (s < 3600) return Math.floor(s / 60) + 'm ago';
      if (s < 86400) return Math.floor(s / 3600) + 'h ago';
      return Math.floor(s / 86400) + 'd ago';
    },
    short(id) { return id && id.length > 14 ? id.slice(0, 12) + '…' : id; },

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
    },

    signOut(reason) {
      localStorage.removeItem(TOKEN_KEY);
      this.token = '';
      this.model = null;
      this.signInError = typeof reason === 'string' ? reason : '';
    },

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
      this.pristine = JSON.stringify(toDocument(this.model, this.original));
      this.adding = false;
      this.jsonText = '';
      this.jsonError = '';
      await this.refreshStatus();
    },

    async refreshStatus() {
      const result = await this.api('GET', 'status');
      if (result.status === 200) {
        this.status = result.json;
        this.presets = result.json.presets || [];
      }
    },

    dirty() { return this.model && JSON.stringify(toDocument(this.model, this.original)) !== this.pristine; },

    discard() {
      this.model = fromDocument(this.original);
    },

    async save() {
      this.saving = true;
      try {
        const document = toDocument(this.model, this.original);
        const result = await this.api('PUT', 'config', { document, hash: this.hash });
        if (result.status === 200) {
          this.say('success', 'Saved and in force', (result.json.warnings || []).join('\n'));
          await this.load();
        } else if (result.status === 409) {
          this.say('warning', 'The file was changed elsewhere', 'Reload the file from the menu to see it; your changes here would be lost.');
        } else if (result.status !== 401) {
          const where = result.json.location ? result.json.location + ': ' : '';
          this.say('danger', 'Not saved', where + (result.json.error || 'HTTP ' + result.status));
        }
      } finally {
        this.saving = false;
      }
    },

    async reloadFile() {
      const result = await this.api('POST', 'reload');
      if (result.status === 200) this.say('success', 'The file was read again and is in force', '');
      else if (result.status !== 401) this.say('danger', 'The file does not load', result.json.error || '');
      await this.load();
    },

    async resetKey(provider, key) {
      await this.api('POST', 'keys/reset', { provider, key });
      await this.refreshStatus();
    },

    signsIn(provider) { return SIGN_IN.includes(provider); },
    // The sign-in state of an account of the file, once saved.
    signInOf(a) {
      const name = a.name.trim(), provider = this.accountProvider(a).trim();
      return (this.status?.accounts || []).find(s => s.provider === provider && s.name === name)?.sign_in || null;
    },
    // `adding`: the account is the add form's, added (and saved) once signed in.
    async startSignIn(provider, account, adding = false) {
      const result = await this.api('POST', 'sign-in/start', { provider, account });
      if (result.status === 200) this.signing = { provider, account, adding, id: result.json.id, url: result.json.url, callback: '', error: '', busy: false };
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
          if (s.adding) {
            // Saved at once unless other changes are pending, which the user saves.
            const clean = !this.dirty();
            this.addAccount();
            if (clean) await this.save();
          }
          await this.refreshStatus();
        } else if (result.status !== 401) {
          s.error = result.json.error || 'HTTP ' + result.status;
        }
      } finally {
        s.busy = false;
      }
    },
    async forgetSignIn(provider, account) {
      if (!confirm(t('Forget the sign-in of ' + provider + '/' + account + '?'))) return;
      await this.api('POST', 'sign-in/forget', { provider, account });
      await this.refreshStatus();
    },

    say(kind, title, text) {
      this.messages.push({ id: ++counter, kind, title, text });
      if (kind !== 'danger' && kind !== 'warning') { const id = counter; setTimeout(() => { this.messages = this.messages.filter(m => m.id !== id); }, 5000); }
    },

    // Accounts

    accountProvider(a) { return a.custom ? a.name : (a.provider || a.name); },
    // Presets, and the accounts that are providers of their own.
    providerIds() {
      const ids = new Set(this.presets);
      for (const a of this.model.accounts) if (a.custom && a.name.trim()) ids.add(a.name.trim());
      return [...ids].sort();
    },
    // Providers with more than one account, and those the file sets.
    poolProviders() {
      const counts = {};
      for (const a of this.model.accounts) { const p = this.accountProvider(a).trim(); if (p) counts[p] = (counts[p] || 0) + 1; }
      const ids = new Set(Object.keys(counts).filter(p => counts[p] > 1));
      for (const id of Object.keys(this.model.pools)) ids.add(id);
      return [...ids].sort();
    },

    startAdding() {
      this.draft = { provider: this.presets[0] || '', name: '', autoName: '', key: '', preset: '', protocol: 'chat', url: '', suggestions: [] };
      this.draftChanged(true);
      this.adding = true;
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
      if (d.provider && !this.signsIn(d.provider) && !d.key.trim()) return 'Enter the key.';
      if (!d.provider && !/^https?:\/\//.test(d.url.trim())) return 'Enter the endpoint address (http:// or https://).';
      return '';
    },
    addAccount() {
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
      this.adding = false;
      this.say('info', 'Added ' + name, 'Save to put it in force.');
    },

    // Models and clients

    menuNames() { return this.model.models.map(r => r.name.trim()).filter(Boolean); },
    targetChoices() {
      const providers = new Set(this.model.accounts.map(a => this.accountProvider(a).trim()).filter(Boolean));
      for (const a of this.status?.accounts || []) providers.add(a.provider);
      return [...[...providers].sort(), ...this.menuNames().filter(n => !n.includes('*')).map(n => '@' + n)];
    },
    addClient() {
      this.model.clients.push({ uid: ++counter, name: '', key: generateSecret(), access: 'menu', chosen: [], extra: '', enabled: true, rest: {} });
    },
    clientSummary(models) {
      if (models === null || models === undefined) return 'every model';
      if (models.includes('*')) return 'everything, provider/model too';
      return models.join(', ');
    },

    // Settings

    showJSON() {
      this.jsonText = JSON.stringify(toDocument(this.model, this.original), null, 2);
      this.jsonError = '';
    },
    applyJSON() {
      try {
        const document = JSON.parse(this.jsonText);
        if (typeof document !== 'object' || document === null || Array.isArray(document)) throw new Error('expected an object');
        this.model = fromDocument(document);
        this.original = document;
        this.jsonError = '';
        this.say('info', 'Applied', 'Save to write the file.');
      } catch (e) {
        this.jsonError = 'Not valid JSON: ' + e.message;
      }
    },

    // Helpers

    stateClass(state) { return { ready: 'bg-success-lt', cooling: 'bg-warning-lt', disabled: 'bg-danger-lt' }[state]; },
    isHidden(value) { return typeof value === 'string' && HIDDEN.test(value); },
    hiddenName(value) { return value.match(HIDDEN)[1]; },
    move(items, index, by) { const [item] = items.splice(index, 1); items.splice(index + by, 0, item); },
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
    listen: text(doc.listen),
    panelToken: text(doc.panel?.token),
    panelRest: omit(doc.panel, ['token']),
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
  if (model.listen.trim()) sections.listen = model.listen.trim();

  const panel = { ...model.panelRest };
  if (model.panelToken.trim()) panel.token = model.panelToken.trim();
  if (Object.keys(panel).length) sections.panel = panel;

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

  // The file's order of sections, then the usual one; sections the panel
  // does not know are kept, for the server to name.
  const doc = {};
  const order = Object.keys(original || {});
  for (const key of SECTIONS) if (!order.includes(key)) order.push(key);
  for (const key of order) {
    if (key in sections) doc[key] = sections[key];
    else if (!SECTIONS.includes(key)) doc[key] = original[key];
  }
  return doc;
}
