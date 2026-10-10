import AppKit
import SwiftUI
@preconcurrency import Translation
import BrowserCore

/// The only SwiftUI outside Settings: Apple offers no other way to ask the system to download a translation model. A
/// session made in code fails with `notInstalled`; the system's own download sheet only appears for a session handed out by
/// `.translationTask`. The view is invisible, lives for the length of one download, and then removes itself.
@available(macOS 26.4, *)
private struct TranslationDownloadView: View {
    let configuration: TranslationSession.Configuration
    let finished: @MainActor (Error?) -> Void

    var body: some View {
        Color.clear.translationTask(configuration) { session in
            do {
                try await session.prepareTranslation()     // shows the system sheet, returns once the model is installed
                await finished(nil)
            } catch {
                await finished(error)
            }
        }
    }
}

@MainActor
enum TranslationDownload {
    /// Asks the system to install the fast (`lowLatency`) model for `source` → the user's language.
    /// `completion` gets nil on success, or the reason it did not happen (the user cancelled, no network, …).
    static func requestFastModel(source: String, in window: NSWindow, completion: @escaping @MainActor (Error?) -> Void) {
        guard #available(macOS 26.4, *), let content = window.contentView else { return completion(PageTranslator.Failure.failed("macOS 26.4")) }
        let configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: PageTranslator.targetIdentifier),
            preferredStrategy: .lowLatency)
        var host: NSHostingView<TranslationDownloadView>!
        host = NSHostingView(rootView: TranslationDownloadView(configuration: configuration) { error in
            host.removeFromSuperview()
            if let error { Log.tabs.error("Translation model download: \(error.localizedDescription, privacy: .public)") }
            completion(error)
        })
        // Alive and in the window (a task only runs for a view that is on screen), but 1 pt and see-through.
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        host.alphaValue = 0.01
        content.addSubview(host)
    }
}
