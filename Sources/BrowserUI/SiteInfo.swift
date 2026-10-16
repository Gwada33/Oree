import AppKit
import WebKit
import SecurityInterface
import BrowserStorage
import BrowserCore

/// The popover under the address bar's lock.
extension BrowserWindowController {
    func showSiteInfo() {
        journalPanel("site", open: true)
        if let popover = siteInfoPopover, popover.isShown { popover.close(); return }
        guard let tab = activeTab, let web = tab.webView, let url = web.url, let host = url.host else { return }
        var content = SiteInfoContent(host: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host, connection: SiteInfoPolicy.connection(for: url))

        if url.scheme == "https", let trust = web.serverTrust {
            let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
            if let leaf = chain.first {
                content.certificate.append(.init(label: "Certificat émis pour", value: (SecCertificateCopySubjectSummary(leaf) as String?) ?? host))
                if chain.count > 1 { content.certificate.append(.init(label: "Émis par", value: (SecCertificateCopySubjectSummary(chain[1]) as String?) ?? "—")) }
                if let expiry = Self.expiryDate(of: leaf) { content.certificate.append(.init(label: "Validité", value: SiteInfoPolicy.validity(until: expiry))) }
                content.showCertificate = { [weak self] in
                    guard let window = self?.window else { return }
                    SFCertificatePanel.shared().beginSheet(for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, certificates: chain, showGroup: true)
                }
            }
        }

        if let origin = SiteInfoPolicy.origin(for: url) {
            for kind in SitePermission.allCases {
                guard let stored = try? permissionRepo.decision(origin: origin, permission: kind) else { continue }
                let name: String
                switch kind { case .camera: name = "Caméra"; case .microphone: name = "Micro"; case .location: name = "Position" }
                content.permissions.append(.init(name: name, allowed: stored.decision == .allow, reset: { [weak self] in
                    try? self?.permissionRepo.reset(origin: origin, permission: kind)
                    self?.siteInfoPopover?.close()
                }))
            }
        }

        let dataStore = web.configuration.websiteDataStore
        dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self else { return }
                content.cookieCount = cookies.filter { SiteInfoPolicy.cookieDomain($0.domain, belongsTo: host) }.count
                content.dataSiteName = content.host
                content.clearData = { [weak self, weak web] in
                    guard let web else { return }
                    let types = WKWebsiteDataStore.allWebsiteDataTypes()
                    dataStore.fetchDataRecords(ofTypes: types) { records in
                        let mine = records.filter { SiteInfoPolicy.cookieDomain($0.displayName, belongsTo: host) }
                        dataStore.removeData(ofTypes: types, for: mine) {
                            Task { @MainActor in
                                self?.siteInfoPopover?.close()
                                web.reload()
                                self?.presentNotice("Données de \(content.host) effacées.")
                            }
                        }
                    }
                }
                self.presentSiteInfo(content)
            }
        }
    }

    private func presentSiteInfo(_ content: SiteInfoContent) {
        let view = SiteInfoView(content)
        let controller = NSViewController()
        controller.view = view
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        guard showPopoverSafely(popover, relativeTo: addressPill) else { return }
        siteInfoPopover = popover
    }

    private static func expiryDate(of certificate: SecCertificate) -> Date? {
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any], let raw = entry[kSecPropertyKeyValue as String] else { return nil }
        if let date = raw as? Date { return date }
        if let seconds = raw as? NSNumber { return Date(timeIntervalSinceReferenceDate: seconds.doubleValue) }
        return nil
    }
}
