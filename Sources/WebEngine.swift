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

    /// Best-effort universal dark theme in the Catppuccin Mocha palette
    /// (https://catppuccin.com/palette). Two layers:
    /// 1. Exposes the official `--ctp-*` custom properties on `:root` for the
    ///    (growing) set of sites/userstyles that already key off them.
    /// 2. A CSS `filter`-based recolor, the same technique general "force dark
    ///    mode" tools use, tuned toward Catppuccin's hue, with media elements
    ///    (images/video/canvas) re-inverted so photos don't look like negatives.
    /// This can't perfectly retheme every site's exact hex values — that would
    /// need a per-site stylesheet the way Catppuccin's own userstyles project
    /// does — but it gives a consistent, comfortable dark palette everywhere.
    private static let catppuccinScript = """
    (function () {
      const css = `
        :root, ::backdrop {
          --ctp-rosewater:#f5e0dc; --ctp-flamingo:#f2cdcd; --ctp-pink:#f5c2e7;
          --ctp-mauve:#cba6f7; --ctp-red:#f38ba8; --ctp-maroon:#eba0ac;
          --ctp-peach:#fab387; --ctp-yellow:#f9e2af; --ctp-green:#a6e3a1;
          --ctp-teal:#94e2d5; --ctp-sky:#89dceb; --ctp-sapphire:#74c7ec;
          --ctp-blue:#89b4fa; --ctp-lavender:#b4befe; --ctp-text:#cdd6f4;
          --ctp-subtext1:#bac2de; --ctp-subtext0:#a6adc8; --ctp-overlay2:#9399b2;
          --ctp-overlay1:#7f849c; --ctp-overlay0:#6c7086; --ctp-surface2:#585b70;
          --ctp-surface1:#45475a; --ctp-surface0:#313244; --ctp-base:#1e1e2e;
          --ctp-mantle:#181825; --ctp-crust:#11111b;
          color-scheme: dark;
        }
        html {
          filter: invert(1) hue-rotate(180deg) brightness(0.94) contrast(0.92) !important;
          background: #f5e0dc !important;
        }
        img, picture, video, iframe, canvas, svg, [style*="background-image"],
        embed, object {
          filter: invert(1) hue-rotate(180deg) !important;
        }
        ::selection { background: var(--ctp-mauve); color: var(--ctp-base); }
        ::-webkit-scrollbar { background: var(--ctp-base); }
        ::-webkit-scrollbar-thumb { background: var(--ctp-surface2); border-radius: 6px; }
      `;
      function inject() {
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
