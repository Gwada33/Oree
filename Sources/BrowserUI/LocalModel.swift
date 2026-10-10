import Foundation
import FoundationModels

/// The system's on-device language model (Apple Intelligence), used for features that read a page: nothing leaves the Mac.
/// macOS 26 or later, and only when Apple Intelligence is on; every caller must cope with `isAvailable == false`.
@MainActor
enum LocalModel {
    enum Failure: Error, Equatable {
        case unavailable(String)
        case timedOut
        case failed(String)
    }

    static var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Why the model cannot be used, in words for the user; nil when it can.
    static var unavailableReason: String? {
        guard #available(macOS 26.0, *) else { return "macOS 26 ou plus est nécessaire." }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "Ce Mac ne prend pas en charge Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence n'est pas activée (Réglages Système)."
        case .unavailable(.modelNotReady): return "Le modèle est encore en cours de téléchargement."
        case .unavailable: return "Le modèle local n'est pas disponible."
        }
    }

    /// One question, one answer. `seconds` bounds the wait: the model has been seen to take a long time on first use.
    static func respond(instructions: String, prompt: String, seconds: Double = 60) async throws -> String {
        guard #available(macOS 26.0, *) else { throw Failure.unavailable("macOS 26") }
        if let reason = unavailableReason { throw Failure.unavailable(reason) }
        let session = LanguageModelSession(instructions: instructions)
        let work = Task { try await session.respond(to: prompt).content }
        var timedOut = false
        let timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { timedOut = true; work.cancel() }
        }
        defer { timer.cancel() }
        do { return try await work.value }
        catch { throw timedOut ? Failure.timedOut : Failure.failed("\(error)") }
    }
}
