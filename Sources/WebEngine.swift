import WebKit

enum WebEngine {

    static func makeConfiguration(tor: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = tor ? TorManager.shared.dataStore : .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsInlineMediaPlayback = true
        // No autoplaying video/audio: faster pages, less data.
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        return config
    }

    /// Installs every Undirect script on a (non-popup) tab's content controller.
    /// Our scripts run in an isolated content world so pages can't see or tamper with them.
    static func installScripts(on controller: WKUserContentController, messageName: String, tor: Bool) {
        let world = WKContentWorld.defaultClient
        func add(_ source: String, mainFrameOnly: Bool, world: WKContentWorld) {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: mainFrameOnly, in: world))
        }
        add(darkThemeScript, mainFrameOnly: false, world: world)
        add(agentScript(messageName: messageName), mainFrameOnly: false, world: world)
        add(pickerScript(messageName: messageName), mainFrameOnly: true, world: world)
        add(ElementHideStore.shared.scriptSource(), mainFrameOnly: false, world: world)
        if Settings.shared.autoHandleCookieBanners {
            add(consentAutoHandlerScript, mainFrameOnly: false, world: world)
        }
        if tor {
            // WebRTC can reveal your real IP over UDP, bypassing the Tor proxy.
            add(disableWebRTCScript, mainFrameOnly: false, world: .page)
        }
    }

    // MARK: Scripts

    /// Plain, low-risk dark theme (no page-wide filters).
    private static let darkThemeScript = """
    (function () {
      var css = ':root{color-scheme:dark}html{background-color:#121217 !important}body{background-color:transparent;color:#dcdce4}';
      function inject() {
        if (document.getElementById('undirect-dark-theme')) return;
        var s = document.createElement('style');
        s.id = 'undirect-dark-theme';
        s.textContent = css;
        (document.head || document.documentElement).appendChild(s);
      }
      if (document.documentElement) inject();
      else document.addEventListener('DOMContentLoaded', inject, { once: true });
    })();
    """

    /// Auto-rejects and hides cookie-consent banners, so you never see one.
    /// Recognizes the handful of big consent-management platforms (OneTrust,
    /// Cookiebot, Didomi, Quantcast/IAB TCF, Osano, Termly) plus a generic
    /// selector list for everything else, and calls each platform's own
    /// "reject non-essential" API where one exists rather than just hiding
    /// the banner blind. Turn off in Settings to see banners normally.
    private static let consentAutoHandlerScript = """
    (function () {
      var selectors = [
        '#onetrust-banner-sdk', '#onetrust-consent-sdk', '.onetrust-pc-dark-filter',
        '#CybotCookiebotDialog', '#CybotCookiebotDialogBodyUnderlay',
        '.qc-cmp2-container', '.fc-consent-root', '#sp_message_container',
        '.didomi-popup-container', '#didomi-host', '.didomi-consent-popup-backdrop',
        '.osano-cm-window', '.osano-cm-dialog', '.termly-styles-consent-container',
        '#cookiescript_injected', '.cc-window', '.cc-banner', '#cookie-law-info-bar',
        '#cookieConsentContainer', '.cookie-consent', '.cookie-banner', '.cookie-notice',
        '#cookie-notice', '.cookiebar', '#cookiebar', '.truste_box_overlay',
        '#truste-consent-track', '.tp-modal-overlay', '#gdpr-consent-tool-wrapper',
        '[class*="cookie-consent" i]', '[id*="cookie-consent" i]', '[class*="cookiebanner" i]',
        '[aria-label*="cookie" i][role="dialog"]'
      ];

      function rejectKnownCMPs() {
        try { if (window.Cookiebot && Cookiebot.submitCustomConsent) Cookiebot.submitCustomConsent(false, false, false); } catch (e) {}
        try { if (window.OneTrust && OneTrust.RejectAll) OneTrust.RejectAll(); } catch (e) {}
        try {
          if (window.didomiOnReady && didomiOnReady.push) {
            didomiOnReady.push(function (Didomi) { try { Didomi.setUserDisagreeToAll(); } catch (e) {} });
          }
        } catch (e) {}
        try {
          if (typeof window.__tcfapi === 'function') {
            window.__tcfapi('setGdprApplies', 2, function () {}, 0);
          }
        } catch (e) {}
        try { if (window.__cmp) window.__cmp('setConsent', null, function () {}, false); } catch (e) {}
        try { if (window.Osano && Osano.cm && Osano.cm.denyAll) Osano.cm.denyAll(); } catch (e) {}
      }

      function hide() {
        for (var i = 0; i < selectors.length; i++) {
          try {
            var els = document.querySelectorAll(selectors[i]);
            for (var j = 0; j < els.length; j++) els[j].style.setProperty('display', 'none', 'important');
          } catch (e) {}
        }
        // Many banners lock page scroll while shown; undo that once hidden.
        if (document.documentElement) document.documentElement.style.overflow = '';
        if (document.body) document.body.style.overflow = '';
      }

      function run() { hide(); rejectKnownCMPs(); }
      if (document.documentElement) run(); else document.addEventListener('DOMContentLoaded', run, { once: true });

      var observer = new MutationObserver(hide);
      function observe() {
        if (document.documentElement) observer.observe(document.documentElement, { childList: true, subtree: true });
      }
      if (document.documentElement) observe(); else document.addEventListener('DOMContentLoaded', observe, { once: true });

      // Banners frequently arrive late via their own async script; keep trying briefly.
      [400, 1000, 2000, 4000].forEach(function (t) { setTimeout(run, t); });
    })();
    """

    private static let disableWebRTCScript = """
    (function () {
      ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel'].forEach(function (k) {
        try { Object.defineProperty(window, k, { value: undefined, writable: false, configurable: false }); } catch (e) {}
      });
      try { Object.defineProperty(navigator, 'mediaDevices', { value: undefined, configurable: false }); } catch (e) {}
    })();
    """

    /// Reports real taps, password submissions and blocked resource loads, and
    /// implements the click-through used to get past redirect/ad overlays.
    private static func agentScript(messageName: String) -> String {
        #"""
        (function () {
          if (window.__undirectAgent) return;
          window.__undirectAgent = true;
          var NAME = '\#(messageName)';
          var isTop = (window.top === window);
          function post(m) { try { window.webkit.messageHandlers[NAME].postMessage(m); } catch (e) {} }

          if (isTop) {
            document.addEventListener('touchstart', function (e) {
              if (window.__undirectPicking) return;
              var t = e.changedTouches && e.changedTouches[0];
              if (!t) return;
              window.__undirectTapEl = e.target;
              post({ type: 'tap', x: t.clientX, y: t.clientY });
            }, { capture: true, passive: true });
            document.addEventListener('click', function (e) {
              if (window.__undirectPicking || !e.isTrusted) return;
              window.__undirectTapEl = e.target;
              post({ type: 'tap', x: e.clientX, y: e.clientY });
            }, true);
          }

          function checkLogin() {
            try {
              var pw = document.querySelectorAll('input[type=password]');
              for (var i = 0; i < pw.length; i++) {
                if (pw[i].value && pw[i].value.length > 0) { post({ type: 'login' }); return; }
              }
            } catch (e) {}
          }
          document.addEventListener('submit', checkLogin, true);
          document.addEventListener('click', function (e) {
            var b = e.target && e.target.closest && e.target.closest('button, input[type=submit], [role=button]');
            if (b) checkLogin();
          }, true);
          document.addEventListener('keydown', function (e) {
            if (e.key === 'Enter' && e.target && e.target.type === 'password') checkLogin();
          }, true);

          var failed = [], timer = null;
          document.addEventListener('error', function (e) {
            var t = e.target;
            if (!t || t === window) return;
            var u = t.currentSrc || t.src || t.href;
            if (!u || typeof u !== 'string') return;
            try {
              var h = new URL(u, location.href).hostname;
              if (!h) return;
              failed.push(h);
              if (!timer) timer = setTimeout(function () {
                post({ type: 'failed', hosts: failed });
                failed = []; timer = null;
              }, 1000);
            } catch (_) {}
          }, true);

          window.__undirectClickThrough = function (x, y) {
            var el = document.elementFromPoint(x, y);
            if (!el) return null;
            var prev = window.__undirectTapEl;
            var same = prev && (el === prev || (el.contains && el.contains(prev)) || (prev.contains && prev.contains(el)));
            var a = el.closest ? el.closest('a[href]') : null;
            if (!same && a && a.href && a.href.indexOf('javascript:') !== 0) return { href: a.href };
            window.__undirectTapEl = el;
            var o = { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window };
            ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function (type) {
              try {
                var C = (type.indexOf('pointer') === 0 && window.PointerEvent) ? PointerEvent : MouseEvent;
                el.dispatchEvent(new C(type, o));
              } catch (e) {}
            });
            return { dispatched: true };
          };
        })();
        """#
    }

    /// Element picker used by "Hide element…".
    private static func pickerScript(messageName: String) -> String {
        #"""
        (function () {
          if (window.__undirectPicker) return;
          var NAME = '\#(messageName)';
          var box = null, current = null;
          function post(m) { try { window.webkit.messageHandlers[NAME].postMessage(m); } catch (e) {} }
          function esc(s) { return (window.CSS && CSS.escape) ? CSS.escape(s) : s.replace(/[^a-zA-Z0-9_-]/g, '\\$&'); }
          function good(n) { return n && n.length < 40 && !/\d{3,}/.test(n) && !/^(css|sc|jsx|emotion|svelte)-/.test(n); }
          function part(el) {
            var tag = el.tagName.toLowerCase();
            if (el.id && good(el.id)) return '#' + esc(el.id);
            var cls = Array.prototype.filter.call(el.classList, good).slice(0, 3).map(function (c) { return '.' + esc(c); }).join('');
            var p = tag + cls;
            var parent = el.parentElement;
            if (parent && !cls) {
              var same = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === el.tagName; });
              if (same.length > 1) p += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
            }
            return p;
          }
          function selectorFor(el) {
            var parts = [], e = el;
            for (var i = 0; i < 6 && e && e !== document.body && e !== document.documentElement; i++) {
              var p = part(e);
              parts.unshift(p);
              if (p.charAt(0) === '#') break;
              try { if (document.querySelectorAll(parts.join(' > ')).length === 1) break; } catch (_) {}
              e = e.parentElement;
            }
            return parts.join(' > ');
          }
          function describe(el) {
            var r = el.getBoundingClientRect();
            var d = el.tagName.toLowerCase();
            if (el.id) d += '#' + el.id;
            else if (el.classList.length) d += '.' + el.classList[0];
            return d + ' (' + Math.round(r.width) + '×' + Math.round(r.height) + ')';
          }
          function highlight(el) {
            if (!box) {
              box = document.createElement('div');
              box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border:2px solid #ff5c8a;background:rgba(255,92,138,0.25);border-radius:4px;';
              document.documentElement.appendChild(box);
            }
            var r = el.getBoundingClientRect();
            box.style.left = r.left + 'px'; box.style.top = r.top + 'px';
            box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
          }
          function info() { return current ? { selector: selectorFor(current), label: describe(current) } : null; }
          function swallow(e) {
            if (!window.__undirectPicking) return;
            e.stopImmediatePropagation();
            if (e.type === 'click') {
              e.preventDefault();
              var el = document.elementFromPoint(e.clientX, e.clientY);
              if (!el || el === document.documentElement || el === document.body || el === box) return;
              current = el;
              highlight(el);
              var i = info();
              post({ type: 'pick', selector: i.selector, label: i.label });
            }
          }
          ['click', 'mousedown', 'mouseup', 'pointerdown', 'pointerup', 'touchstart', 'touchend'].forEach(function (t) {
            document.addEventListener(t, swallow, true);
          });
          window.__undirectPicker = {
            start: function () { window.__undirectPicking = true; current = null; },
            parent: function () {
              if (current && current.parentElement && current.parentElement !== document.body && current.parentElement !== document.documentElement) {
                current = current.parentElement;
                highlight(current);
              }
              return info();
            },
            hide: function () { if (current) current.style.setProperty('display', 'none', 'important'); this.stop(); },
            stop: function () { window.__undirectPicking = false; current = null; if (box) { box.remove(); box = null; } }
          };
        })();
        """#
    }
}
