import AppKit
import WebKit
import BrowserCore

/// Copier les médias d'une page, ou la page entière, et ouvrir l'inspecteur depuis le menu du clic droit.
extension OreeWebView {
    /// Images, vidéos et sons de la page : balises, `<source>`, affiches de vidéo et images de fond CSS (adresses seulement).
    private static let collectScript = """
    (function () {
      var out = [];
      function add(u, k) { if (u) out.push({ url: String(u), kind: k }); }
      document.querySelectorAll('img').forEach(function (e) { add(e.currentSrc || e.src, 'image'); });
      document.querySelectorAll('picture source').forEach(function (e) { add((e.srcset || '').split(',')[0].trim().split(' ')[0], 'image'); });
      document.querySelectorAll('video').forEach(function (e) { add(e.currentSrc || e.src, 'video'); add(e.poster, 'image'); });
      document.querySelectorAll('video source').forEach(function (e) { add(e.src, 'video'); });
      document.querySelectorAll('audio').forEach(function (e) { add(e.currentSrc || e.src, 'audio'); });
      document.querySelectorAll('audio source').forEach(function (e) { add(e.src, 'audio'); });
      var all = document.querySelectorAll('body *'), n = Math.min(all.length, 4000);
      for (var i = 0; i < n; i++) {
        var bg = getComputedStyle(all[i]).backgroundImage;
        if (bg && bg !== 'none') { var re = /url\\(["']?([^"')]+)["']?\\)/g, m; while ((m = re.exec(bg))) add(m[1], 'image'); }
      }
      return JSON.stringify(out);
    })()
    """

    func pageMedia() async -> [PageMedia] {
        guard let json = await safeEvaluate(Self.collectScript, world: .page) as? String else { return [] }
        return MediaCollector.parse(json: json, base: url)
    }

    func copyMediaAddresses() {
        Task { @MainActor in
            let media = await pageMedia()
            guard !media.isEmpty else { tab?.owner?.noticePill.show(message: "Aucun média trouvé sur cette page", button: "OK", seconds: 4) {}; return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(media.map(\.url.absoluteString).joined(separator: "\n"), forType: .string)
            tab?.owner?.noticePill.show(message: "\(media.count) adresses de médias copiées", button: "OK", seconds: 4) {}
        }
    }

    /// Télécharge tous les médias dans un dossier « Médias — site » et met les fichiers sur le presse-papiers : ⌘V les colle dans le Finder.
    func copyAllMedia() {
        let owner = tab?.owner
        let isPrivate = tab?.isPrivate ?? false
        Task { @MainActor in
            let media = await pageMedia()
            guard !media.isEmpty else { owner?.noticePill.show(message: "Aucun média trouvé sur cette page", button: "OK", seconds: 4) {}; return }
            owner?.noticePill.show(message: "Copie de \(media.count) médias…", button: "OK", seconds: 30) {}
            let site = (url?.host ?? "page").replacingOccurrences(of: "www.", with: "")
            // Les essais fixent HB_DOWNLOAD_DIR pour ne rien déposer dans le vrai dossier Téléchargements.
            let root = ProcessInfo.processInfo.environment["HB_DOWNLOAD_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let folder = root.appendingPathComponent("Médias — \(site)", isDirectory: true)
            let referer = url?.absoluteString
            // Un téléchargement ordinaire (et éphémère en navigation privée) : pas de cookies partagés ni de cache sur disque.
            let session = URLSession(configuration: isPrivate ? .ephemeral : .default)
            let saved = await Task.detached { await Self.download(media, into: folder, referer: referer, session: session) }.value
            guard !saved.isEmpty else { owner?.noticePill.show(message: "Aucun média n'a pu être copié", button: "OK", seconds: 6) {}; return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(saved as [NSURL])
            let failed = media.count - saved.count
            owner?.noticePill.show(message: "\(saved.count) médias copiés" + (failed > 0 ? " (\(failed) échecs)" : ""), button: "Afficher") {
                NSWorkspace.shared.activateFileViewerSelecting(saved)
            }
        }
    }

    nonisolated private static func download(_ media: [PageMedia], into folder: URL, referer: String?, session: URLSession) async -> [URL] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = MediaCollector.fileNames(for: media)
        var saved: [URL] = []
        for (item, name) in zip(media, names) {
            var request = URLRequest(url: item.url, timeoutInterval: 30)
            if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true, !data.isEmpty else { continue }
            let target = folder.appendingPathComponent(name)
            if (try? data.write(to: target, options: .atomic)) != nil { saved.append(target) }
        }
        return saved
    }

    /// La page entière, de haut en bas, en PDF + image sur le presse-papiers (coller dans Aperçu, Notes, Mail, Pages).
    func copyWholePage() {
        let owner = tab?.owner
        Task { @MainActor in
            let size = await safeEvaluate("JSON.stringify([document.documentElement.scrollWidth, document.documentElement.scrollHeight])", world: .page) as? String
            let dims = size.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Double] } ?? []
            let width = max(dims.first ?? bounds.width, 1), height = min(max(dims.last ?? bounds.height, 1), 20_000)
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
            guard let pdfData = try? await pdf(configuration: configuration) else {
                owner?.noticePill.show(message: "La page n'a pas pu être copiée", button: "OK", seconds: 5) {}; return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(pdfData, forType: .pdf)
            if let image = NSImage(data: pdfData), let tiff = image.tiffRepresentation { NSPasteboard.general.setData(tiff, forType: .tiff) }
            owner?.noticePill.show(message: "Page entière copiée", button: "OK", seconds: 4) {}
        }
    }

    /// Ouvre l'inspecteur web de WebKit. Il ne s'attache qu'à une page « inspectable » : on l'autorise pour cet onglet au moment du clic.
    func showInspector() {
        isInspectable = true
        let getter = NSSelectorFromString("_inspector"), show = NSSelectorFromString("show")
        guard responds(to: getter), let inspector = perform(getter)?.takeUnretainedValue() as? NSObject, inspector.responds(to: show) else {
            tab?.owner?.noticePill.show(message: "L'inspecteur n'est pas disponible dans cette version de macOS", button: "OK", seconds: 5) {}
            return
        }
        inspector.perform(show)
    }
}
