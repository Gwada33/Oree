import WebKit

/// La page d'un formulaire d'adresse ou de carte : reconnaît les champs (par l'attribut standard `autocomplete`, sinon par leur nom, leur étiquette, leur forme, en français et en
/// anglais), prévient l'app quand on entre dans l'un d'eux (avec le rectangle du champ, pour ouvrir un menu juste dessous), remplit les champs avec les valeurs que l'app donne, et
/// signale l'envoi d'un formulaire (pour proposer d'enregistrer). Le script ne garde rien : les valeurs qu'il voit à l'envoi partent à l'app, qui décide.
/// Image-miroir de `CredentialScript` : même poignée (`hbCreds`), mêmes règles (image principale seulement, geste réel de la personne avant toute proposition).
public enum AutofillScript {
    @MainActor
    public static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    nonisolated public static let source = """
    (function () {
      'use strict';
      if (window.__hbFillForm) { return; }
      const HANDLER = '\\(CredentialScript.handlerName)';
      const post = (message) => { try { window.webkit.messageHandlers[HANDLER].postMessage(message); } catch (e) {} };

      const ADDRESS = ['name', 'given-name', 'family-name', 'organization', 'email', 'tel', 'tel-national', 'street-address', 'address-line1', 'address-line2', 'postal-code', 'address-level2', 'address-level1', 'country', 'country-name'];
      const CARD = ['cc-name', 'cc-number', 'cc-exp', 'cc-exp-month', 'cc-exp-year', 'cc-csc'];
      const kindOf = (token) => (CARD.indexOf(token) !== -1 ? 'card' : (ADDRESS.indexOf(token) !== -1 ? 'address' : null));

      // L'ordre compte : le plus précis d'abord (« e-mail » avant « nom », « code postal » avant « code »).
      const RULES = [
        ['cc-csc', /cvc|cvv|csc|cid\\b|security.?code|code.?de.?s[ée]curit[ée]|cryptogramme/i],
        ['cc-number', /card.?number|cc.?num|cardnumber|ccnumber|num[ée]ro.?de.?carte|num[ée]ro.?carte|n°.?carte/i],
        ['cc-name', /card.?holder|name.?on.?card|cc.?name|titulaire|nom.?sur.?la.?carte/i],
        ['cc-exp-month', /exp.*month|cc.?month|expmonth|mois.?d.?exp|^mois$|\\bmm\\b/i],
        ['cc-exp-year', /exp.*year|cc.?year|expyear|ann[ée]e.?d.?exp|^ann[ée]e$|\\byy(yy)?\\b/i],
        ['cc-exp', /expir|exp.?date|valid.?(thru|until|jusqu)|date.?d.?exp|mm.?\\/.?yy/i],
        ['email', /e-?mail|courriel/i],
        ['tel', /phone|t[ée]l[ée]?phone|\\btel\\b|mobile|portable|gsm/i],
        ['postal-code', /zip|postal|code.?postal|\\bcp\\b/i],
        ['address-level2', /\\bcity\\b|ville|town|commune|locality/i],
        ['address-level1', /\\bstate\\b|province|region|r[ée]gion|d[ée]partement/i],
        ['country-name', /country|pays/i],
        ['address-line2', /address.?(line)?.?2|addr.?2|compl[ée]ment|apt|suite|appartement|b[âa]timent|building/i],
        ['address-line1', /address.?(line)?.?1|addr.?1|street|adresse|\\brue\\b|^address$/i],
        ['organization', /company|organi[sz]ation|soci[ée]t[ée]|entreprise|employer/i],
        ['given-name', /first.?name|given.?name|fname|pr[ée]nom|prenom/i],
        ['family-name', /last.?name|family.?name|surname|lname|nom.?de.?famille|^nom$/i],
        ['name', /full.?name|nom.?complet|your.?name|^name$|^nom.?et.?pr/i],
      ];

      const labelText = (el) => {
        let text = '';
        try { if (el.labels && el.labels.length) text = Array.prototype.map.call(el.labels, (l) => l.textContent).join(' '); } catch (e) {}
        return text;
      };

      function tokenOf(el) {
        if (!el || el.disabled || el.readOnly) return null;
        const tag = el.tagName;
        if (tag !== 'INPUT' && tag !== 'SELECT' && tag !== 'TEXTAREA') return null;
        const type = (el.getAttribute('type') || 'text').toLowerCase();
        if (['hidden', 'password', 'submit', 'button', 'checkbox', 'radio', 'file', 'image', 'reset', 'range', 'color'].indexOf(type) !== -1) return null;
        const auto = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\\s+/);
        for (let i = auto.length - 1; i >= 0; i--) { if (kindOf(auto[i])) return auto[i]; }
        if (type === 'email') return 'email';
        if (type === 'tel') return 'tel';
        const parts = [el.name, el.id, el.placeholder, el.getAttribute('aria-label'), labelText(el)].map((t) => String(t || '').trim());
        const hint = parts.join(' ');
        // Chaque indice seul (pour les motifs « exactement ce mot », comme « Nom »), puis tous ensemble.
        for (const [token, pattern] of RULES) { if (pattern.test(hint) || parts.some((p) => p && pattern.test(p))) return token; }
        return null;
      }

      const isVisible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
      const scopeOf = (el) => el.form || document;
      const fieldsOf = (scope) => Array.prototype.slice.call(scope.querySelectorAll('input, select, textarea')).filter((e) => isVisible(e) && tokenOf(e));

      let lastGesture = 0;
      const markGesture = (e) => { if (e.isTrusted) lastGesture = Date.now(); };
      document.addEventListener('pointerdown', markGesture, true);
      document.addEventListener('keydown', markGesture, true);

      // Une proposition par sorte de formulaire et par page (pas à chaque champ) ; seulement pour un champ vide.
      const offered = {};
      document.addEventListener('focusin', (e) => {
        if (!e.isTrusted || Date.now() - lastGesture > 1500) return;
        const el = e.target, token = tokenOf(el), kind = token && kindOf(token);
        if (!kind || offered[kind] || (el.value && el.tagName !== 'SELECT')) return;
        // Un formulaire d'adresse n'a de sens qu'avec au moins deux champs reconnus (un simple champ « e-mail » ne propose pas une adresse).
        const found = fieldsOf(scopeOf(el)).filter((f) => kindOf(tokenOf(f)) === kind);
        if (found.length < 2 || (kind === 'card' && !found.some((f) => tokenOf(f) === 'cc-number'))) return;
        offered[kind] = true;
        const r = el.getBoundingClientRect();
        post({ type: kind, x: r.left, y: r.bottom, w: r.width, h: r.height });
      }, true);

      const nativeInput = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      const nativeArea = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
      const fold = (s) => String(s || '').normalize('NFD').replace(/[\\u0300-\\u036f]/g, '').toLowerCase().trim();
      function fire(el) { el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); }
      function setValue(el, value) {
        if (el.tagName === 'SELECT') {
          const want = fold(value);
          const alt = want.replace(/^0+/, '');
          const options = Array.prototype.slice.call(el.options);
          const match = options.find((o) => fold(o.value) === want || fold(o.textContent) === want) || options.find((o) => fold(o.value) === alt || fold(o.textContent) === alt)
            || options.find((o) => want.length >= 2 && (fold(o.textContent).indexOf(want) === 0 || fold(o.value).slice(-want.length) === want));
          if (!match) return false;
          el.value = match.value; fire(el); return true;
        }
        (el.tagName === 'TEXTAREA' ? nativeArea : nativeInput).call(el, value);   // contourne les accesseurs des frameworks (React, Vue…)
        fire(el); return true;
      }

      Object.defineProperty(window, '__hbFillForm', {
        value: function (kind, values) {
          const active = document.activeElement;
          const scope = active && tokenOf(active) ? scopeOf(active) : document;
          let count = 0;
          const fields = fieldsOf(scope).filter((f) => kindOf(tokenOf(f)) === kind);
          const have = new Set(fields.map(tokenOf));
          for (const el of fields) {
            let token = tokenOf(el), value = values[token];
            if (value === undefined && token === 'name' && !have.has('given-name')) value = values['name'];
            if (value === undefined && token === 'cc-exp' && values['cc-exp']) value = values['cc-exp'];
            if (value === undefined) continue;
            if (token === 'cc-exp' && el.maxLength === 5 && value.length === 7) value = value.slice(0, 3) + value.slice(5);
            if (token === 'cc-exp-year' && el.tagName === 'INPUT' && el.maxLength === 2) value = String(value).slice(-2);
            if (setValue(el, String(value))) count++;
          }
          return count;
        },
        enumerable: false, configurable: false, writable: false,
      });

      // L'envoi d'un formulaire : si des champs d'adresse ou de carte étaient remplis, l'app propose d'enregistrer (elle compare à ce qu'elle a déjà).
      let lastSubmit = 0;
      function report(scope) {
        if (Date.now() - lastSubmit < 1500) return;
        const values = { address: {}, card: {} };
        for (const el of fieldsOf(scope)) {
          const token = tokenOf(el), kind = kindOf(token);
          if (!kind || token === 'cc-csc' || !el.value) continue;
          values[kind][token] = el.tagName === 'SELECT' ? (el.selectedOptions[0] ? el.selectedOptions[0].textContent.trim() : el.value) : el.value;
        }
        const a = values.address, c = values.card;
        const hasAddress = Object.keys(a).length >= 3 && (a['address-line1'] || a['street-address']) && (a['postal-code'] || a['address-level2']);
        const hasCard = c['cc-number'] && String(c['cc-number']).replace(/\\D/g, '').length >= 12;
        if (!hasAddress && !hasCard) return;
        lastSubmit = Date.now();
        if (hasCard) post({ type: 'cardSubmit', values: c });
        if (hasAddress) post({ type: 'addressSubmit', values: a });
      }
      document.addEventListener('submit', (e) => { if (e.isTrusted) report(e.target); }, true);
      document.addEventListener('click', (e) => {
        if (!e.isTrusted) return;
        const button = e.target.closest && e.target.closest('button, input[type=submit], [role=button]');
        if (button) report(button.form || document);
      }, true);
    })();
    """
}
