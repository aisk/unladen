// The control panel: one page, Tabler for the look and Alpine.js for the
// behaviour, both from a CDN. It talks to `/admin/api/*` with the panel
// token, which it keeps in the browser's localStorage.
//
// The page is Panel/panel.html with Panel/panel.js inlined; the EmbedPanel
// plugin compiles it in as `AdminPage.html`.

enum AdminPage {
    /// What the page may load: its own inline script and styles, Tabler,
    /// its icon font, Alpine.js and the providers' icons from jsDelivr,
    /// and `data:` images (its favicon, Tabler's form controls). Alpine's
    /// standard build evaluates its attributes as code, hence
    /// `'unsafe-eval'`. It talks to the gateway alone, is framed by no
    /// page, and submits no form.
    static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://cdn.jsdelivr.net",
        "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net",
        "font-src 'self' https://cdn.jsdelivr.net data:",
        "img-src 'self' https://cdn.jsdelivr.net data:",
        "connect-src 'self'",
        "frame-ancestors 'none'",
        "base-uri 'none'",
        "form-action 'none'",
    ].joined(separator: "; ")
}
