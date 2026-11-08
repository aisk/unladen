// The control panel: one page, Tabler for the look and Alpine.js for the
// behaviour, both from a CDN. It talks to `/admin/api/*` with the panel
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
  .mono { font-family: var(--tblr-font-monospace); }
  .table td { vertical-align: middle; }
  textarea.mono { font-size: .8125rem; }
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
          <label class="form-label">Panel token</label>
          <input type="password" class="form-control" x-model="tokenInput" autocomplete="current-password" placeholder="panel.token">
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

          <!-- Overview -->
          <div x-show="tab === 'overview'">
            <div class="text-secondary mb-3">
              Configuration file: <code x-text="path || 'none'"></code>
              <span class="ms-2">Refreshed every 5 seconds.</span>
            </div>
            <div class="card mb-3">
              <div class="card-header"><h3 class="card-title">Accounts</h3></div>
              <table class="table card-table">
                <thead><tr><th>Account</th><th>Provider</th><th>State</th><th></th></tr></thead>
                <tbody>
                  <template x-for="a in status?.accounts || []" :key="a.provider + ' ' + a.name">
                    <tr>
                      <td>
                        <span class="mono" x-text="a.name"></span>
                        <span class="badge bg-secondary-lt ms-1" x-show="a.source === 'environment'">environment</span>
                      </td>
                      <td>
                        <span class="mono" x-text="a.provider"></span>
                        <span class="badge ms-1" x-show="a.pool !== 'order'" x-text="a.pool"></span>
                      </td>
                      <td>
                        <span class="badge" :class="stateClass(a.state)" x-text="a.state"></span>
                        <span class="text-secondary ms-1" x-show="a.cooling_seconds" x-text="a.cooling_seconds + 's'"></span>
                      </td>
                      <td class="text-end">
                        <button class="btn btn-sm" x-show="a.state !== 'ready'" @click="resetKey(a.provider, a.name)">Reset</button>
                      </td>
                    </tr>
                  </template>
                  <tr x-show="!(status?.accounts || []).length"><td colspan="4" class="text-secondary">No account: add one on the Accounts page.</td></tr>
                  <template x-for="c in status?.cooling || []" :key="c.provider + c.what">
                    <tr><td colspan="4" class="text-warning">
                      <span x-text="c.provider + ': ' + c.what + ', retried in ' + c.cooling_seconds + 's'"></span>
                    </td></tr>
                  </template>
                </tbody>
              </table>
            </div>
            <div class="row row-cards">
              <div class="col-md-6">
                <div class="card">
                  <div class="card-header"><h3 class="card-title">Models in force</h3></div>
                  <table class="table card-table">
                    <tbody>
                      <template x-for="r in status?.models || []" :key="r.name">
                        <tr><td class="mono" x-text="r.name"></td><td class="mono" x-text="r.targets.join(', ')"></td></tr>
                      </template>
                      <tr x-show="!(status?.models || []).length"><td class="text-secondary">No model: clients name provider/model.</td></tr>
                    </tbody>
                  </table>
                </div>
              </div>
              <div class="col-md-6">
                <div class="card">
                  <div class="card-header"><h3 class="card-title">Clients in force</h3></div>
                  <table class="table card-table">
                    <tbody>
                      <template x-for="c in status?.clients || []" :key="c.name">
                        <tr><td x-text="c.name"></td><td class="text-secondary" x-text="c.disabled ? 'disabled' : clientSummary(c.models)"></td></tr>
                      </template>
                      <tr x-show="!(status?.clients || []).length"><td class="text-warning">None: any client may use the gateway.</td></tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          </div>

          <!-- Activity -->
          <div x-show="tab === 'activity'">
            <div class="text-secondary mb-3">Requests as they happen, refreshed every 2 seconds. Sessions of the last 7 days.</div>
            <div class="card mb-3">
              <div class="card-header"><h3 class="card-title">In flight</h3></div>
              <table class="table card-table table-sm">
                <thead><tr><th>Started</th><th>Client</th><th>Model</th><th>Account</th><th>Phase</th><th class="text-end">Elapsed</th></tr></thead>
                <tbody>
                  <template x-for="r in activity?.in_flight || []" :key="r.id">
                    <tr>
                      <td x-text="clock(r.t)"></td>
                      <td><span x-text="r.client"></span> <span class="text-secondary" x-show="r.client_key" x-text="'(' + r.client_key + ')'"></span></td>
                      <td class="mono" x-text="r.model"></td>
                      <td class="mono" x-text="accountOf(r)"></td>
                      <td><span class="badge" :class="r.phase === 'streaming' ? 'bg-green-lt' : 'bg-yellow-lt'" x-text="r.phase"></span></td>
                      <td class="text-end" x-text="duration(activity.now - r.t)"></td>
                    </tr>
                  </template>
                  <tr x-show="!(activity?.in_flight || []).length"><td colspan="6" class="text-secondary">Nothing in flight.</td></tr>
                </tbody>
              </table>
            </div>
            <div class="card mb-3">
              <div class="card-header"><h3 class="card-title">Sessions</h3></div>
              <div class="table-responsive">
              <table class="table card-table table-sm table-hover">
                <thead><tr><th>Last active</th><th>Client</th><th>Session</th><th>Model</th><th class="text-end">Requests</th><th class="text-end">Input</th><th class="text-end">Output</th><th class="text-end">Cache hit</th><th>Accounts</th></tr></thead>
                <tbody>
                  <template x-for="s in activity?.sessions || []" :key="s.id">
                    <tr style="cursor: pointer" @click="openSession(s)" :class="session?.id === s.id && 'table-active'">
                      <td x-text="ago(s.last)"></td>
                      <td><span x-text="s.client"></span> <span class="text-secondary" x-show="s.client_key" x-text="'(' + s.client_key + ')'"></span></td>
                      <td class="mono text-secondary" :title="s.id" x-text="short(s.id)"></td>
                      <td class="mono" x-text="s.last_model"></td>
                      <td class="text-end"><span x-text="s.requests"></span><span class="text-danger" x-show="s.failures" x-text="' (' + s.failures + ' failed)'"></span></td>
                      <td class="text-end" x-text="count(s.tokens.input)"></td>
                      <td class="text-end" x-text="count(s.tokens.output)"></td>
                      <td class="text-end" x-text="cacheShare(s.tokens)"></td>
                      <td class="mono"><span x-text="s.accounts.join(', ')"></span> <span class="badge bg-orange-lt" x-show="s.switches" x-text="s.switches + ' switches'"></span></td>
                    </tr>
                  </template>
                  <tr x-show="!(activity?.sessions || []).length"><td colspan="9" class="text-secondary">No session yet.</td></tr>
                </tbody>
              </table>
              </div>
            </div>
            <div class="card mb-3">
              <div class="card-header">
                <h3 class="card-title" x-text="session ? 'Requests of session ' + short(session.id) : 'Recent requests'"></h3>
                <div class="card-actions" x-show="session"><button class="btn btn-sm" @click="session = null; sessionRequests = []">Show all recent</button></div>
              </div>
              <div class="table-responsive">
              <table class="table card-table table-sm">
                <thead><tr><th>Time</th><th>Client</th><th>Model</th><th>Served by</th><th>Status</th><th class="text-end">First content</th><th class="text-end">Total</th><th class="text-end">Input</th><th class="text-end">Output</th><th class="text-end">Cached</th></tr></thead>
                <tbody>
                  <template x-for="r in shownRequests()" :key="r.id">
                    <tr>
                      <td>
                        <a href="#" class="text-reset" @click.prevent="expanded[r.id] = !expanded[r.id]" x-text="clock(r.t)"></a>
                        <div x-show="expanded[r.id]" class="small text-secondary mt-1">
                          <div x-show="r.session" class="mono" x-text="'session ' + r.session + (r.subagent ? ', subagent ' + r.subagent : '')"></div>
                          <div x-text="r.protocol + (r.stream ? ', streamed' : '')"></div>
                          <template x-for="a in r.attempt_list || []">
                            <div class="mono" x-text="a.provider + '/' + a.account + ' ' + a.model + ': ' + a.outcome + ' (' + duration(a.ms) + ')'"></div>
                          </template>
                          <div x-show="r.note" class="text-danger" x-text="r.note"></div>
                        </div>
                      </td>
                      <td x-text="r.client"></td>
                      <td class="mono" x-text="r.model"></td>
                      <td class="mono">
                        <span x-text="accountOf(r)"></span>
                        <span class="badge bg-orange-lt" x-show="r.attempts > 1" x-text="r.attempts + ' tries'"></span>
                      </td>
                      <td><span class="badge" :class="r.failed || r.status >= 400 ? 'bg-red-lt' : 'bg-green-lt'" x-text="r.phase && r.phase !== 'done' ? r.phase : r.status"></span></td>
                      <td class="text-end" x-text="r.first_content_ms == null ? '' : duration(r.first_content_ms)"></td>
                      <td class="text-end" x-text="r.ms == null ? '' : duration(r.ms)"></td>
                      <td class="text-end" x-text="r.tokens ? count(r.tokens.input) : ''"></td>
                      <td class="text-end" x-text="r.tokens ? count(r.tokens.output) : ''"></td>
                      <td class="text-end" x-text="r.tokens ? count(r.tokens.cache_read) : ''"></td>
                    </tr>
                  </template>
                  <tr x-show="!shownRequests().length"><td colspan="10" class="text-secondary">No request recorded since the gateway started.</td></tr>
                </tbody>
              </table>
              </div>
            </div>
          </div>

          <!-- Usage -->
          <div x-show="tab === 'usage'">
            <div class="d-flex mb-3 align-items-center">
              <div class="text-secondary me-auto">Tokens as the upstreams reported them, by local day.</div>
              <div class="btn-group">
                <template x-for="d in [1, 7, 30]">
                  <button class="btn" :class="usageDays === d && 'active'" @click="usageDays = d; refreshUsage()" x-text="d === 1 ? 'Today' : d + ' days'"></button>
                </template>
              </div>
            </div>
            <div class="row row-cards mb-3" x-show="usage">
              <template x-for="tile in usageTiles()">
                <div class="col-6 col-md-3">
                  <div class="card card-sm"><div class="card-body">
                    <div class="subheader" x-text="tile.label"></div>
                    <div class="h2 mb-0" x-text="tile.value"></div>
                  </div></div>
                </div>
              </template>
            </div>
            <template x-for="g in [['accounts', 'By account'], ['clients', 'By client'], ['models', 'By model']]">
              <div class="card mb-3">
                <div class="card-header"><h3 class="card-title" x-text="g[1]"></h3></div>
                <div class="table-responsive">
                <table class="table card-table table-sm">
                  <thead><tr><th>Name</th><th class="text-end">Requests</th><th class="text-end">Failed</th><th class="text-end">Input</th><th class="text-end">Output</th><th class="text-end">Cache read</th><th class="text-end">Cache write</th><th class="text-end">Cache hit</th></tr></thead>
                  <tbody>
                    <template x-for="row in usage?.[g[0]] || []" :key="row.name">
                      <tr>
                        <td class="mono" x-text="row.name"></td>
                        <td class="text-end" x-text="row.requests"></td>
                        <td class="text-end" :class="row.failures && 'text-danger'" x-text="row.failures"></td>
                        <td class="text-end" x-text="count(row.tokens.input)"></td>
                        <td class="text-end" x-text="count(row.tokens.output)"></td>
                        <td class="text-end" x-text="count(row.tokens.cache_read)"></td>
                        <td class="text-end" x-text="count(row.tokens.cache_write)"></td>
                        <td class="text-end" x-text="cacheShare(row.tokens)"></td>
                      </tr>
                    </template>
                    <tr x-show="!(usage?.[g[0]] || []).length"><td colspan="8" class="text-secondary">No request in this period.</td></tr>
                  </tbody>
                </table>
                </div>
              </div>
            </template>
          </div>

          <!-- Accounts -->
          <div x-show="tab === 'accounts'">
            <div class="d-flex mb-3 align-items-start">
              <div class="text-secondary me-auto">
                The upstream accounts the gateway pays with. Accounts of one provider form a pool, tried in this order:
                the next is used only when the one before fails.
              </div>
              <button class="btn" @click="startAdding()" x-show="!adding"><i class="ti ti-plus me-1"></i>Add account</button>
            </div>

            <template x-if="adding">
            <div class="card mb-3">
              <div class="card-header"><h3 class="card-title">Add an account</h3></div>
              <div class="card-body">
                <div class="row g-3">
                  <div class="col-md-4">
                    <label class="form-label">Provider</label>
                    <select class="form-select" x-model="draft.provider" @change="draftChanged()">
                      <template x-for="id in providerIds()" :key="id"><option :value="id" x-text="id" :selected="draft.provider === id"></option></template>
                      <option value="">another address…</option>
                    </select>
                  </div>
                  <div class="col-md-4">
                    <label class="form-label">Name</label>
                    <input class="form-control mono" x-model="draft.name" @input="draftChanged()" placeholder="work">
                    <div class="form-hint">Shown in logs and the overview.</div>
                  </div>
                  <div class="col-md-4">
                    <label class="form-label">Key</label>
                    <input class="form-control mono" x-model="draft.key" placeholder="sk-… or ${ENV_VAR}" autocomplete="off">
                    <div class="form-hint" x-show="!draft.provider">May stay empty for an address without authentication.</div>
                  </div>
                  <template x-if="!draft.provider">
                    <div class="col-12">
                      <div class="row g-3">
                        <div class="col-md-4">
                          <label class="form-label">Speaks like</label>
                          <select class="form-select" x-model="draft.preset">
                            <option value="">nothing built in</option>
                            <template x-for="id in presets" :key="id"><option :value="id" x-text="id"></option></template>
                          </select>
                        </div>
                        <div class="col-md-8">
                          <label class="form-label">Endpoint</label>
                          <div class="input-group">
                            <select class="form-select" style="max-width: 9rem" x-model="draft.protocol">
                              <template x-for="proto in protocols" :key="proto"><option :value="proto" x-text="proto" :selected="draft.protocol === proto"></option></template>
                            </select>
                            <input class="form-control mono" x-model="draft.url" placeholder="https://relay.example.com/v1">
                          </div>
                        </div>
                      </div>
                    </div>
                  </template>
                  <div class="col-12" x-show="draft.suggestions.length">
                    <label class="form-label">Models</label>
                    <template x-for="s in draft.suggestions" :key="s.name">
                      <label class="form-check">
                        <input class="form-check-input" type="checkbox" x-model="s.chosen">
                        <span class="form-check-label">
                          <span x-text="s.current ? 'Point' : 'Add'"></span>
                          <code x-text="s.name"></code> →
                          <code x-text="s.target"></code>
                          <span class="text-secondary" x-show="s.current" x-text="'(now ' + s.current + ')'"></span>
                        </span>
                      </label>
                    </template>
                  </div>
                </div>
              </div>
              <div class="card-footer d-flex gap-2">
                <button class="btn btn-primary" @click="addAccount()" :disabled="!!draftProblem()">Add</button>
                <button class="btn btn-ghost-secondary" @click="adding = false">Cancel</button>
                <span class="text-secondary align-self-center" x-text="draftProblem()"></span>
              </div>
            </div>
            </template>

            <div class="card">
              <table class="table card-table">
                <thead><tr><th style="width: 13rem">Name</th><th style="width: 11rem">Provider</th><th>Key</th><th style="width: 5rem">Enabled</th><th style="width: 8rem"></th></tr></thead>
                <tbody>
                  <template x-for="(a, ai) in model.accounts" :key="a.uid">
                    <tr>
                      <td><input class="form-control form-control-sm mono" x-model="a.name"></td>
                      <td>
                        <span class="mono" x-text="accountProvider(a)"></span>
                        <span class="badge bg-secondary-lt ms-1" x-show="a.custom">own address</span>
                      </td>
                      <td>
                        <template x-if="isHidden(a.key)">
                          <div class="d-flex align-items-center gap-2">
                            <span class="mono text-secondary" x-text="'•••• ' + hiddenName(a.key)"></span>
                            <button class="btn btn-sm" @click="a.key = ''">Replace</button>
                          </div>
                        </template>
                        <template x-if="!isHidden(a.key)">
                          <input class="form-control form-control-sm mono" x-model="a.key" :placeholder="a.custom ? 'none' : 'sk-… or ${ENV_VAR}'" autocomplete="off">
                        </template>
                        <template x-if="a.custom">
                          <div class="mt-2">
                            <template x-for="(e, ei) in a.endpoints" :key="e.uid">
                              <div class="input-group input-group-sm mb-1">
                                <select class="form-select" style="max-width: 8rem" x-model="e.protocol">
                                  <template x-for="proto in protocols" :key="proto"><option :value="proto" x-text="proto" :selected="e.protocol === proto"></option></template>
                                </select>
                                <input class="form-control mono" x-model="e.url">
                                <button class="btn btn-icon" @click="a.endpoints.splice(ei, 1)"><i class="ti ti-x"></i></button>
                              </div>
                            </template>
                            <template x-for="(h, hi) in a.headers" :key="h.uid">
                              <div class="input-group input-group-sm mb-1">
                                <input class="form-control mono" style="max-width: 12rem" x-model="h.name" placeholder="Header-Name">
                                <input class="form-control mono" x-model="h.value" placeholder="value or ${ENV_VAR}">
                                <button class="btn btn-icon" @click="a.headers.splice(hi, 1)"><i class="ti ti-x"></i></button>
                              </div>
                            </template>
                            <button class="btn btn-sm" @click="a.endpoints.push({uid: uid(), protocol: 'chat', url: ''})"><i class="ti ti-plus me-1"></i>Endpoint</button>
                            <button class="btn btn-sm" @click="a.headers.push({uid: uid(), name: '', value: ''})"><i class="ti ti-plus me-1"></i>Header</button>
                            <span class="text-secondary ms-2" x-show="a.preset" x-text="'speaks like ' + a.preset"></span>
                          </div>
                        </template>
                      </td>
                      <td><input type="checkbox" class="form-check-input" x-model="a.enabled"></td>
                      <td class="text-end text-nowrap">
                        <button class="btn btn-sm btn-ghost-secondary btn-icon" title="Earlier in the pool" @click="move(model.accounts, ai, -1)" :disabled="ai === 0"><i class="ti ti-arrow-up"></i></button>
                        <button class="btn btn-sm btn-ghost-secondary btn-icon" title="Later in the pool" @click="move(model.accounts, ai, 1)" :disabled="ai === model.accounts.length - 1"><i class="ti ti-arrow-down"></i></button>
                        <button class="btn btn-sm btn-ghost-danger btn-icon" title="Remove" @click="model.accounts.splice(ai, 1)"><i class="ti ti-trash"></i></button>
                      </td>
                    </tr>
                  </template>
                  <tr x-show="!model.accounts.length"><td colspan="5" class="text-secondary">No account in the file: providers use keys from the environment.</td></tr>
                </tbody>
              </table>
            </div>
          </div>

          <!-- Models -->
          <div x-show="tab === 'models'">
            <div class="card">
              <div class="card-header">
                <h3 class="card-title">Models</h3>
                <div class="card-actions"><button class="btn" @click="model.models.push({uid: uid(), name: '', target: '', raw: undefined})"><i class="ti ti-plus me-1"></i>Add model</button></div>
              </div>
              <div class="card-body text-secondary">
                The names clients may ask for, and who answers them. A target is a provider (the name asked for is passed on),
                <code>provider/model</code>, or <code>@name</code> for another entry. Names may use <code>*</code>;
                <code>*</code> alone answers every other name.
              </div>
              <table class="table card-table">
                <thead><tr><th style="width: 35%">Name</th><th>Target</th><th style="width: 3rem"></th></tr></thead>
                <tbody>
                  <template x-for="(r, ri) in model.models" :key="r.uid">
                    <tr>
                      <td><input class="form-control mono" x-model="r.name" placeholder="claude-*, fast, *"></td>
                      <td>
                        <template x-if="r.raw === undefined">
                          <input class="form-control mono" x-model="r.target" placeholder="anthropic, deepseek/deepseek-chat, @fast" list="target-list">
                        </template>
                        <template x-if="r.raw !== undefined">
                          <code class="text-secondary" x-text="JSON.stringify(r.raw)" title="Edit it under Settings, Edit as JSON"></code>
                        </template>
                      </td>
                      <td><button class="btn btn-ghost-danger btn-icon" @click="model.models.splice(ri, 1)"><i class="ti ti-x"></i></button></td>
                    </tr>
                  </template>
                  <tr x-show="!model.models.length"><td colspan="3" class="text-secondary">No model: clients name provider/model directly.</td></tr>
                </tbody>
              </table>
            </div>
          </div>

          <!-- Clients -->
          <div x-show="tab === 'clients'">
            <div class="d-flex mb-3 align-items-start">
              <div class="text-secondary me-auto">
                The keys clients present (Bearer, <code>x-api-key</code> or <code>x-goog-api-key</code>). With none, any client may use the gateway.
              </div>
              <button class="btn" @click="addClient()"><i class="ti ti-plus me-1"></i>Add client</button>
            </div>
            <template x-for="(c, ci) in model.clients" :key="c.uid">
              <div class="card mb-3">
                <div class="card-header">
                  <input class="form-control form-control-flush h3 mb-0" style="max-width: 16rem" x-model="c.name" placeholder="name">
                  <div class="card-actions d-flex gap-3 align-items-center">
                    <label class="form-check form-switch mb-0"><input class="form-check-input" type="checkbox" x-model="c.enabled"><span class="form-check-label">Enabled</span></label>
                    <button class="btn btn-ghost-danger btn-icon" title="Remove" @click="model.clients.splice(ci, 1)"><i class="ti ti-trash"></i></button>
                  </div>
                </div>
                <div class="card-body">
                  <label class="form-label">Key</label>
                  <template x-if="isHidden(c.key)">
                    <div class="d-flex align-items-center gap-2">
                      <span class="mono text-secondary" x-text="'•••• ' + hiddenName(c.key)"></span>
                      <button class="btn btn-sm" @click="c.key = ''">Replace</button>
                    </div>
                  </template>
                  <template x-if="!isHidden(c.key)">
                    <div class="input-group">
                      <input class="form-control mono" x-model="c.key" placeholder="key or ${ENV_VAR}" autocomplete="off">
                      <button class="btn btn-icon" title="Generate" @click="c.key = generateSecret()"><i class="ti ti-dice-5"></i></button>
                      <button class="btn btn-icon" title="Copy" @click="navigator.clipboard.writeText(c.key)"><i class="ti ti-copy"></i></button>
                    </div>
                  </template>
                  <label class="form-label mt-3">May use</label>
                  <div class="btn-group mb-2">
                    <button class="btn btn-sm" :class="c.access === 'menu' && 'btn-primary'" @click="c.access = 'menu'">Every model</button>
                    <button class="btn btn-sm" :class="c.access === 'some' && 'btn-primary'" @click="c.access = 'some'">Some models</button>
                    <button class="btn btn-sm" :class="c.access === 'all' && 'btn-primary'" @click="c.access = 'all'">Everything, provider/model too</button>
                  </div>
                  <div x-show="c.access === 'some'">
                    <div class="d-flex flex-wrap gap-3 mb-2">
                      <template x-for="name in menuNames()" :key="name">
                        <label class="form-check mb-0">
                          <input class="form-check-input" type="checkbox" :checked="c.chosen.includes(name)" @change="toggle(c.chosen, name)">
                          <span class="form-check-label mono" x-text="name"></span>
                        </label>
                      </template>
                    </div>
                    <input class="form-control form-control-sm mono" x-model="c.extra" placeholder="also, comma-separated: deepseek/*, openai/gpt-4o">
                  </div>
                </div>
              </div>
            </template>
            <div class="empty" x-show="!model.clients.length">
              <p class="empty-title">No client key</p>
              <p class="empty-subtitle text-secondary">Any client that reaches the gateway may use it.</p>
            </div>
          </div>

          <!-- Settings -->
          <div x-show="tab === 'settings'">
            <div class="card mb-3">
              <div class="card-body">
                <div class="row g-3">
                  <div class="col-md-6">
                    <label class="form-label"><span class="mono">listen</span><span class="badge bg-secondary-lt ms-1">restart</span></label>
                    <input class="form-control mono" x-model="model.listen" placeholder="127.0.0.1:4141">
                    <div class="form-hint">host:port</div>
                  </div>
                  <div class="col-md-6">
                    <label class="form-label"><span class="mono">panel.token</span></label>
                    <template x-if="isHidden(model.panelToken)">
                      <div class="d-flex align-items-center gap-2">
                        <span class="mono text-secondary" x-text="'•••• ' + hiddenName(model.panelToken)"></span>
                        <button class="btn btn-sm" @click="model.panelToken = ''">Replace</button>
                      </div>
                    </template>
                    <template x-if="!isHidden(model.panelToken)">
                      <input class="form-control mono" x-model="model.panelToken" placeholder="${UNLADEN_ADMIN_TOKEN}" autocomplete="off">
                    </template>
                    <div class="form-hint">Opens this panel; at least 16 characters. After a change, sign in again.</div>
                  </div>
                </div>
                <h4 class="mt-4">Advanced</h4>
                <div class="row g-3">
                  <template x-for="f in advancedFields" :key="f.name">
                    <div class="col-md-6">
                      <label class="form-label">
                        <span class="mono" x-text="f.name"></span>
                        <span class="badge bg-secondary-lt ms-1" x-show="f.restart">restart</span>
                      </label>
                      <template x-if="f.kind === 'bool'">
                        <label class="form-check form-switch">
                          <input class="form-check-input" type="checkbox" x-model="model.advanced[f.name]">
                          <span class="form-check-label" x-text="f.help"></span>
                        </label>
                      </template>
                      <template x-if="f.kind !== 'bool'">
                        <div>
                          <input class="form-control mono" x-model="model.advanced[f.name]" :placeholder="f.placeholder">
                          <div class="form-hint" x-text="f.help"></div>
                        </div>
                      </template>
                    </div>
                  </template>
                  <div class="col-md-6">
                    <label class="form-label"><span class="mono">pools</span></label>
                    <template x-for="id in poolProviders()" :key="id">
                      <div class="input-group input-group-sm mb-1">
                        <span class="input-group-text mono" style="min-width: 9rem" x-text="id"></span>
                        <select class="form-select" @change="model.pools[id] = $event.target.value">
                          <option value="order" :selected="(model.pools[id] || 'order') === 'order'">order</option>
                          <option value="rotate" :selected="model.pools[id] === 'rotate'">rotate</option>
                        </select>
                      </div>
                    </template>
                    <div class="form-hint">
                      How a provider's accounts take turns. <code>order</code>: the next only when one fails.
                      <code>rotate</code>: each request starts at the next account; it spreads load but breaks prompt caches.
                    </div>
                  </div>
                </div>
              </div>
            </div>
            <div class="card">
              <div class="card-header">
                <h3 class="card-title">Edit as JSON</h3>
                <div class="card-actions d-flex gap-2">
                  <button class="btn btn-sm" @click="showJSON()">Show the current form</button>
                  <button class="btn btn-sm btn-primary" @click="applyJSON()" :disabled="!jsonText">Apply to the form</button>
                </div>
              </div>
              <div class="card-body">
                <div class="text-secondary mb-2">
                  The whole file as JSON, keys hidden as <code>&lt;hidden key-…&gt;</code> (kept as they are when saved).
                  Applying fills the pages above; Save writes the file. Comments in the file are not kept.
                </div>
                <textarea class="form-control mono" rows="18" x-model="jsonText" spellcheck="false"></textarea>
                <div class="text-danger mt-2" x-text="jsonError"></div>
              </div>
            </div>
          </div>

        </div>
      </div>
    </div>

    <datalist id="target-list"><template x-for="t in targetChoices()" :key="t"><option :value="t"></option></template></datalist>
  </div>
  </template>
</div>

<script>
const TOKEN_KEY = 'unladen.adminToken';
const HIDDEN = /^<hidden (key-[0-9a-f]{8})>$/;
const SECTIONS = ['listen', 'panel', 'accounts', 'models', 'clients', 'advanced'];
const ADVANCED = ['strict', 'keepalive', 'connect_timeout', 'head_timeout', 'idle_timeout', 'max_request_bytes'];
// The names a provider's own models go by, offered as models when an
// account of it is added.
const FAMILIES = {
  anthropic: ['claude-*'], openai: ['gpt-*', 'o3*', 'o4*'], gemini: ['gemini-*'], deepseek: ['deepseek-*'],
  xai: ['grok-*'], moonshot: ['kimi-*'], mistral: ['mistral-*', 'codestral-*'],
};
let counter = 0;

function panel() {
  return {
    token: localStorage.getItem(TOKEN_KEY) || '',
    tokenInput: '',
    signInError: '',
    tab: 'overview',
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
    jsonText: '',
    jsonError: '',
    activity: null,
    session: null,
    sessionRequests: [],
    expanded: {},
    usage: null,
    usageDays: 1,

    async start() {
      if (this.token) await this.load();
      setInterval(() => { if (this.token && this.tab === 'overview') this.refreshStatus(); }, 5000);
      setInterval(() => { if (this.token && this.tab === 'activity') this.refreshActivity(); }, 2000);
      setInterval(() => { if (this.token && this.tab === 'usage') this.refreshUsage(); }, 10000);
      this.$watch('tab', tab => {
        if (tab === 'activity') this.refreshActivity();
        if (tab === 'usage') this.refreshUsage();
      });
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
      if (d.provider && !d.key.trim()) return 'Enter the key.';
      if (!d.provider && !/^https?:\/\//.test(d.url.trim())) return 'Enter the endpoint address (http:// or https://).';
      return '';
    },
    addAccount() {
      const d = this.draft, name = d.name.trim();
      const account = { uid: ++counter, name, provider: '', key: d.key.trim(), enabled: true, custom: false, preset: '', endpoints: [], headers: [], rest: {} };
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
</script>
</body>
</html>
"""#
}
