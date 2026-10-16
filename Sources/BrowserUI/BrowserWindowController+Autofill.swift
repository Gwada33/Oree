import AppKit
import WebKit
import BrowserCore
import BrowserStorage

/// Remplissage automatique des adresses et des cartes : un menu s'ouvre juste sous le champ où l'on vient de cliquer (comme les autres navigateurs), le choix remplit le formulaire.
/// Les cartes demandent Touch ID. Le code de sécurité n'est jamais gardé. Rien ne part ailleurs que dans la page où l'on a choisi de remplir.
extension BrowserWindowController {
    // MARK: Menu sous le champ

    func offerAutofillMenu(kind: String, body: [String: Any], tab: Tab, webView: WKWebView) async {
        guard webView.url?.scheme == "https" || webView.url?.host == "localhost" || webView.url?.host == "127.0.0.1" else { return }     // jamais sur une page non sécurisée
        let menu = NSMenu(title: kind)
        if kind == "address" {
            let addresses = (try? autofillStore.addresses()) ?? []
            guard !addresses.isEmpty else { return }
            for address in addresses {
                let title = [address.label.isEmpty ? address.fullName : address.label, address.summary].filter { !$0.isEmpty }.joined(separator: " — ")
                menu.addItem(ClosureMenuItem(title: title) { [weak self, weak webView] in
                    guard let webView else { return }
                    Task { @MainActor in await self?.fill(kind: "address", tokens: address.tokens, in: webView) }
                })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Gérer les adresses…") { [weak self] in self?.openAutofillSettings() })
        } else {
            let cards = (try? autofillStore.cards()) ?? []
            guard !cards.isEmpty else { return }
            for card in cards {
                let expired = card.expMonth > 0 && CardTools.isExpired(month: card.expMonth, year: card.expYear)
                menu.addItem(ClosureMenuItem(title: (card.label.isEmpty ? "" : card.label + " · ") + card.summary + (expired ? " (expirée)" : "")) { [weak self, weak webView] in
                    guard let webView else { return }
                    Task { @MainActor in
                        guard await VaultUnlocker.shared.authenticate(reason: "Remplir la carte \(card.masked)") else { return }
                        await self?.fill(kind: "card", tokens: card.tokens, in: webView)
                    }
                })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Gérer les cartes…") { [weak self] in self?.openAutofillSettings() })
        }
        let x = (body["x"] as? Double ?? 0), y = (body["y"] as? Double ?? 0)
        let zoom = max(webView.pageZoom, 0.1)
        let point = NSPoint(x: x * zoom, y: webView.isFlipped ? y * zoom + 2 : webView.bounds.height - y * zoom - 2)
        menu.popUp(positioning: nil, at: point, in: webView)
    }

    func fill(kind: String, tokens: [String: String], in webView: WKWebView) async {
        _ = await webView.safeCall("return window.__hbFillForm(kind, values);", arguments: ["kind": kind, "values": tokens], world: .page)
    }

    func openAutofillSettings() {
        openSettings()
        NotificationCenter.default.post(name: Notification.Name("Oree.selectSettingsCategory"), object: "passwords")
    }

    // MARK: Proposer d'enregistrer

    /// Les valeurs d'un formulaire envoyé → une adresse (le nom « Ana Dupont » seul est coupé en prénom et nom).
    static func addressProfile(from values: [String: String]) -> AddressProfile {
        var a = AddressProfile()
        a.firstName = values["given-name"] ?? ""; a.lastName = values["family-name"] ?? ""
        if a.firstName.isEmpty, a.lastName.isEmpty, let full = values["name"] {
            let parts = full.split(separator: " ", maxSplits: 1).map(String.init)
            a.firstName = parts.first ?? ""; a.lastName = parts.count > 1 ? parts[1] : ""
        }
        a.organization = values["organization"] ?? ""; a.email = values["email"] ?? ""; a.phone = values["tel"] ?? values["tel-national"] ?? ""
        let lines = (values["street-address"] ?? "").split(separator: "\n").map(String.init)
        a.street = values["address-line1"] ?? lines.first ?? ""
        a.street2 = values["address-line2"] ?? (lines.count > 1 ? lines[1] : "")
        a.postalCode = values["postal-code"] ?? ""; a.city = values["address-level2"] ?? ""; a.region = values["address-level1"] ?? ""
        a.country = values["country-name"] ?? values["country"] ?? ""
        a.label = a.city.isEmpty ? (a.fullName.isEmpty ? "Adresse" : a.fullName) : a.city
        return a
    }

    static func sameAddress(_ a: AddressProfile, _ b: AddressProfile) -> Bool {
        func n(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber } }
        return n(a.street) == n(b.street) && n(a.postalCode) == n(b.postalCode)
    }

    func offerToSaveAddress(_ values: [String: String]) async {
        guard let window, !credentialPromptInFlight else { return }
        let candidate = Self.addressProfile(from: values)
        guard !candidate.street.isEmpty, !declinedSaves.contains("addr:" + candidate.street) else { return }
        if let known = try? autofillStore.addresses(), known.contains(where: { Self.sameAddress($0, candidate) }) { return }
        credentialPromptInFlight = true; defer { credentialPromptInFlight = false }
        let alert = NSAlert()
        alert.messageText = "Enregistrer cette adresse ?"
        alert.informativeText = [candidate.fullName, candidate.summary].filter { !$0.isEmpty }.joined(separator: "\n") + "\n\nElle sera chiffrée sur ce Mac et proposée dans les prochains formulaires."
        alert.addButton(withTitle: "Enregistrer"); alert.addButton(withTitle: "Pas maintenant")
        let response: NSApplication.ModalResponse = await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0) } }
        guard response == .alertFirstButtonReturn else { declinedSaves.insert("addr:" + candidate.street); return }
        try? autofillStore.save(candidate)
    }

    func offerToSaveCard(_ values: [String: String]) async {
        guard let window, !credentialPromptInFlight else { return }
        let number = CardTools.digits(values["cc-number"] ?? "")
        guard CardTools.isValid(number), !declinedSaves.contains("card:" + number.suffix(4)) else { return }       // un numéro faux ou une faute de frappe : rien
        var card = CardProfile(); card.number = number; card.holder = values["cc-name"] ?? ""
        if let month = values["cc-exp-month"].flatMap({ Int($0.filter(\.isNumber)) }), let year = values["cc-exp-year"].flatMap({ Int($0.filter(\.isNumber)) }), (1...12).contains(month) {
            card.expMonth = month; card.expYear = year < 100 ? 2000 + year : year
        } else if let exp = values["cc-exp"].flatMap(CardTools.parseExpiry) { card.expMonth = exp.month; card.expYear = exp.year }
        if let known = try? autofillStore.cards(), known.contains(where: { CardTools.digits($0.number) == number }) { return }
        card.label = card.brand
        credentialPromptInFlight = true; defer { credentialPromptInFlight = false }
        let alert = NSAlert()
        alert.messageText = "Enregistrer cette carte ?"
        alert.informativeText = "\(card.summary)\n\nElle sera chiffrée sur ce Mac et protégée par Touch ID au remplissage. Le code de sécurité (CVC) n'est jamais enregistré."
        alert.addButton(withTitle: "Enregistrer"); alert.addButton(withTitle: "Pas maintenant")
        let response: NSApplication.ModalResponse = await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0) } }
        guard response == .alertFirstButtonReturn else { declinedSaves.insert("card:" + number.suffix(4)); return }
        try? autofillStore.save(card)
    }
}
