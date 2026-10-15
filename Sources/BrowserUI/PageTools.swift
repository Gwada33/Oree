import AppKit
import PDFKit
import WebKit
import BrowserCore

/// Everyday page commands that every browser has: print, save as PDF, view the page's source.
extension BrowserWindowController {
    // MARK: Print

    /// ⌘P — the system print panel as a sheet on the window, for the page in the active tab.
    @objc func printPage() {
        guard let web = activeTab?.webView, let window else { NSSound.beep(); return }
        let operation = web.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = web.bounds          // WebKit prints nothing for a view without a frame
        operation.jobTitle = activeTab?.displayTitle ?? "Page"
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Save as PDF

    /// ⇧⌘S — the page as a PDF cut into pages of the window's width, saved where the user chooses.
    @objc func savePageAsPDF() {
        guard let web = activeTab?.webView, let window else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = PageToolsPolicy.pdfFileName(title: activeTab?.displayTitle, host: web.url?.host)
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.showToolNotice("Création du PDF… (une longue page peut prendre une minute)")
                guard let data = await self?.makePDF(of: web) else { self?.showToolNotice("Impossible de créer le PDF de cette page."); return }
                do { try data.write(to: url, options: .atomic); self?.showToolNotice("PDF enregistré.") } catch { self?.showToolNotice("Impossible d’écrire le fichier : \(error.localizedDescription)") }
            }
        }
    }

    /// The page as a PDF made of slices. One single page as tall as the whole page (what `createPDF` does by default) comes out blank on a
    /// long page, and a print operation run without a panel never stops writing pages: so ask for slices and stitch them with PDFKit.
    func makePDF(of web: WKWebView) async -> Data? {
        guard let reply = await web.safeEvaluate("[document.documentElement.scrollWidth, document.documentElement.scrollHeight]", world: .page) as? [NSNumber], reply.count == 2 else { return nil }
        let size = CGSize(width: CGFloat(truncating: reply[0]), height: CGFloat(truncating: reply[1]))
        let slices = PageToolsPolicy.pdfSlices(contentHeight: Double(size.height), sliceHeight: 2400, maxSlices: 40)
        let document = PDFDocument()
        for slice in slices {
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: slice.origin, width: size.width, height: slice.height)
            let data: Data? = await withCheckedContinuation { continuation in
                web.createPDF(configuration: configuration) { result in
                    if case .failure(let error) = result { Log.tabs.error("createPDF failed: \(error.localizedDescription, privacy: .public)") }
                    continuation.resume(returning: try? result.get())
                }
            }
            guard let data, let part = PDFDocument(data: data), let page = part.page(at: 0) else { return nil }
            document.insert(page, at: document.pageCount)
        }
        return document.dataRepresentation()
    }

    // MARK: View source

    /// ⌥⌘U — the page's HTML in a new tab, as text. It is the document as the page has it now (after its scripts ran), which is what
    /// developers usually want; the original bytes from the network are not kept.
    @objc func viewPageSource() {
        guard let tab = activeTab, let web = tab.webView, let address = web.url, address.scheme == "http" || address.scheme == "https" else { NSSound.beep(); return }
        Task { @MainActor [weak self] in
            guard let self, let html = await web.safeEvaluate("document.documentElement.outerHTML", world: .page) as? String else {
                self?.showToolNotice("Impossible de lire le code de cette page."); return
            }
            let page = PageToolsPolicy.sourcePage(html: html, address: address.absoluteString)
            let opened = self.newTab(urlString: nil, isPrivate: tab.isPrivate)
            opened.webView?.loadHTMLString(page, baseURL: nil)
        }
    }

    /// A small message in the notice pill (nothing else to press).
    func showToolNotice(_ message: String) { presentNotice(message) }

    // MARK: Reader mode

    /// ⇧⌘R — the article of the page, alone, in a calm layout; again to come back to the page.
    @objc func toggleReaderMode() {
        guard let tab = activeTab, let web = tab.webView else { NSSound.beep(); return }
        if let origin = tab.readerOrigin {
            tab.readerOrigin = nil
            web.load(URLRequest(url: origin))
            return
        }
        guard let url = web.url, url.scheme == "http" || url.scheme == "https" else { showToolNotice(ReaderPage.notReadableMessage()); return }
        Task { @MainActor [weak self, weak tab, weak web] in
            guard let self, let tab, let web else { return }
            guard let json = await web.safeEvaluate(ReaderScript.extract, world: ReaderScript.world) as? String,
                  let article = ReaderArticle.parse(json, originalURL: url.absoluteString), article.isReadable else {
                self.showToolNotice(ReaderPage.notReadableMessage()); return
            }
            tab.readerOrigin = url
            web.loadHTMLString(ReaderPage.html(article), baseURL: url)
        }
    }

    // MARK: Zoom

    @objc func zoomInAction() { changeZoom { ZoomPolicy.zoomedIn(from: $0) } }
    @objc func zoomOutAction() { changeZoom { ZoomPolicy.zoomedOut(from: $0) } }
    @objc func zoomResetAction() { changeZoom { _ in 1 } }

    /// ⌘+ ⌘− ⌘0: the page is zoomed, and the site keeps that zoom for its next visits.
    private func changeZoom(_ next: (Double) -> Double) {
        guard let web = activeTab?.webView else { NSSound.beep(); return }
        let zoom = next(Double(web.pageZoom))
        web.pageZoom = CGFloat(zoom)
        if let key = ZoomPolicy.key(for: web.url) {
            SettingsStore.shared.siteZoom = ZoomPolicy.updated(SettingsStore.shared.siteZoom, key: key, zoom: zoom)
        }
        presentNotice("Zoom \(ZoomPolicy.label(zoom))")
    }

    /// A page is shown at the zoom its site had last time.
    func applySiteZoom(to web: WKWebView) {
        let zoom = CGFloat(ZoomPolicy.zoom(for: web.url, memory: SettingsStore.shared.siteZoom))
        if web.pageZoom != zoom { web.pageZoom = zoom }
    }
}
