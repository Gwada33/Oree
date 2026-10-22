import AVFoundation
import BrowserCore

/// Reads text aloud with the Mac's voices, in short passages. One reading at a time; reading again (or "Arrêter") stops it.
@MainActor
final class PageSpeech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = PageSpeech()
    private let synthesizer = AVSpeechSynthesizer()
    private var remaining = 0
    var onFinish: (() -> Void)?
    var isSpeaking: Bool { synthesizer.isSpeaking || remaining > 0 }
    /// Tests stay silent: HB_SPEECH_MUTED=1 reads at volume 0.
    private let muted = ProcessInfo.processInfo.environment["HB_SPEECH_MUTED"] == "1"

    override init() { super.init(); synthesizer.delegate = self }

    func speak(_ text: String, language: String) {
        stop()
        let passages = SpeechText.chunks(text)
        guard !passages.isEmpty else { onFinish?(); return }
        let voice = AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        remaining = passages.count
        for passage in passages {
            let utterance = AVSpeechUtterance(string: passage)
            utterance.voice = voice
            utterance.volume = muted ? 0 : 1
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        remaining = 0
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { mainActorNow { self.passageEnded() } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { mainActorNow { self.passageEnded() } }
    }

    private func passageEnded() {
        guard remaining > 0 else { return }
        remaining -= 1
        if remaining == 0 { onFinish?() }
    }
}
