import WebKit
import LocalAuthentication

/// Page-side half of the password manager. Injected into the main frame only
/// (never iframes, so an embedded ad can't see or trigger anything).
///
/// It reports two things to the app through the `hbCreds` message handler:
///  - `focus`: the user clicked/tabbed into a login field (only if a real
///    user gesture happened just before — a page can't prompt on its own);
///  - `submit`: a form with a filled-in password field was submitted.
/// And it exposes `window.__hbFill(username, password)`, which the app calls
/// after the user authenticated.
///
/// The origin is never taken from the page: the app reads it from WebKit's
/// own frame info.
public enum CredentialScript {
    public static let handlerName = "hbCreds"

    @MainActor
    public static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    nonisolated public static let source = """
    (function () {
      'use strict';
      if (window.__hbFill) { return; }
      const HANDLER = '\(handlerName)';
      const post = (message) => {
        try { window.webkit.messageHandlers[HANDLER].postMessage(message); } catch (e) {}
      };

      const typeOf = (el) => (el.getAttribute('type') || 'text').toLowerCase();
      const isPassword = (el) => el && el.tagName === 'INPUT' && typeOf(el) === 'password';
      const isTextish = (el) => el && el.tagName === 'INPUT' && ['text', 'email', 'tel'].indexOf(typeOf(el)) !== -1;
      const isVisible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);

      function passwordIn(scope, requireValue) {
        const fields = scope.querySelectorAll('input[type=password]');
        for (const f of fields) {
          if (f.disabled || !isVisible(f)) continue;
          if (requireValue && !f.value) continue;
          return f;
        }
        return null;
      }

      // The username is the closest visible text-like input before the password.
      function usernameFor(password) {
        const scope = password.form || document;
        const inputs = Array.prototype.slice.call(scope.querySelectorAll('input'));
        for (let i = inputs.indexOf(password) - 1; i >= 0; i--) {
          if (isTextish(inputs[i]) && !inputs[i].disabled && isVisible(inputs[i])) return inputs[i];
        }
        return null;
      }

      // A login form = a visible password field in the same form as this field.
      function isLoginField(el) {
        if (isPassword(el)) return true;
        if (!isTextish(el)) return false;
        const scope = el.form || document;
        const pw = passwordIn(scope, false);
        return !!pw && usernameFor(pw) === el;
      }

      // Only react to focus that follows a real click/keypress.
      let lastGesture = 0;
      const markGesture = (e) => { if (e.isTrusted) lastGesture = Date.now(); };
      document.addEventListener('pointerdown', markGesture, true);
      document.addEventListener('keydown', markGesture, true);

      // Champs de code à usage unique (2FA) : par l'attribut standard, ou par le nom du champ et sa forme (4 à 8 chiffres).
      const OTP_NAME = /otp|totp|2fa|mfa|one.?time|verif|security.?code|auth.?code|code.?(sms|secur)|token|passcode/i;
      function isOtpField(el) {
        if (!el || el.tagName !== 'INPUT' || el.disabled || !isVisible(el)) return false;
        const t = typeOf(el);
        if (['text', 'tel', 'number'].indexOf(t) === -1) return false;
        if ((el.getAttribute('autocomplete') || '').toLowerCase().indexOf('one-time-code') !== -1) return true;
        const hint = [el.name, el.id, el.placeholder, el.getAttribute('aria-label')].join(' ');
        const len = el.maxLength > 0 ? el.maxLength : 0;
        const numeric = (el.inputMode || '') === 'numeric' || /\\d/.test(el.getAttribute('pattern') || '') || t === 'number' || t === 'tel';
        return OTP_NAME.test(hint) && ((len >= 4 && len <= 8) || numeric || len === 1);
      }
      // Un code coupé en plusieurs cases d'un chiffre : le groupe de cases voisines.
      function otpGroup(el) {
        if (el.maxLength !== 1) return [el];
        const scope = el.closest('form') || el.parentElement && el.parentElement.parentElement || document;
        const boxes = Array.prototype.slice.call(scope.querySelectorAll('input')).filter((i) => i.maxLength === 1 && isVisible(i) && !i.disabled);
        return boxes.length >= 4 && boxes.length <= 8 ? boxes : [el];
      }

      document.addEventListener('focusin', (e) => {
        if (!e.isTrusted || Date.now() - lastGesture > 1500) return;
        if (isLoginField(e.target)) post({ type: 'focus' });
        else if (isOtpField(e.target)) post({ type: 'otp' });
      }, true);

      let lastSubmit = 0;
      function report(scope) {
        const pw = passwordIn(scope || document, true);
        if (!pw || Date.now() - lastSubmit < 1000) return;
        const user = usernameFor(pw);
        lastSubmit = Date.now();
        post({ type: 'submit', username: user ? user.value : '', password: pw.value });
      }
      document.addEventListener('submit', (e) => { if (e.isTrusted) report(e.target); }, true);
      // Sites that log in with fetch()/XHR never fire 'submit': also watch clicks on buttons.
      document.addEventListener('click', (e) => {
        if (!e.isTrusted) return;
        const button = e.target.closest && e.target.closest('button, input[type=submit], input[type=button], [role=button]');
        if (button) report(button.form || document);
      }, true);

      const nativeSet = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      function setValue(el, value) {
        nativeSet.call(el, value);   // bypass framework-patched setters (React, Vue…)
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
      Object.defineProperty(window, '__hbFillOTP', {
        value: function (code) {
          const focused = isOtpField(document.activeElement) ? document.activeElement : null;
          const field = focused || Array.prototype.slice.call(document.querySelectorAll('input')).find(isOtpField);
          if (!field) return false;
          const group = otpGroup(field);
          if (group.length > 1) { group.forEach((box, i) => { if (code[i]) setValue(box, code[i]); }); }
          else setValue(field, code);
          return true;
        },
        enumerable: false, configurable: false, writable: false,
      });
      Object.defineProperty(window, '__hbFill', {
        value: function (username, password) {
          const pw = passwordIn(document, false);
          if (!pw) return false;
          const user = usernameFor(pw);
          if (user && username) setValue(user, username);
          setValue(pw, password);
          return true;
        },
        enumerable: false, configurable: false, writable: false,
      });
    })();
    """
}

/// Gate in front of revealing or filling a saved password: Touch ID (or the
/// account password), then a short "unlocked" window so filling several
/// fields in a row doesn't re-prompt each time.
public actor VaultUnlocker {
    public static let shared = VaultUnlocker()

    /// Set only by the `--automation` dev channel, which can't press a fingerprint sensor.
    public nonisolated(unsafe) static var automationBypass = false

    private let sessionDuration: TimeInterval
    private let now: @Sendable () -> Date
    private let evaluate: @Sendable (String) async -> Bool
    private var unlockedUntil = Date.distantPast

    public init(
        sessionDuration: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() },
        evaluate: @escaping @Sendable (String) async -> Bool = VaultUnlocker.systemEvaluate
    ) {
        self.sessionDuration = sessionDuration
        self.now = now
        self.evaluate = evaluate
    }

    public func authenticate(reason: String) async -> Bool {
        if now() < unlockedUntil { return true }
        guard await evaluate(reason) else { return false }
        unlockedUntil = now().addingTimeInterval(sessionDuration)
        return true
    }

    public func lock() { unlockedUntil = .distantPast }

    public static let systemEvaluate: @Sendable (String) async -> Bool = { reason in
        if automationBypass { return true }
        let context = LAContext()
        var error: NSError?
        // .deviceOwnerAuthentication = Touch ID with the account password as fallback.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
