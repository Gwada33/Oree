import AppKit
import WebKit
import BrowserCore

/// Mode responsive : la page de l'onglet affiché prend la taille (et l'identité) d'un téléphone, d'une tablette ou d'un écran, pour voir comment un site s'y comporte.
/// Propre à l'onglet : les autres ne bougent pas ; quitter le mode rend la page à la fenêtre et au navigateur de bureau.
extension BrowserWindowController {
    func responsiveActions() -> [(String, String, @MainActor (BrowserWindowController) -> Void)] {
        var items: [(String, String, @MainActor (BrowserWindowController) -> Void)] = []
        for device in ResponsiveDevice.presets {
            let icon = device.kind == .phone ? "iphone" : (device.kind == .tablet ? "ipad" : "laptopcomputer")
            items.append(("Mode responsive : \(device.label)", icon, { controller in if let tab = controller.activeTab { controller.applyResponsive(device, to: tab) } }))
        }
        if activeTab?.responsive != nil {
            items.append(("Pivoter l'appareil (responsive)", "rotate.right", { $0.rotateResponsive() }))
            items.append(("Quitter le mode responsive", "xmark.rectangle", { controller in if let tab = controller.activeTab { controller.applyResponsive(nil, to: tab) } }))
        }
        return items
    }

    func applyResponsive(_ device: ResponsiveDevice?, to tab: Tab, reload: Bool = true) {
        let wasResponsive = tab.responsive != nil
        tab.responsive = device
        for constraint in [tab.slotWidth, tab.slotHeight, tab.slotCenterX] { constraint?.isActive = false }
        tab.slotWidth = nil; tab.slotHeight = nil; tab.slotCenterX = nil
        let slot = tab.contentSlot
        slot.wantsLayer = true
        if let device {
            let room = contentContainer.bounds.size
            let fit = device.fit(in: (Double(room.width), Double(room.height) - Self.responsiveBarHeight))
            tab.slotLeading?.isActive = false; tab.slotTrailing?.isActive = false; tab.slotBottom?.isActive = false
            tab.slotTop?.constant = Self.responsiveBarHeight
            let width = slot.widthAnchor.constraint(equalToConstant: fit.width), height = slot.heightAnchor.constraint(equalToConstant: fit.height)
            let center = slot.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor)
            [width, height, center].forEach { $0.isActive = true }
            tab.slotWidth = width; tab.slotHeight = height; tab.slotCenterX = center
            slot.layer?.cornerRadius = 14; slot.layer?.masksToBounds = true
            slot.layer?.borderWidth = 1; slot.layer?.borderColor = Theme.cg(Theme.line, in: slot)
        } else if wasResponsive {
            tab.slotTop?.constant = 0
            tab.slotLeading?.isActive = true; tab.slotTrailing?.isActive = true; tab.slotBottom?.isActive = true
            slot.layer?.cornerRadius = 0; slot.layer?.masksToBounds = false; slot.layer?.borderWidth = 0
        }
        if let web = tab.webView {
            applyUserAgent(to: web, for: web.url)
            if reload, device != nil || wasResponsive { web.reload() }
        }
        syncResponsiveBar()
        contentContainer.layoutSubtreeIfNeeded()
    }

    func rotateResponsive() {
        guard let tab = activeTab, let device = tab.responsive else { return }
        applyResponsive(device.rotated, to: tab, reload: false)
    }

    static var responsiveBarHeight: Double { 44 }

    /// La barre au-dessus de l'appareil : son nom et sa taille, pivoter, quitter. Visible seulement quand l'onglet affiché est en mode responsive.
    func syncResponsiveBar() {
        guard let device = activeTab?.responsive else { responsiveBar.isHidden = true; return }
        responsiveLabel.stringValue = device.label + (activeTab?.slotWidth.map { Double(device.size.width) > $0.constant } == true ? " (réduit pour tenir)" : "")
        responsiveBar.isHidden = false
    }

    func buildResponsiveBar() {
        responsiveBar.translatesAutoresizingMaskIntoConstraints = false
        responsiveBar.isHidden = true
        responsiveLabel.font = Theme.sans(12.5, .semibold); responsiveLabel.textColor = Theme.text
        let rotate = ChromeIconButton(symbol: "rotate.right", label: "Pivoter l'appareil")
        let close = ChromeIconButton(symbol: "xmark", label: "Quitter le mode responsive")
        rotate.onClick = { [weak self] in self?.rotateResponsive() }
        close.onClick = { [weak self] in if let self, let tab = self.activeTab { self.applyResponsive(nil, to: tab) } }
        let stack = NSStackView(views: [responsiveLabel, rotate, close])
        stack.orientation = .horizontal; stack.spacing = 6; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        responsiveBar.addSubview(stack)
        contentContainer.addSubview(responsiveBar)
        NSLayoutConstraint.activate([
            responsiveBar.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 6), responsiveBar.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            responsiveBar.heightAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: responsiveBar.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: responsiveBar.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: responsiveBar.centerYAnchor),
        ])
    }
}
