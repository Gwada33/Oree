import Foundation
import CryptoKit
import OreeAIProtocol

/// Le fichier du modèle tel qu'on l'attend : nom, taille et SHA-256 épinglés dans le code.
public struct ModelPin: Sendable, Equatable {
    public var name: String
    public var size: Int64
    public var sha256: String
    /// D'où le télécharger (moteur de téléchargement d'Orée, avec reprise).
    public var url: URL

    public init(name: String, size: Int64, sha256: String, url: URL) {
        self.name = name; self.size = size; self.sha256 = sha256.lowercased(); self.url = url
    }

    /// Qwen3.5-2B, quantification Q4_K_M. Le dépôt officiel Qwen n'a pas de GGUF : conversion de lmstudio-community
    /// (Apache 2.0, base Qwen/Qwen3.5-2B). Taille et somme relevées sur HuggingFace (en-têtes HTTP et empreinte LFS).
    public static let qwen35_2B = ModelPin(
        name: "Qwen3.5-2B-Q4_K_M.gguf",
        size: 1_270_808_032,
        sha256: "0bfe35afc9f05b7fac3fa04925e051ac7939a42a8a17ea11afc99701bea826cc",
        url: URL(string: "https://huggingface.co/lmstudio-community/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf")!)

    /// Qwen3.5-4B, même conversion et même quantification : environ deux fois plus lourd, plus capable. Taille et somme relevées sur HuggingFace.
    public static let qwen35_4B = ModelPin(
        name: "Qwen3.5-4B-Q4_K_M.gguf",
        size: 2_707_513_696,
        sha256: "25082a7dd3776cc3c741c6347d3bd04523f05796607b3fbc32fa3a25dfa1418c",
        url: URL(string: "https://huggingface.co/lmstudio-community/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf")!)

    /// Le modèle que le service charge. Un seul endroit à changer.
    /// 4B depuis le 11 octobre 2026 : le 2B répondait trop souvent à côté (voir Docs/ia-mesures.md). Pour revenir au 2B : `qwen35_2B`.
    public static let `default` = qwen35_4B

    /// Pour les essais en ligne de commande : `--model 2b` ou `--model 4b`.
    public static func named(_ name: String?) -> ModelPin {
        switch name?.lowercased() { case "4b": qwen35_4B; case "2b": qwen35_2B; default: .default }
    }
}

public enum ModelFile {
    /// ~/Library/Application Support/HyperBrowser/Models — le seul endroit où l'IA écrit dans les données d'Orée.
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HyperBrowser/Models", isDirectory: true)
    }

    public static func url(for pin: ModelPin, in directory: URL = ModelFile.directory) -> URL {
        directory.appendingPathComponent(pin.name)
    }

    /// Vérifie le fichier : absent, taille fausse ou somme fausse → pas `.ready`. Bloquant (1,3 Go à lire) : à appeler hors du fil principal.
    /// `progress` reçoit le nombre d'octets lus.
    public static func verify(_ url: URL, against pin: ModelPin, progress: ((Int64) -> Void)? = nil) -> AIModelState {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return .missing }
        guard (attributes[.size] as? NSNumber)?.int64Value == pin.size else { return .corrupt }   // tronqué ou autre fichier : inutile de lire
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .missing }
        defer { try? handle.close() }
        var hasher = SHA256()
        var read: Int64 = 0
        var more = true
        while more {
            // Un bloc à la fois, libéré tout de suite : sans cette réserve locale, les 1,3 Go lus s'accumulent en mémoire jusqu'à la fin.
            more = autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                read += Int64(chunk.count)
                progress?(read)
                return true
            }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == pin.sha256 ? .ready : .corrupt
    }
}
