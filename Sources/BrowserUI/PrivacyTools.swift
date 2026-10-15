import AppKit
import CoreImage
import WebKit
import BrowserCore
import BrowserStorage

/// Small privacy and sharing tools: the Global Privacy Control signal, forgetting data when Orée quits, and the page's QR code.
@MainActor
enum PrivacyTools {
    // MARK: Global Privacy Control

    /// Pages (and their frames) read `navigator.globalPrivacyControl === true`. The matching `Sec-GPC: 1` header is not added to requests:
    /// a web view gives no hook for that without cancelling and replaying every navigation.
    static func gpcUserScript() -> WKUserScript {
        let source = "try { Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', { get() { return true; }, configurable: true }); } catch (_) {}"
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    // MARK: Forgetting data

    /// Cookies, caches, local storage… of every site, in `store`.
    static func clearSiteData(in store: WKWebsiteDataStore) async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// At quit: what the user asked to forget. Bookmarks, passwords and the open tabs are never touched.
    static func clearAtQuit(settings: SettingsStore) async {
        if settings.clearHistoryOnQuit { try? HistoryRepository().clear() }
        if settings.clearSiteDataOnQuit { await clearSiteData(in: .default()) }
    }

    // MARK: QR code

    /// The QR code of `text` as a crisp image (`size` points wide, no blur), or nil if it does not fit in a code.
    static func qrImage(for text: String, size: CGFloat = 220) -> NSImage? {
        guard let data = text.data(using: .utf8), data.count <= 1200, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, floor(size / output.extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))    // whole-number scale: sharp squares
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// What a QR code image says (used to check ours reads back).
    static func decodeQR(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        return (detector.features(in: ci).first as? CIQRCodeFeature)?.messageString
    }
}

extension BrowserWindowController {
    /// At quit: forgets what the user asked to forget (see `Réglages › À la fermeture d'Orée`).
    @MainActor public static func clearAtQuit() async { await PrivacyTools.clearAtQuit(settings: SettingsStore.shared) }
}
