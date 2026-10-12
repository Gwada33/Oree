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
      const fields = [];
      if (form) for (const f of form.elements) {
        if (fields.length >= 8) break;
        const ft = (f.type || '').toLowerCase();
        if (!['INPUT', 'SELECT', 'TEXTAREA'].includes(f.tagName) || ['hidden', 'submit', 'button', 'reset', 'image', 'file'].includes(ft) || !f.getClientRects().length) continue;
        const secret = ft === 'password' || CARD.test((f.autocomplete || '') + ' ' + f.name + ' ' + f.id);
        let value = f.tagName === 'SELECT' ? (f.selectedOptions[0] ? f.selectedOptions[0].textContent.trim() : '') : (ft === 'checkbox' || ft === 'radio' ? (f.checked ? 'Oui' : 'Non') : f.value);
        if (!secret && !value) continue;
        const digits = secret ? (f.value || '').replace(/\\D/g, '') : '';
        fields.push({ label: label(f).slice(0, 40), value: secret ? '' : value.slice(0, 80), secret, last4: digits.length >= 12 ? digits.slice(-4) : null });
      }
      return { ref, tag, type, label: label(el), isSubmit, inForm: !!form, formHasSecret: secretIn(form), href: tag === 'a' ? el.getAttribute('href') : null, download: el.hasAttribute('download'), fields };
    }
    el.scrollIntoView({ block: 'center', inline: 'nearest' });
    // Le surlignage et le déplacement de Luciole sont dessinés par Orée au-dessus de la page (AgentCursor), jamais dans le DOM du site.
    if (op === 'reveal') {
      const r = el.getBoundingClientRect();
      return { ok: true, x: r.left, y: r.top, w: r.width, h: r.height };
    }
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

    /// La carte « Validation requise » : ce qui va partir, en clair (les secrets masqués), et ce que fait le clic.
    private static func request(for action: AIAction, targets: [Int: ActionTarget], reasons: [String], host: String) -> ConfirmRequest {
        let target = targets.values.first { $0.isSubmit || !$0.fields.isEmpty } ?? targets.values.first
        let label = target?.label ?? "le bouton"
        var title = "Envoyer ce formulaire ?"
        let profileUse = reasons.contains { $0.hasPrefix("Profil") }
        if profileUse { title = "Remplir avec vos informations ?" }
        if reasons.contains(where: { $0.hasPrefix("Achat") }) { title = "Valider cet achat ?" }
        else if reasons.contains(where: { $0.hasPrefix("Télécharger") }) { title = "Télécharger ce fichier ?" }
        else if reasons.contains(where: { $0.hasPrefix("Connexion") || $0.hasPrefix("Se connecter") }) { title = "Se connecter ?" }
        var rows = profileUse ? [(key: "Champ", value: label), (key: "Données", value: reasons.first { $0.hasPrefix("Profil") }?.components(separatedBy: "(").last?.components(separatedBy: ")").first ?? "profil")] : (target?.fields ?? []).map { (key: $0.label.isEmpty ? "Champ" : $0.label, value: $0.shown) }
        if rows.isEmpty { rows = [(key: "Page", value: host), (key: "Action", value: label)] }
        let download = target.map(ActionPolicy.isDownloadLink) ?? false
        let warning = profileUse ? "Je vais écrire vos informations dans cette page ; le site pourra les lire. Je ne les envoie à aucun fournisseur d'IA." : download ? "Je vais télécharger « \(label) »." : "Je vais cliquer sur « \(label) ». Une fois envoyé, je ne pourrai pas l'annuler."
        return ConfirmRequest(title: title, rows: rows, warning: warning, host: host)
    }

    /// - Parameters:
    ///   - profile: les valeurs des jetons `{{profil.xxx}}` (Trousseau).
    ///   - confirm: reçoit la phrase à montrer à la personne ; vrai = elle a validé.
    static func execute(_ action: AIAction, in web: WKWebView, profile: [String: String], presence: AgentPresence? = nil, confirm: (ConfirmRequest) async -> Bool) async -> Result {
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
            let single: AIAction = { if case .fillForm(let fields) = action { return .type(ref: ref, text: fields.first { $0.ref == ref }?.value ?? "", submit: false) }; return action }()
            switch ActionPolicy.decide(single, target: target, pageURL: url) {
            case .allow: break
            case .refuse(let reason): return Result(ok: false, message: reason)
            case .confirm(let reason): reasons.append(reason)
            }
        }
        // Luciole va jusqu'à l'élément AVANT de demander l'accord : la personne voit de quoi il s'agit, et elle reste là pendant qu'elle décide.
        func reveal(_ ref: Int, _ kind: PresenceKind) async {
            guard let presence, let raw = await call(web, ["op": "reveal", "ref": ref]), raw["ok"] as? Bool == true,
                  let x = raw["x"] as? Double, let y = raw["y"] as? Double, let w = raw["w"] as? Double, let h = raw["h"] as? Double else { return }
            await presence.reveal(rect: CGRect(x: x, y: y, width: w, height: h), in: web, kind: kind)
        }
        let singleKind: PresenceKind? = { switch action { case .click: .click; case .type: .type; case .select: .select; default: nil } }()
        if let ref = refs.first, let singleKind, refs.count == 1 { await reveal(ref, singleKind) }
        var asked = false
        if !reasons.isEmpty {
            presence?.hold(.wait)
            asked = true
            let host = url?.host ?? "cette page"
            guard await confirm(Self.request(for: action, targets: targets, reasons: reasons, host: host)) else { return Result(ok: false, message: "La personne a refusé. N'insiste pas : réponds avec done.", askedConfirmation: true) }
        }

        // 3. Les gestes.
        func label(_ ref: Int) -> String { "« \(targets[ref]?.label ?? "@e\(ref)") »" }
        func run(_ args: [String: Any]) async -> Bool { (await call(web, args))?["ok"] as? Bool == true }
        switch action {
        case .scroll(let direction):
            return Result(ok: await run(["op": "scroll", "direction": direction]), message: "Page défilée.")
        case .click(let ref):
            presence?.hold(.act)
            await presence?.press()
            let ok = await run(["op": "click", "ref": ref])
            return Result(ok: ok, message: ok ? "Clic sur \(label(ref))." : "Le clic a échoué.", askedConfirmation: asked)
        case .type(let ref, _, let submit):
            presence?.hold(.write)
            if submit { await presence?.press() }
            let ok = await run(["op": "type", "ref": ref, "value": resolved[0], "submit": submit])
            return Result(ok: ok, message: ok ? "Saisie dans \(label(ref))." : "La saisie a échoué.", askedConfirmation: asked)
        case .select(let ref, _):
            let ok = await run(["op": "select", "ref": ref, "value": resolved[0]])
            return Result(ok: ok, message: ok ? "Choix dans \(label(ref))." : "Option introuvable.", askedConfirmation: asked)
        case .fillForm(let fields):
            var done = 0
            for (index, field) in fields.enumerated() {
                let isSelect = targets[field.ref]?.tag == "select"
                await reveal(field.ref, isSelect ? .select : .type)
                if await run(["op": isSelect ? "select" : "type", "ref": field.ref, "value": resolved[index]]) { done += 1 }
            }
            return Result(ok: done == fields.count, message: "Remplissage de \(done) champ\(done > 1 ? "s" : "") sur \(fields.count).", askedConfirmation: asked)
        }
    }
}
