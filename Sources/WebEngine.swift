import WebKit

enum WebEngine {

    /// Shared across every WKWebView instance in the app so navigations reuse the
    /// same network/render process where possible, and so cookies/session data
    /// stay consistent between the main browser and any popup windows it opens.
    static let processPool = WKProcessPool()

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        installTheming(on: config)
        return config
    }

    static func installTheming(on config: WKWebViewConfiguration) {
        let script = WKUserScript(
            source: darkThemeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(script)
    }

    /// A plain, low-risk dark theme.
    ///
    /// An earlier version used the common "force dark mode" hack — a CSS
    /// `filter: invert(1) hue-rotate(180deg)` on the whole `<html>` element —
    /// to approximate a specific palette. That forces the entire page into one
    /// pixel-inverted composited layer, which is a known source of WKWebView
    /// content-process instability on complex pages, and a very plausible
    /// contributor to crashes on interaction. This version does none of that:
    /// no filter, no attempt at a specific named palette — just cheap,
    /// low-risk dark colors for the parts of the page that don't already set
    /// their own, plus `color-scheme: dark` so well-behaved modern sites apply
    /// their own proper dark styling automatically.
    ///
    /// As before, this can't force every site's own components to a specific
    /// dark look — a site that explicitly styles its own elements keeps doing
    /// so — but it won't fight the renderer to do it.
    private static let darkThemeScript = """
    (function () {
      const css = `
        :root { color-scheme: dark; }
        html { background-color: #16161e !important; }
        body { background-color: transparent; color: #d8dee9; }
      `;
      function inject() {
        if (document.getElementById("undirect-dark-theme")) return;
        const style = document.createElement("style");
        style.id = "undirect-dark-theme";
        style.textContent = css;
        (document.head || document.documentElement).appendChild(style);
      }
      if (document.head) {
        inject();
      } else {
        document.addEventListener("DOMContentLoaded", inject, { once: true });
      }
    })();
    """
}
