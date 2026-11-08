// The control panel: one page, Tabler for the look and Alpine.js for the
// behaviour, both from a CDN. It talks to `/admin/api/*` with the panel
// token, which it keeps in the browser's localStorage.
//
// The page is Panel/panel.html with Panel/panel.js inlined; the EmbedPanel
// plugin compiles it in as `AdminPage.html`.

enum AdminPage {}
