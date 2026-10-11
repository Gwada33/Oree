import Foundation
import CryptoKit
import llama
import OreeAIEngine

enum LlamaError: LocalizedError {
    case loadFailed, contextFailed, tokenizeFailed, decodeFailed(Int32), noModel

    var errorDescription: String? {
        switch self {
        case .loadFailed: "llama.cpp n'a pas pu ouvrir le modèle"
        case .contextFailed: "llama.cpp n'a pas pu créer le contexte"
        case .tokenizeFailed: "découpage du texte en jetons impossible"
        case .decodeFailed(let code): "calcul interrompu (code \(code))"
        case .noModel: "aucun modèle chargé"
        }
    }
}

/// Le moteur réel : Qwen3.5-2B via llama.cpp (Metal). Tout passe par une file sérielle : llama.cpp n'est pas thread-safe.
/// Réglages imposés par le contrat : poids en mmap, pénalité de répétition 1.0, réflexion désactivée.
final class LlamaEngine: AIEngine, @unchecked Sendable {
    private let queue = DispatchQueue(label: "oree.ai.llama", qos: .userInitiated)
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var modelURL: URL?
    private var prefixTokens: [llama_token] = []
    private var prefixText = ""
    private var prefixKV: URL?
    private let cacheDirectory: URL
    /// Taille du contexte. Les tâches de l'étape 1 sont courtes ; 4096 jetons suffisent et gardent le cache KV petit.
    private let contextSize: UInt32 = 4096
    private let batchSize: UInt32 = 512

    /// - Parameter cacheDirectory: où écrire le cache KV du prompt système (jetable : il se reconstruit).
    init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
        llama_backend_init()
        if ProcessInfo.processInfo.environment["OREE_AI_LOG"] == nil { llama_log_set({ _, _, _ in }, nil) }   // silence, sauf demande
    }

    // MARK: AIEngine

    func load(modelAt url: URL) async throws {
        try await onQueue {
            var params = llama_model_default_params()
            params.n_gpu_layers = 999
            params.load_mode = LLAMA_LOAD_MODE_MMAP               // poids mappés, pas copiés : l'OS peut les reprendre
            guard let model = llama_model_load_from_file(url.path, params) else { throw LlamaError.loadFailed }
            self.model = model
            self.modelURL = url
        }
    }

    /// Pré-réveil : on mappe le fichier une seconde fois, on demande la lecture anticipée (MADV_WILLNEED), on relâche. Les pages
    /// restent dans le cache disque de l'OS, donc le vrai chargement ou le premier calcul les trouve déjà en mémoire.
    func prewarm(modelAt url: URL) async {
        await onQueueQuietly { Self.adviseWillNeed(url) }
    }

    static func adviseWillNeed(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { return }
        let length = Int(info.st_size)
        guard let address = mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0), address != MAP_FAILED else { return }
        _ = madvise(address, length, MADV_WILLNEED)
        munmap(address, length)
    }

    func startContext(systemPrompt: String) async throws {
        try await onQueue {
            guard let model = self.model else { throw LlamaError.noModel }
            var params = llama_context_default_params()
            params.n_ctx = self.contextSize
            params.n_batch = self.batchSize
            params.n_ubatch = self.batchSize
            let threads = Int32(max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)))
            params.n_threads = threads
            params.n_threads_batch = threads
            guard let context = llama_init_from_model(model, params) else { throw LlamaError.contextFailed }
            self.context = context
            try self.preparePrefix(systemPrompt)
        }
    }

    func stopContext() async {
        await onQueueQuietly {
            if let context = self.context { llama_free(context) }
            self.context = nil
        }
    }

    func unload() async {
        await onQueueQuietly {
            if let context = self.context { llama_free(context) }
            self.context = nil
            if let model = self.model { llama_model_free(model) }
            self.model = nil
        }
    }

    func generate(user: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let cancelled = Flag()
            continuation.onTermination = { _ in cancelled.set() }
            queue.async {
                do {
                    try self.decodeAnswer(user: user, maxTokens: maxTokens, cancelled: cancelled) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: Prompt et cache KV (sur la file llama)

    /// Le prompt système est le début de TOUS les prompts : son calcul (prefill) est fait une fois, puis gardé dans un fichier.
    private func preparePrefix(_ systemPrompt: String) throws {
        guard let model, let context else { throw LlamaError.noModel }
        prefixText = try applyTemplate([("system", systemPrompt)], addAssistant: false)
        prefixTokens = try tokenize(prefixText)
        let key = SHA256.hash(data: Data((modelURL?.lastPathComponent ?? "") .utf8) + Data(prefixText.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let file = cacheDirectory.appendingPathComponent("prefix-\(key).kv")
        prefixKV = file
        _ = model
        if !restorePrefix() {
            try decode(prefixTokens)
            _ = llama_state_seq_save_file(context, file.path, 0, prefixTokens, prefixTokens.count)
        }
    }

    /// Remet le contexte dans l'état « prompt système seulement ». Vrai si le cache KV du disque a pu être relu.
    @discardableResult
    private func restorePrefix() -> Bool {
        guard let context, let file = prefixKV else { return false }
        llama_memory_clear(llama_get_memory(context), true)
        var loaded = 0
        var tokens = [llama_token](repeating: 0, count: prefixTokens.count)
        let bytes = llama_state_seq_load_file(context, file.path, 0, &tokens, tokens.count, &loaded)
        if bytes > 0, loaded == prefixTokens.count, tokens == prefixTokens { return true }
        llama_memory_clear(llama_get_memory(context), true)
        return false
    }

    /// Texte du prompt : le modèle de conversation (chat template) du GGUF fait le travail. Réflexion désactivée : le modèle de Qwen3.5
    /// ajoute lui-même un bloc de réflexion vide après « assistant » quand `enable_thinking` est faux ; llama_chat_apply_template n'exécute pas
    /// le Jinja, donc on ajoute ce bloc vide ici, tel que le modèle l'écrit.
    private func applyTemplate(_ messages: [(role: String, content: String)], addAssistant: Bool) throws -> String {
        let template = model.flatMap { llama_model_chat_template($0, nil) }
        func render(_ template: UnsafePointer<CChar>?) -> String? {
            let roles = messages.map { strdup($0.role) }, contents = messages.map { strdup($0.content) }
            defer { roles.forEach { free($0) }; contents.forEach { free($0) } }
            var chat = (0..<messages.count).map { llama_chat_message(role: UnsafePointer(roles[$0]), content: UnsafePointer(contents[$0])) }
            var capacity = max(1024, messages.reduce(0) { $0 + $1.content.utf8.count + 64 } * 2)
            for _ in 0..<2 {
                var buffer = [CChar](repeating: 0, count: capacity)
                let n = llama_chat_apply_template(template, &chat, chat.count, addAssistant, &buffer, Int32(capacity))
                if n < 0 { return nil }
                if Int(n) <= capacity { return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) }
                capacity = Int(n)
            }
            return nil
        }
        guard let text = render(template) ?? render("chatml") else { throw LlamaError.tokenizeFailed }
        return addAssistant ? text + "<think>\n\n</think>\n\n" : text
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        guard let model else { throw LlamaError.noModel }
        let vocab = llama_model_get_vocab(model)
        let utf8 = Array(text.utf8CString.dropLast())
        var tokens = [llama_token](repeating: 0, count: utf8.count + 16)
        var n = llama_tokenize(vocab, utf8, Int32(utf8.count), &tokens, Int32(tokens.count), false, true)   // pas de jeton spécial ajouté : le modèle de conversation les écrit
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, utf8, Int32(utf8.count), &tokens, Int32(tokens.count), false, true)
        }
        guard n >= 0 else { throw LlamaError.tokenizeFailed }
        return Array(tokens.prefix(Int(n)))
    }

    private func decode(_ tokens: [llama_token]) throws {
        guard let context else { throw LlamaError.noModel }
        var rest = tokens[...]
        while !rest.isEmpty {
            let chunk = Array(rest.prefix(Int(batchSize)))
            rest = rest.dropFirst(chunk.count)
            var chunkCopy = chunk
            let code = chunkCopy.withUnsafeMutableBufferPointer { llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
            if code != 0 { throw LlamaError.decodeFailed(code) }
        }
    }

    private func decodeAnswer(user: String, maxTokens: Int, cancelled: Flag, emit: (String) -> Void) throws {
        guard let model, let context else { throw LlamaError.noModel }
        // 1. Retour au prompt système seul (cache KV), 2. on ajoute la question, 3. on génère jeton par jeton.
        if !restorePrefix() { try decode(prefixTokens) }
        let full = try applyTemplate([("system", AIPrompts.system), ("user", user)], addAssistant: true)
        guard full.hasPrefix(prefixText) else { throw LlamaError.tokenizeFailed }
        let suffix = try tokenize(String(full.dropFirst(prefixText.count)))
        guard prefixTokens.count + suffix.count + maxTokens <= Int(contextSize) else { throw LlamaError.decodeFailed(-1) }
        try decode(suffix)

        let vocab = llama_model_get_vocab(model)
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        // Pénalité de répétition 1.0 (neutre) fixée explicitement, comme le demande le contrat.
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.0, 0, 0))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(20))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.8, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

        var pending: [UInt8] = []                     // un caractère UTF-8 peut être coupé entre deux jetons
        for _ in 0..<maxTokens {
            if cancelled.isSet { return }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            llama_sampler_accept(sampler, token)
            var piece = [CChar](repeating: 0, count: 64)
            let n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 { pending += piece.prefix(Int(n)).map { UInt8(bitPattern: $0) } }
            if let text = Self.completePrefix(&pending) { emit(text) }
            let code = llama_decode(context, llama_batch_get_one(&token, 1))
            if code != 0 { throw LlamaError.decodeFailed(code) }
        }
        if !pending.isEmpty { emit(String(decoding: pending, as: UTF8.self)) }
    }

    /// Retire de `bytes` la plus longue partie qui forme du UTF-8 complet, et la renvoie.
    static func completePrefix(_ bytes: inout [UInt8]) -> String? {
        for cut in 0...min(3, bytes.count) {
            let head = bytes.dropLast(cut)
            if !head.isEmpty, let text = String(bytes: head, encoding: .utf8) {
                bytes = Array(bytes.suffix(cut))
                return text
            }
        }
        return nil
    }

    // MARK: File sérielle

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
    private func onQueueQuietly(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { body(); continuation.resume() }
        }
    }
}

/// Drapeau d'annulation lisible depuis la file llama.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
