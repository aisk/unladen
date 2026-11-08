// The control panel: one page, Tabler for the look and Alpine.js for the
// behaviour, both from a CDN. It talks to `/admin/api/*` with the admin
// token, which it keeps in the browser's localStorage.

enum AdminPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>unladen</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/core@1.6.1/dist/css/tabler.min.css">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.49.0/dist/tabler-icons.min.css">
<script defer src="https://cdn.jsdelivr.net/npm/alpinejs@3.17.5/dist/cdn.min.js"></script>
<style>
  [x-cloak] { display: none !important; }
  .secret { font-family: var(--tblr-font-monospace); }
  .table td { vertical-align: middle; }
  .w-strategy { width: 9rem; }
</style>
</head>
<body>
<div class="page" x-data="panel()" x-init="start()" x-cloak>

  <!-- Sign in -->
  <div class="page page-center" x-show="!token">
    <div class="container container-tight py-4">
      <div class="text-center mb-4"><h1 class="h2">unladen</h1></div>
      <form class="card card-md" @submit.prevent="signIn()">
        <div class="card-body">
          <h2 class="h3 text-center mb-4">Control panel</h2>
          <label class="form-label">Admin token</label>
          <input type="password" class="form-control" x-model="tokenInput" autocomplete="current-password" placeholder="server.admin.token">
          <div class="text-danger mt-2" x-text="signInError"></div>
          <button class="btn btn-primary w-100 mt-4" type="submit">Sign in</button>
        </div>
      </form>
    </div>
  </div>

  <template x-if="token && model">
  <div>
    <header class="navbar navbar-expand-md d-print-none">
      <div class="container-xl">
        <span class="navbar-brand pe-3">unladen</span>
        <ul class="navbar-nav me-auto">
          <template x-for="t in tabs" :key="t.id">
            <li class="nav-item" :class="tab === t.id && 'active'">
              <a class="nav-link" href="#" @click.prevent="tab = t.id">
                <i class="ti me-1" :class="t.icon"></i><span x-text="t.label"></span>
              </a>
            </li>
          </template>
        </ul>
        <div class="d-flex align-items-center gap-2">
          <span class="badge bg-warning-lt" x-show="dirty()">Unsaved changes</span>
          <button class="btn btn-ghost-secondary" @click="discard()" x-show="dirty()">Discard</button>
          <button class="btn btn-primary" :disabled="!dirty() || saving" @click="save()">
            <i class="ti ti-device-floppy me-1"></i>Save
          </button>
          <div class="dropdown">
            <button class="btn btn-ghost-secondary btn-icon" @click="menu = !menu" title="More"><i class="ti ti-dots-vertical"></i></button>
            <div class="dropdown-menu dropdown-menu-end" :class="menu && 'show'" @click.outside="menu = false">
              <a class="dropdown-item" href="#" @click.prevent="menu = false; reloadFile()"><i class="ti ti-refresh me-2"></i>Reload the file</a>
              <a class="dropdown-item" href="#" @click.prevent="menu = false; signOut()"><i class="ti ti-logout me-2"></i>Sign out</a>
            </div>
          </div>
        </div>
      </div>
    </header>

    <div class="page-wrapper">
      <div class="container-xl pt-3">
        <template x-for="(m, i) in messages" :key="m.id">
          <div class="alert alert-dismissible" :class="'alert-' + m.kind">
            <div class="fw-bold" x-text="m.title"></div>
            <div x-show="m.text" class="text-secondary" style="white-space: pre-wrap" x-text="m.text"></div>
            <a class="btn-close" @click="messages.splice(i, 1)"></a>
          </div>
        </template>
      </div>

      <div class="page-body mt-2">
        <div class="container-xl">

          <!-- Status -->
          <div x-show="tab === 'status'">
            <div class="text-secondary mb-3">
              Configuration file: <code x-text="path || 'none'"></code>
              <span class="ms-2">Refreshed every 5 seconds.</span>
            </div>
            <div class="row row-cards">
              <template x-for="p in (status?.providers || []).filter(p => p.configured)" :key="p.id">
                <div class="col-md-6 col-xl-4">
                  <div class="card">
                    <div class="card-header">
                      <h3 class="card-title" x-text="p.id"></h3>
                      <div class="card-actions"><span class="badge" x-show="p.strategy" x-text="p.strategy"></span></div>
                    </div>
                    <table class="table card-table">
                      <tbody>
                        <template x-for="k in p.keys" :key="k.name">
                          <tr>
                            <td class="secret" x-text="k.name"></td>
                            <td>
                              <span class="badge" :class="stateClass(k.state)" x-text="k.state"></span>
                              <span class="text-secondary ms-1" x-show="k.cooling_seconds" x-text="k.cooling_seconds + 's'"></span>
                            </td>
                            <td class="text-end">
                              <button class="btn btn-sm" x-show="k.state !== 'ready'" @click="resetKey(p.id, k.name)">Reset</button>
                            </td>
                          </tr>
                        </template>
                        <tr x-show="!p.keys.length"><td colspan="3" class="text-secondary">No key</td></tr>
                        <template x-for="e in p.endpoints.filter(e => e.cooling_seconds)" :key="e.protocol">
                          <tr><td colspan="3" class="text-warning">
                            <span x-text="e.protocol + ' endpoint unreachable, retried in ' + e.cooling_seconds + 's'"></span>
                          </td></tr>
                        </template>
                        <template x-for="m in p.cooling_models" :key="m.endpoint + m.model">
                          <tr><td colspan="3" class="text-warning">
                            <span x-text="m.model + ' failing, retried in ' + m.cooling_seconds + 's'"></span>
                          </td></tr>
                        </template>
                      </tbody>
                    </table>
                  </div>
                </div>
              </template>
            </div>
            <div class="row row-cards mt-2">
              <div class="col-md-6">
                <div class="card">
                  <div class="card-header"><h3 class="card-title">Routes in force</h3></div>
                  <table class="table card-table">
                    <tbody>
                      <template x-for="r in status?.routes || []" :key="r.name">
                        <tr><td class="secret" x-text="r.name"></td><td x-text="r.targets.join(', ')"></td></tr>
                      </template>
                      <tr x-show="!(status?.routes || []).length"><td class="text-secondary">No route: clients name provider/model.</td></tr>
                    </tbody>
                  </table>
                </div>
              </div>
              <div class="col-md-6">
                <div class="card">
                  <div class="card-header"><h3 class="card-title">Client keys in force</h3></div>
                  <table class="table card-table">
                    <tbody>
                      <template x-for="c in status?.client_keys || []" :key="c.name">
                        <tr>
                          <td x-text="c.name"></td>
                          <td class="text-secondary" x-text="'routes: ' + (c.routes ? c.routes.join(', ') : 'all') + ' · passthrough: ' + (c.passthrough.join(', ') || 'none')"></td>
                        </tr>
                      </template>
                      <tr x-show="!(status?.client_keys || []).length"><td class="text-warning">None: any client may use the gateway.</td></tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          </div>

          <!-- Providers -->
          <div x-show="tab === 'providers'">
            <div class="d-flex mb-3">
              <div class="text-secondary me-auto">
                Built-in presets need only keys. A provider of another id names the preset it is like and its endpoints.
              </div>
              <button class="btn" @click="addProvider()"><i class="ti ti-plus me-1"></i>Add provider</button>
            </div>
            <template x-for="(p, pi) in model.providers" :key="p.uid">
              <div class="card mb-3">
                <div class="card-header">
                  <input class="form-control form-control-flush h3 mb-0 secret" style="max-width: 16rem" x-model="p.id" placeholder="provider id" list="preset-list">
                  <div class="card-actions d-flex gap-2 align-items-center">
                    <select class="form-select w-strategy" x-model="p.strategy" title="How a request picks among the keys">
                      <option value="">order</option>
                      <option value="rotate">rotate</option>
                    </select>
                    <button class="btn btn-ghost-danger btn-icon" title="Remove the provider" @click="model.providers.splice(pi, 1)"><i class="ti ti-trash"></i></button>
                  </div>
                </div>
                <div class="card-body">
                  <div class="row g-3">
                    <div class="col-md-4" x-show="!isPreset(p.id) || p.preset">
                      <label class="form-label">Preset</label>
                      <select class="form-select" x-model="p.preset">
                        <option value="">none</option>
                        <template x-for="id in presets" :key="id"><option :value="id" x-text="id" :selected="p.preset === id"></option></template>
                      </select>
                    </div>
                  </div>

                  <h4 class="mt-3">Keys</h4>
                  <table class="table table-sm">
                    <thead><tr><th style="width: 12rem">Name</th><th>Key</th><th style="width: 6rem">Enabled</th><th style="width: 3rem"></th></tr></thead>
                    <tbody>
                      <template x-for="(k, ki) in p.keys" :key="k.uid">
                        <tr>
                          <td><input class="form-control form-control-sm" x-model="k.name" placeholder="key-…"></td>
                          <td>
                            <template x-if="isHidden(k.key)">
                              <div class="d-flex align-items-center gap-2">
                                <span class="secret text-secondary" x-text="'•••• ' + hiddenName(k.key)"></span>
                                <button class="btn btn-sm" @click="k.key = ''">Replace</button>
                              </div>
                            </template>
                            <template x-if="!isHidden(k.key)">
                              <input class="form-control form-control-sm secret" x-model="k.key" placeholder="sk-… or ${ENV_VAR}" autocomplete="off">
                            </template>
                          </td>
                          <td><input type="checkbox" class="form-check-input" x-model="k.enabled"></td>
                          <td><button class="btn btn-sm btn-ghost-danger btn-icon" @click="p.keys.splice(ki, 1)"><i class="ti ti-x"></i></button></td>
                        </tr>
                      </template>
                      <tr x-show="!p.keys.length"><td colspan="4" class="text-secondary">No key in the file: the environment's are used.</td></tr>
                    </tbody>
                  </table>
                  <button class="btn btn-sm" @click="p.keys.push(newKey())"><i class="ti ti-plus me-1"></i>Key</button>

                  <h4 class="mt-4">Endpoints <span class="text-secondary fw-normal" x-show="isPreset(p.id) || p.preset">(empty: the preset's)</span></h4>
                  <template x-for="(e, ei) in p.endpoints" :key="e.uid">
                    <div class="input-group input-group-sm mb-2">
                      <select class="form-select" style="max-width: 9rem" x-model="e.protocol">
                        <template x-for="proto in protocols" :key="proto"><option :value="proto" x-text="proto" :selected="e.protocol === proto"></option></template>
                      </select>
                      <input class="form-control" x-model="e.url" placeholder="https://api.example.com/v1">
                      <button class="btn btn-icon" @click="p.endpoints.splice(ei, 1)"><i class="ti ti-x"></i></button>
                    </div>
                  </template>
                  <button class="btn btn-sm" @click="p.endpoints.push({uid: uid(), protocol: 'chat', url: ''})"><i class="ti ti-plus me-1"></i>Endpoint</button>

                  <h4 class="mt-4">Headers</h4>
                  <template x-for="(h, hi) in p.headers" :key="h.uid">
                    <div class="input-group input-group-sm mb-2">
                      <input class="form-control" style="max-width: 16rem" x-model="h.name" placeholder="Header-Name">
                      <input class="form-control" x-model="h.value" placeholder="value or ${ENV_VAR}">
                      <button class="btn btn-icon" @click="p.headers.splice(hi, 1)"><i class="ti ti-x"></i></button>
                    </div>
                  </template>
                  <button class="btn btn-sm" @click="p.headers.push({uid: uid(), name: '', value: ''})"><i class="ti ti-plus me-1"></i>Header</button>
                </div>
              </div>
            </template>
            <div class="empty" x-show="!model.providers.length">
              <p class="empty-title">No provider in the file</p>
              <p class="empty-subtitle text-secondary">Built-in presets still work with keys from the environment.</p>
            </div>
          </div>

          <!-- Routes -->
          <div x-show="tab === 'routes'">
            <div class="card">
              <div class="card-header">
                <h3 class="card-title">Routes</h3>
                <div class="card-actions"><button class="btn" @click="model.routes.push({uid: uid(), name: '', target: ''})"><i class="ti ti-plus me-1"></i>Add route</button></div>
              </div>
              <div class="card-body text-secondary">
                A model name a client asks for → the <code>provider/model</code> that serves it.
                Names may use <code>*</code>; <code>$model</code> in the target stands for the name asked for;
                <code>*</code> alone catches every other name.
              </div>
              <table class="table card-table">
                <thead><tr><th style="width: 40%">Model name</th><th>Target</th><th style="width: 3rem"></th></tr></thead>
                <tbody>
                  <template x-for="(r, ri) in model.routes" :key="r.uid">
                    <tr>
                      <td><input class="form-control secret" x-model="r.name" placeholder="claude-sonnet, gpt-*, *"></td>
                      <td><input class="form-control secret" x-model="r.target" placeholder="provider/model" list="provider-list"></td>
                      <td><button class="btn btn-ghost-danger btn-icon" @click="model.routes.splice(ri, 1)"><i class="ti ti-x"></i></button></td>
                    </tr>
                  </template>
                  <tr x-show="!model.routes.length"><td colspan="3" class="text-secondary">No route: clients name provider/model directly.</td></tr>
                </tbody>
              </table>
            </div>
          </div>

          <!-- Client keys -->
          <div x-show="tab === 'clients'">
            <div class="card">
              <div class="card-header">
                <h3 class="card-title">Client keys</h3>
                <div class="card-actions"><button class="btn" @click="addClient()"><i class="ti ti-plus me-1"></i>Add client key</button></div>
              </div>
              <div class="card-body text-secondary">
                Keys clients present (Bearer, <code>x-api-key</code> or <code>x-goog-api-key</code>). With none, any client may use the gateway.
              </div>
              <table class="table card-table">
                <thead><tr><th style="width: 12rem">Name</th><th>Secret</th><th>Routes</th><th>Passthrough</th><th style="width: 5rem">Enabled</th><th style="width: 3rem"></th></tr></thead>
                <tbody>
                  <template x-for="(c, ci) in model.clients" :key="c.uid">
                    <tr>
                      <td><input class="form-control form-control-sm" x-model="c.name"></td>
                      <td>
                        <template x-if="isHidden(c.secret)">
                          <div class="d-flex align-items-center gap-2">
                            <span class="secret text-secondary" x-text="'•••• ' + hiddenName(c.secret)"></span>
                            <button class="btn btn-sm" @click="c.secret = ''">Replace</button>
                          </div>
                        </template>
                        <template x-if="!isHidden(c.secret)">
                          <div class="input-group input-group-sm">
                            <input class="form-control secret" x-model="c.secret" placeholder="secret or ${ENV_VAR}" autocomplete="off">
                            <button class="btn btn-icon" title="Generate" @click="c.secret = generateSecret()"><i class="ti ti-dice-5"></i></button>
                            <button class="btn btn-icon" title="Copy" @click="navigator.clipboard.writeText(c.secret)"><i class="ti ti-copy"></i></button>
                          </div>
                        </template>
                      </td>
                      <td><input class="form-control form-control-sm secret" x-model="c.routes" placeholder="all"></td>
                      <td>
                        <div class="input-group input-group-sm">
                          <select class="form-select" style="max-width: 6rem" x-model="c.passMode">
                            <option value="none">none</option><option value="all">all</option><option value="some">some</option>
                          </select>
                          <input class="form-control secret" x-show="c.passMode === 'some'" x-model="c.passthrough" placeholder="deepseek/*, openai/gpt-*">
                        </div>
                      </td>
                      <td><input type="checkbox" class="form-check-input" x-model="c.enabled"></td>
                      <td><button class="btn btn-sm btn-ghost-danger btn-icon" @click="model.clients.splice(ci, 1)"><i class="ti ti-x"></i></button></td>
                    </tr>
                  </template>
                </tbody>
              </table>
              <div class="card-footer text-secondary">
                Routes and passthrough take comma-separated globs. Passthrough lets the client name <code>provider/model</code> directly.
              </div>
            </div>
          </div>

          <!-- Server -->
          <div x-show="tab === 'server'">
            <div class="card">
              <div class="card-body">
                <div class="row g-3">
                  <template x-for="f in serverFields" :key="f.name">
                    <div class="col-md-6">
                      <label class="form-label">
                        <span class="secret" x-text="f.name"></span>
                        <span class="badge bg-secondary-lt ms-1" x-show="f.restart">restart</span>
                      </label>
                      <template x-if="f.kind === 'bool'">
                        <label class="form-check form-switch">
                          <input class="form-check-input" type="checkbox" x-model="model.server[f.name]">
                          <span class="form-check-label" x-text="f.help"></span>
                        </label>
                      </template>
                      <template x-if="f.kind !== 'bool'">
                        <div>
                          <input class="form-control secret" x-model="model.server[f.name]" :placeholder="f.placeholder">
                          <div class="form-hint" x-text="f.help"></div>
                        </div>
                      </template>
                    </div>
                  </template>
                  <div class="col-md-6">
                    <label class="form-label"><span class="secret">admin.token</span></label>
                    <template x-if="isHidden(model.server.adminToken)">
                      <div class="d-flex align-items-center gap-2">
                        <span class="secret text-secondary" x-text="'•••• ' + hiddenName(model.server.adminToken)"></span>
                        <button class="btn btn-sm" @click="model.server.adminToken = ''">Replace</button>
                      </div>
                    </template>
                    <template x-if="!isHidden(model.server.adminToken)">
                      <input class="form-control secret" x-model="model.server.adminToken" placeholder="${UNLADEN_ADMIN_TOKEN}" autocomplete="off">
                    </template>
                    <div class="form-hint">Opens this panel; at least 16 characters. After a change, sign in again.</div>
                  </div>
                </div>
              </div>
            </div>
          </div>

        </div>
      </div>
    </div>

    <datalist id="preset-list"><template x-for="id in presets" :key="id"><option :value="id"></option></template></datalist>
    <datalist id="provider-list"><template x-for="id in providerIds()" :key="id"><option :value="id + '/'"></option></template></datalist>
  </div>
  </template>
</div>

<script>
const TOKEN_KEY = 'unladen.adminToken';
const HIDDEN = /^<hidden (key-[0-9a-f]{8})>$/;
let counter = 0;

function panel() {
  return {
    token: localStorage.getItem(TOKEN_KEY) || '',
    tokenInput: '',
    signInError: '',
    tab: 'status',
    tabs: [
      { id: 'status', label: 'Status', icon: 'ti-activity' },
      { id: 'providers', label: 'Providers', icon: 'ti-server' },
      { id: 'routes', label: 'Routes', icon: 'ti-route' },
      { id: 'clients', label: 'Client keys', icon: 'ti-key' },
      { id: 'server', label: 'Server', icon: 'ti-settings' },
    ],
    protocols: ['chat', 'responses', 'anthropic', 'gemini'],
    serverFields: [
      { name: 'listen', placeholder: '127.0.0.1:4141', help: 'host:port', restart: true },
      { name: 'strict', kind: 'bool', help: 'Refuse requests a model cannot take exactly' },
      { name: 'keepalive', placeholder: '15s', help: 'Keepalive interval for streams' },
      { name: 'connect_timeout', placeholder: '10s', help: 'Upstream connection timeout', restart: true },
      { name: 'head_timeout', placeholder: '240s', help: 'Wait for the first content before the next key; off: no limit' },
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

    async start() {
      if (this.token) await this.load();
      setInterval(() => { if (this.token && this.tab === 'status') this.refreshStatus(); }, 5000);
    },

    async api(method, path, body) {
      const response = await fetch('/admin/api/' + path, {
        method,
        headers: { 'Authorization': 'Bearer ' + this.token, 'Content-Type': 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      let json = {};
      try { json = await response.json(); } catch (e) {}
      if (response.status === 401) { this.signOut('The admin token was refused.'); }
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

    say(kind, title, text) {
      this.messages.push({ id: ++counter, kind, title, text });
      if (kind === 'success') { const id = counter; setTimeout(() => { this.messages = this.messages.filter(m => m.id !== id); }, 5000); }
    },

    stateClass(state) { return { ready: 'bg-success-lt', cooling: 'bg-warning-lt', disabled: 'bg-danger-lt' }[state]; },
    isHidden(value) { return typeof value === 'string' && HIDDEN.test(value); },
    hiddenName(value) { return value.match(HIDDEN)[1]; },
    isPreset(id) { return this.presets.includes(id); },
    providerIds() {
      const ids = new Set(this.model.providers.map(p => p.id).filter(Boolean));
      for (const p of this.status?.providers || []) if (p.configured) ids.add(p.id);
      return [...ids].sort();
    },
    uid() { return ++counter; },
    newKey() { return { uid: ++counter, name: '', key: '', enabled: true, rest: {} }; },
    addProvider() {
      this.model.providers.push({ uid: ++counter, id: '', preset: '', strategy: '', keys: [this.newKey()], endpoints: [], headers: [], rest: {} });
    },
    addClient() {
      this.model.clients.push({ uid: ++counter, name: '', secret: generateSecret(), routes: '', passMode: 'none', passthrough: '', enabled: true, rest: {} });
    },
    generateSecret,
  };
}

function generateSecret() {
  const bytes = new Uint8Array(24);
  crypto.getRandomValues(bytes);
  return 'sk-unladen-' + Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
}

// The document (the file as JSON) ↔ what the forms edit. Fields the forms
// do not know are carried in `rest` and written back as they were.

function omit(object, keys) {
  const rest = {};
  for (const [k, v] of Object.entries(object || {})) if (!keys.includes(k)) rest[k] = v;
  return rest;
}

function list(value) {
  if (value === undefined || value === null) return [];
  return Array.isArray(value) ? value : [value];
}

function fromDocument(doc) {
  const server = doc.server || {};
  const model = { server: {}, providers: [], routes: [], clients: [] };
  for (const field of ['listen', 'keepalive', 'connect_timeout', 'head_timeout', 'idle_timeout', 'max_request_bytes']) {
    model.server[field] = server[field] === undefined || server[field] === null ? '' : String(server[field]);
  }
  model.server.strict = server.strict === true;
  model.server.adminToken = server.admin?.token ?? '';
  model.server.rest = omit(server, ['listen', 'strict', 'keepalive', 'connect_timeout', 'head_timeout', 'idle_timeout', 'max_request_bytes', 'admin']);
  model.server.adminRest = omit(server.admin, ['token']);

  for (const [id, p] of Object.entries(doc.providers || {})) {
    const provider = p || {};
    model.providers.push({
      uid: ++counter, id,
      preset: provider.preset || '',
      strategy: provider.strategy === 'rotate' ? 'rotate' : '',
      keys: list(provider.keys).map(k => typeof k === 'object'
        ? { uid: ++counter, name: k.name || '', key: k.key ?? '', enabled: k.enabled !== false, rest: omit(k, ['name', 'key', 'enabled']) }
        : { uid: ++counter, name: '', key: String(k), enabled: true, rest: {} }),
      endpoints: Object.entries(provider.endpoints || {}).map(([protocol, url]) => ({ uid: ++counter, protocol, url: String(url) })),
      headers: Object.entries(provider.headers || {}).map(([name, value]) => ({ uid: ++counter, name, value: String(value) })),
      rest: omit(provider, ['preset', 'strategy', 'keys', 'endpoints', 'headers']),
    });
  }

  for (const [name, r] of Object.entries(doc.routes || {})) {
    if (typeof r === 'object' && r !== null) {
      const first = list(r.targets)[0];
      const target = typeof first === 'object' && first !== null ? first.model : first;
      model.routes.push({ uid: ++counter, name, target: target || '', rest: omit(r, ['targets']) });
    } else {
      model.routes.push({ uid: ++counter, name, target: String(r ?? ''), rest: null });
    }
  }

  for (const c of list(doc.client_keys)) {
    const pass = c.passthrough;
    const passList = pass === true || pass === false ? [] : list(pass).map(String);
    model.clients.push({
      uid: ++counter,
      name: c.name || '',
      secret: c.secret ?? '',
      routes: c.routes === undefined ? '' : list(c.routes).join(', '),
      passMode: pass === true || (passList.length === 1 && passList[0] === '*') ? 'all' : passList.length ? 'some' : 'none',
      passthrough: passList.join(', '),
      enabled: c.enabled !== false,
      rest: omit(c, ['name', 'secret', 'routes', 'passthrough', 'enabled']),
    });
  }
  return model;
}

function globs(text) {
  return text.split(',').map(s => s.trim()).filter(Boolean);
}

function scalar(text) {
  const t = String(text).trim();
  return /^[0-9]+$/.test(t) ? Number(t) : t;
}

function toDocument(model, original) {
  const doc = {};
  const order = Object.keys(original || {});
  for (const key of ['server', 'providers', 'routes', 'client_keys']) if (!order.includes(key)) order.push(key);
  const sections = {};

  const server = { ...model.server.rest };
  for (const field of ['listen', 'keepalive', 'connect_timeout', 'head_timeout', 'idle_timeout', 'max_request_bytes']) {
    if (String(model.server[field]).trim() !== '') server[field] = scalar(model.server[field]);
  }
  if (model.server.strict) server.strict = true;
  const admin = { ...model.server.adminRest };
  if (String(model.server.adminToken).trim() !== '') admin.token = model.server.adminToken.trim();
  if (Object.keys(admin).length) server.admin = admin;
  if (Object.keys(server).length) sections.server = server;

  const providers = {};
  for (const p of model.providers) {
    const provider = { ...p.rest };
    if (p.preset) provider.preset = p.preset;
    if (p.endpoints.length) provider.endpoints = Object.fromEntries(p.endpoints.map(e => [e.protocol, e.url.trim()]));
    if (p.headers.length) provider.headers = Object.fromEntries(p.headers.filter(h => h.name.trim()).map(h => [h.name.trim(), h.value]));
    if (p.keys.length) {
      provider.keys = p.keys.map(k => {
        const key = k.key.trim();
        if (!k.name.trim() && k.enabled && !Object.keys(k.rest).length) return key;
        const entry = { ...k.rest };
        if (k.name.trim()) entry.name = k.name.trim();
        entry.key = key;
        if (!k.enabled) entry.enabled = false;
        return entry;
      });
    }
    if (p.strategy) provider.strategy = p.strategy;
    providers[p.id.trim()] = provider;
  }
  if (model.providers.length) sections.providers = providers;

  const routes = {};
  for (const r of model.routes) {
    routes[r.name.trim()] = r.rest ? { ...r.rest, targets: [r.target.trim()] } : r.target.trim();
  }
  if (model.routes.length) sections.routes = routes;

  if (model.clients.length) {
    sections.client_keys = model.clients.map(c => {
      const entry = { name: c.name.trim(), secret: c.secret.trim(), ...c.rest };
      if (c.routes.trim()) entry.routes = globs(c.routes);
      if (c.passMode === 'all') entry.passthrough = true;
      if (c.passMode === 'some' && globs(c.passthrough).length) entry.passthrough = globs(c.passthrough);
      if (!c.enabled) entry.enabled = false;
      return entry;
    });
  }

  for (const key of order) {
    if (key in sections) doc[key] = sections[key];
    else if (!['server', 'providers', 'routes', 'client_keys'].includes(key)) doc[key] = original[key];
  }
  return doc;
}
</script>
</body>
</html>
"""#
}
