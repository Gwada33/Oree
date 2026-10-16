import WebKit

/// Refuse les bannières de cookies à la place de la personne : le bouton « Tout refuser » des gestionnaires de consentement courants (OneTrust, Cookiebot, Didomi,
/// Usercentrics, Quantcast, CookieYes, Complianz, Axeptio…), puis, à défaut, un bouton de refus à l'intérieur de ce qui ressemble à une bannière de consentement.
/// Il ne clique JAMAIS sur « Accepter » ni sur « Personnaliser » : s'il n'y a pas de bouton de refus clair, la bannière reste et la personne décide.
/// Il observe la page quelques secondes (les bannières arrivent souvent après le chargement) puis s'arrête : aucun coût ensuite.
public enum CookieBannerScript {
    /// Les textes de bouton qui veulent dire « refuser », en français et en anglais (tout le texte du bouton, pas un morceau).
    public static let rejectPattern = "^(tout refuser|refuser tout|refuser|refuser les cookies|refuser tous les cookies|tout rejeter|rejeter tout|rejeter|continuer sans accepter|continuer sans consentir|non merci|non, merci|uniquement (les )?cookies? (n[ée]cessaires|essentiels|obligatoires)|(cookies? )?(n[ée]cessaires|essentiels) uniquement|refuser et fermer|reject all|reject|reject all cookies|decline|decline all|deny|deny all|refuse all|refuse|no thanks|no, thanks|only (necessary|essential|required) cookies|necessary cookies only|essential cookies only|continue without accepting|use necessary cookies only)$"

    /// Les gestionnaires connus : le sélecteur de leur bouton de refus.
    public static let knownSelectors = [
        "#onetrust-reject-all-handler", ".ot-pc-refuse-all-handler", "#CybotCookiebotDialogBodyButtonDecline", "#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll",
        "#didomi-notice-disagree-button", ".didomi-continue-without-agreeing", "[data-testid='uc-deny-all-button']", "button.sp_choice_type_REJECT_ALL", "button[title='Reject all']",
        ".cky-btn-reject", ".cmplz-deny", "#axeptio_btn_dismiss", ".osano-cm-denyAll", ".cn-decline", "#cookie-consent-decline", "button[data-cookiebanner='reject_button']",
        ".qc-cmp2-summary-buttons button[mode='secondary']:not([class*='save'])", "#truste-consent-required", ".iubenda-cs-reject-btn", ".termsfeed-com---nb .cc-nb-reject",
    ]

    @MainActor
    public static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    nonisolated public static var source: String {
        let selectors = (try? String(data: JSONSerialization.data(withJSONObject: knownSelectors), encoding: .utf8)) ?? "[]"
        return """
        (function () {
          'use strict';
          if (window.__hbCookie) { return; }
          window.__hbCookie = true;
          const HANDLER = '\(CredentialScript.handlerName)';
          const KNOWN = \(selectors);
          const REJECT = new RegExp(\(JSONEncoderString.quote(rejectPattern)), 'i');
          const CONSENT_HINT = /cookie|consent|gdpr|rgpd|cmp|privacy|confidentialit|tracking|banner|didomi|onetrust|cookiebot|usercentrics|sp_message|truste|qc-cmp/i;
          let done = false, tries = 0;
          const visible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
          const textOf = (el) => (el.innerText || el.value || el.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim();

          function click(el, method) {
            if (done) return true;
            done = true;
            try { el.click(); } catch (e) { return false; }
            try { window.webkit.messageHandlers[HANDLER].postMessage({ type: 'cookieBanner', method: method }); } catch (e) {}
            return true;
          }

          // Un bouton de refus dans quelque chose qui ressemble à une bannière : un conteneur dont l'identifiant, la classe ou le rôle parle de consentement, ou une fenêtre fixe.
          function insideConsent(el) {
            for (let node = el.parentElement, depth = 0; node && depth < 8; node = node.parentElement, depth++) {
              const hint = (node.id || '') + ' ' + (typeof node.className === 'string' ? node.className : '') + ' ' + (node.getAttribute('role') || '') + ' ' + (node.getAttribute('aria-label') || '');
              if (CONSENT_HINT.test(hint)) return true;
              const style = getComputedStyle(node);
              if ((style.position === 'fixed' || style.position === 'sticky') && /cookie|consent|cookies|confidentialit|privacy/i.test(node.innerText || '')) return true;
            }
            return false;
          }

          function attempt() {
            if (done) return;
            tries++;
            for (const selector of KNOWN) {
              let el = null;
              try { el = document.querySelector(selector); } catch (e) {}
              if (el && visible(el) && click(el, 'known')) return;
            }
            const buttons = document.querySelectorAll('button, a[role=button], [role=button], input[type=button], input[type=submit], a.button, a.btn');
            for (const el of buttons) {
              if (!visible(el)) continue;
              const text = textOf(el);
              if (text.length > 60 || !REJECT.test(text)) continue;
              if (insideConsent(el) && click(el, 'text')) return;
            }
          }

          attempt();
          if (done) return;
          // Les bannières arrivent souvent après le chargement : on surveille la page 8 secondes, au plus 30 essais, puis on s'arrête.
          const observer = new MutationObserver(() => { if (tries < 30) attempt(); });
          observer.observe(document.documentElement, { childList: true, subtree: true });
          setTimeout(() => observer.disconnect(), 8000);
        })();
        """
    }
}

/// Une chaîne Swift → un littéral JavaScript (guillemets doublés, caractères spéciaux protégés).
enum JSONEncoderString {
    static func quote(_ text: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }
}
