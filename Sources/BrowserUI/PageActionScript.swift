import WebKit
import BrowserCore

/// Les mains de l'IA côté page, dans le monde isolé `oree-ai` (le même que les yeux : `window.__oreeAI.resolve(n)` retrouve l'élément d'une référence `@eN`).
/// Les champs « contrôlés » (React, Vue…) ignorent `el.value = …` : on passe par le setter natif du prototype puis on envoie `input`, `change`, `blur`.
@MainActor
enum PageActionScript {
    static let world = PageMapScript.world

    /// `arguments` : op (describe | click | type | select | scroll), ref, value, submit, direction. Ne renvoie jamais une valeur saisie.
    static let run = """
    const S = window.__oreeAI;
    const el = ref ? (S && S.resolve(ref)) : null;
    const CARD = /card|cvc|cvv|iban|cc-|carte|cryptogramme/i;
    const label = e => (e.getAttribute('aria-label') || (e.labels && e.labels[0] && e.labels[0].textContent) || e.innerText || e.value || e.getAttribute('placeholder') || e.name || '').replace(/\\s+/g, ' ').trim().slice(0, 120);
    const fire = (e, type, init) => e.dispatchEvent(new (type.startsWith('pointer') ? PointerEvent : type.startsWith('mouse') || type === 'click' ? MouseEvent : Event)(type, Object.assign({ bubbles: true, cancelable: true, composed: true, view: window }, init || {})));
    const setNative = (e, v) => {
      const proto = e instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : e instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(e, v);
    };
    if (op === 'scroll') {
      const h = window.innerHeight * 0.8;
      if (direction === 'top') window.scrollTo(0, 0); else if (direction === 'bottom') window.scrollTo(0, document.body.scrollHeight);
      else window.scrollBy(0, direction === 'up' ? -h : h);
      return { ok: true };
    }
    if (!el) return { ok: false, error: 'stale' };
    if (op === 'describe') {
      const form = el.form || el.closest('form');
      const tag = el.tagName.toLowerCase();
      const type = tag === 'input' ? (el.type || 'text').toLowerCase() : null;
      const isSubmit = !!form && ((tag === 'button' && (el.getAttribute('type') || 'submit').toLowerCase() === 'submit') || (tag === 'input' && ['submit', 'image'].includes(type)));
      const secretIn = f => !!f && [...f.querySelectorAll('input')].some(i => i.type === 'password' || CARD.test(i.autocomplete + ' ' + i.name + ' ' + i.id));
      return { ref, tag, type, label: label(el), isSubmit, inForm: !!form, formHasSecret: secretIn(form), href: tag === 'a' ? el.getAttribute('href') : null, download: el.hasAttribute('download') };
    }
    el.scrollIntoView({ block: 'center', inline: 'nearest' });
    // Surlignage : un cadre fin de la couleur de l'accent autour de l'élément visé, une seconde (sans animation si le mouvement est réduit).
    { const r = el.getBoundingClientRect(); const box = document.createElement('div');
      box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #2F7354;border-radius:6px;background:rgba(47,115,84,.10);left:' + (r.left - 3) + 'px;top:' + (r.top - 3) + 'px;width:' + (r.width + 6) + 'px;height:' + (r.height + 6) + 'px;';
      if (!matchMedia('(prefers-reduced-motion: reduce)').matches) box.style.transition = 'opacity .26s cubic-bezier(.2,.8,.2,1)';
      document.documentElement.appendChild(box);
      setTimeout(() => { box.style.opacity = '0'; setTimeout(() => box.remove(), 300); }, 1000); }
    if (op === 'click') {
      for (const t of ['pointerover', 'mouseover', 'pointerdown', 'mousedown']) fire(el, t);
      if (el.focus) el.focus();
      for (const t of ['pointerup', 'mouseup']) fire(el, t);
      el.click();
      return { ok: true };
    }
    if (op === 'type') {
      if (el.isContentEditable && !('value' in el)) { el.focus(); el.textContent = value; fire(el, 'input'); }
      else {
        el.focus();
        setNative(el, value);
        el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: value }));
        fire(el, 'change');
        el.blur();
      }
      if (submit) { const f = el.form; if (f && f.requestSubmit) f.requestSubmit(); else for (const t of ['keydown', 'keypress', 'keyup']) el.dispatchEvent(new KeyboardEvent(t, { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true })); }
      return { ok: true };
    }
    if (op === 'select') {
      const wanted = value.toLowerCase();
      const opt = [...el.options].find(o => o.value.toLowerCase() === wanted || o.textContent.trim().toLowerCase() === wanted) || [...el.options].find(o => o.textContent.toLowerCase().includes(wanted));
      if (!opt) return { ok: false, error: 'option' };
      el.focus(); setNative(el, opt.value); fire(el, 'input'); fire(el, 'change'); el.blur();
      return { ok: true };
    }
    return { ok: false, error: 'op' };
    """
}

/// Fait les gestes demandés par le modèle, après les règles de `ActionPolicy`. Rien ne part sans confirmation quand la règle l'exige,
/// et les valeurs du profil ne reviennent jamais dans le résultat (qui va au modèle).
@MainActor
enum ActionExecutor {
    struct Result: Equatable {
        var ok: Bool
        var message: String          // pour le modèle et la trace : jamais une valeur saisie
        var askedConfirmation = false
    }

    private static func call(_ web: WKWebView, _ args: [String: Any]) async -> [String: Any]? {
        var full: [String: Any] = ["op": "", "ref": 0, "value": "", "submit": false, "direction": "down"]
        full.merge(args) { $1 }
        return await web.callJSON(PageActionScript.run, arguments: full, world: PageActionScript.world, seconds: 8) as? [String: Any]
    }

    private static func describe(_ web: WKWebView, _ ref: Int) async -> ActionTarget? {
        guard let raw = await call(web, ["op": "describe", "ref": ref]), raw["error"] == nil,
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(ActionTarget.self, from: data)
    }

    /// - Parameters:
    ///   - profile: les valeurs des jetons `{{profil.xxx}}` (Trousseau).
    ///   - confirm: reçoit la phrase à montrer à la personne ; vrai = elle a validé.
    static func execute(_ action: AIAction, in web: WKWebView, profile: [String: String], confirm: (String) async -> Bool) async -> Result {
        let url = web.url
        // 1. Les jetons : remplacés ici, jamais envoyés au modèle ; un jeton inconnu arrête tout.
        var resolved: [String]
        do { resolved = try action.typedValues.map { try ProfileTokens.resolve($0, profile: profile) } }
        catch ProfileTokens.TokenError.unknown(let key) { return Result(ok: false, message: "Le profil n'a pas de « \(key) ». Demandez-le à la personne.") }
        catch { return Result(ok: false, message: "Valeur illisible.") }

        // 2. Les cibles et la décision (la plus stricte l'emporte).
        let refs: [Int]
        switch action {
        case .click(let r), .type(let r, _, _), .select(let r, _): refs = [r]
        case .fillForm(let fields): refs = fields.map(\.ref)
        case .scroll: refs = []
        }
        var targets: [Int: ActionTarget] = [:]
        var reasons: [String] = []
        if refs.isEmpty, case .scroll = action, ActionPolicy.isForbiddenPage(url) { return Result(ok: false, message: "L'IA n'agit pas sur cette page.") }
        for ref in refs {
            guard let target = await describe(web, ref) else { return Result(ok: false, message: "L'élément @e\(ref) n'est plus sur la page. Relisez la page.") }
            targets[ref] = target
            let single: AIAction = { if case .fillForm = action { return .type(ref: ref, text: "", submit: false) }; return action }()
            switch ActionPolicy.decide(single, target: target, pageURL: url) {
            case .allow: break
            case .refuse(let reason): return Result(ok: false, message: reason)
            case .confirm(let reason): reasons.append(reason)
            }
        }
        var asked = false
        if !reasons.isEmpty {
            asked = true
            let host = url?.host ?? "cette page"
            guard await confirm("\(reasons.joined(separator: " · ")) — sur \(host)") else { return Result(ok: false, message: "La personne a refusé.", askedConfirmation: true) }
        }

        // 3. Les gestes.
        func label(_ ref: Int) -> String { "« \(targets[ref]?.label ?? "@e\(ref)") »" }
        func run(_ args: [String: Any]) async -> Bool { (await call(web, args))?["ok"] as? Bool == true }
        switch action {
        case .scroll(let direction):
            return Result(ok: await run(["op": "scroll", "direction": direction]), message: "Page défilée.")
        case .click(let ref):
            let ok = await run(["op": "click", "ref": ref])
            return Result(ok: ok, message: ok ? "Clic sur \(label(ref))." : "Le clic a échoué.", askedConfirmation: asked)
        case .type(let ref, _, let submit):
            let ok = await run(["op": "type", "ref": ref, "value": resolved[0], "submit": submit])
            return Result(ok: ok, message: ok ? "Saisie dans \(label(ref))." : "La saisie a échoué.", askedConfirmation: asked)
        case .select(let ref, _):
            let ok = await run(["op": "select", "ref": ref, "value": resolved[0]])
            return Result(ok: ok, message: ok ? "Choix dans \(label(ref))." : "Option introuvable.", askedConfirmation: asked)
        case .fillForm(let fields):
            var done = 0
            for (index, field) in fields.enumerated() {
                let isSelect = targets[field.ref]?.tag == "select"
                if await run(["op": isSelect ? "select" : "type", "ref": field.ref, "value": resolved[index]]) { done += 1 }
            }
            return Result(ok: done == fields.count, message: "Remplissage de \(done) champ\(done > 1 ? "s" : "") sur \(fields.count).", askedConfirmation: asked)
        }
    }
}
