import WebKit

enum WebEngine {

    /// Shared across every WKWebView instance in the app so navigations reuse the
    /// same network/render process where possible, and so cookies/session data
    /// stay consistent between the main browser and any popup windows it opens.
    static let processPool = WKProcessPool()

    /// Builds a fresh configuration wired up with the shared process pool and the
    /// Catppuccin theming script. Callers that need to host a system-provided
    /// popup configuration should use that configuration directly instead (WebKit
    /// requires it), calling `installTheming(on:)` on it separately.
    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        installTheming(on: config)
        return config
    }

    /// Injects the Catppuccin Mocha theme into every frame, as early as possible,
    /// so pages don't flash their original colors before it applies.
    static func installTheming(on config: WKWebViewConfiguration) {
        let script = WKUserScript(
            source: catppuccinScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(script)
    }

    /// Best-effort universal dark theme, Catppuccin **Mocha** (the dark flavor —
    /// https://catppuccin.com/palette). This uses the standard "force dark mode"
    /// filter technique: `invert(1) hue-rotate(180deg)` applied against a *white*
    /// pre-invert canvas, which is what reliably makes light pages dark (a white
    /// background inverts to near-black; light text inverts to light-on-dark
    /// automatically). Media elements are filtered back to their normal
    /// appearance so photos/video don't render as negatives.
    ///
    /// (An earlier version of this used a light pre-invert background color,
    /// which produced washed-out, Latte-like — i.e. light — results instead of
    /// Mocha's dark palette. This version is deliberately based on a white
    /// canvas so the output is reliably dark.)
    ///
    /// This can't hit every site's exact Catppuccin hex values — that needs a
    /// per-site stylesheet, the way Catppuccin's own userstyles project does —
    /// but it gives a consistent, comfortably dark look everywhere, and the
    /// official `--ctp-*` custom properties are exposed on `:root` for sites/
    /// styles that already key off them.
    private static let catppuccinScript = """
    (function () {
      const css = `
        :root {
          color-scheme: dark;
          --ctp-rosewater:#f5e0dc; --ctp-flamingo:#f2cdcd; --ctp-pink:#f5c2e7;
          --ctp-mauve:#cba6f7; --ctp-red:#f38ba8; --ctp-maroon:#eba0ac;
          --ctp-peach:#fab387; --ctp-yellow:#f9e2af; --ctp-green:#a6e3a1;
          --ctp-teal:#94e2d5; --ctp-sky:#89dceb; --ctp-sapphire:#74c7ec;
          --ctp-blue:#89b4fa; --ctp-lavender:#b4befe; --ctp-text:#cdd6f4;
          --ctp-subtext1:#bac2de; --ctp-subtext0:#a6adc8; --ctp-overlay2:#9399b2;
          --ctp-overlay1:#7f849c; --ctp-overlay0:#6c7086; --ctp-surface2:#585b70;
          --ctp-surface1:#45475a; --ctp-surface0:#313244; --ctp-base:#1e1e2e;
          --ctp-mantle:#181825; --ctp-crust:#11111b;
        }
        html {
          filter: invert(1) hue-rotate(180deg) !important;
          background: #ffffff !important;
        }
        img, picture, video, canvas, svg, iframe, embed, object,
        [style*="background-image"] {
          filter: invert(1) hue-rotate(180deg) !important;
        }
      `;
      function inject() {
        if (document.getElementById("undirect-catppuccin")) return;
        const style = document.createElement("style");
        style.id = "undirect-catppuccin";
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
