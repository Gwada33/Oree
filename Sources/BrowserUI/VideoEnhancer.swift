import AppKit
import AVFoundation
import VideoToolbox
import CoreImage
import ImageIO
import WebKit
import BrowserCore

/// L'upscaler d'Apple (`VTLowLatencySuperResolutionScaler`, macOS 26+, apprentissage, temps réel) appliqué à la vidéo d'une page : le script de la page envoie chaque image en JPEG,
/// ce moteur l'agrandit ×2 (mesuré : 2,7 ms pour 960×540 → 1920×1080 sur un M1), et `VideoEnhancer` l'affiche dans une vue native posée sur la vidéo.
/// Taille de source permise par l'API : de 96×96 à 1280×1280.
struct VideoFrameInfo: Sendable {
    var x = 0.0, y = 0.0, w = 0.0, h = 0.0       // l'emplacement de la vidéo dans la fenêtre d'affichage de la page, en pixels CSS
    var sourceW = 0, sourceH = 0, sent = 0.0     // taille d'origine, et l'instant d'envoi par la page (ms depuis 1970) pour mesurer le délai
    init(_ body: [String: Any]) {
        func number(_ key: String) -> Double { (body[key] as? NSNumber)?.doubleValue ?? 0 }
        x = number("x"); y = number("y"); w = number("w"); h = number("h"); sourceW = Int(number("vw")); sourceH = Int(number("vh")); sent = number("sent")
    }
}

@available(macOS 26.0, *)
actor SuperResolutionEngine {
    struct Output: @unchecked Sendable { var buffer: CVPixelBuffer; var width: Int; var height: Int; var decodeMs: Double; var processMs: Double; var info: VideoFrameInfo }

    nonisolated static var isSupported: Bool { VTLowLatencySuperResolutionScalerConfiguration.isSupported }
    nonisolated static func accepts(width: Int, height: Int) -> Bool {
        guard isSupported, let low = VTLowLatencySuperResolutionScalerConfiguration.minimumDimensions, let high = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions else { return false }
        return width >= Int(low.width) && height >= Int(low.height) && width <= Int(high.width) && height <= Int(high.height)
    }

    private let context = CIContext()
    private var processor: VTFrameProcessor?
    private var configuration: VTLowLatencySuperResolutionScalerConfiguration?
    private var sourceBuffer: CVPixelBuffer?
    private var destinations: [CVPixelBuffer] = []            // trois tampons de sortie en rotation : celui que l'écran lit n'est jamais réécrit
    private var next = 0
    private var size = (width: 0, height: 0)
    private var pending: (data: Data, info: VideoFrameInfo)?
    private var running = false
    private(set) var framesIn = 0, framesOut = 0, framesDropped = 0
    private(set) var failure: String?
    var onOutput: (@Sendable (Output) -> Void)?
    func setOutput(_ handler: @escaping @Sendable (Output) -> Void) { onOutput = handler }

    /// Une image à traiter ; si le moteur est encore occupé, la précédente en attente est abandonnée (l'écran préfère la plus récente).
    func submit(jpeg: Data, info: VideoFrameInfo) {
        framesIn += 1
        if pending != nil { framesDropped += 1 }
        pending = (jpeg, info)
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    private func drain() async {
        while let job = pending {
            pending = nil
            await handle(job.data, info: job.info)
        }
        running = false
    }

    private func makeBuffer(_ attributes: [String: Any], width: Int, height: Int) -> CVPixelBuffer? {
        var attrs = attributes; attrs[kCVPixelBufferWidthKey as String] = width; attrs[kCVPixelBufferHeightKey as String] = height
        if attrs[kCVPixelBufferIOSurfacePropertiesKey as String] == nil { attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] }
        var buffer: CVPixelBuffer?
        let format = (attributes[kCVPixelBufferPixelFormatTypeKey as String] as? Int).map { OSType($0) } ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }

    private func startSession(width: Int, height: Int) -> Bool {
        processor?.endSession(); processor = nil
        let cfg = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: 2)
        let processor = VTFrameProcessor()
        do { try processor.startSession(configuration: cfg) } catch { failure = "session : \(error.localizedDescription)"; return false }
        guard let source = makeBuffer(cfg.sourcePixelBufferAttributes, width: width, height: height) else { failure = "tampon source"; return false }
        let outputs = (0..<3).compactMap { _ in makeBuffer(cfg.destinationPixelBufferAttributes, width: width * 2, height: height * 2) }
        guard outputs.count == 3 else { failure = "tampons de sortie"; return false }
        self.processor = processor; configuration = cfg; sourceBuffer = source; destinations = outputs; size = (width, height); failure = nil
        return true
    }

    private func handle(_ data: Data, info: VideoFrameInfo) async {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { failure = "image illisible"; return }
        let width = image.width, height = image.height
        guard Self.accepts(width: width, height: height) else { failure = "taille \(width)×\(height) non prise en charge"; return }
        if size.width != width || size.height != height || processor == nil { guard startSession(width: width, height: height) else { return } }
        guard let processor, let sourceBuffer else { return }
        context.render(CIImage(cgImage: image), to: sourceBuffer)
        let decoded = DispatchTime.now().uptimeNanoseconds
        let destination = destinations[next % destinations.count]; next += 1
        guard let inFrame = VTFrameProcessorFrame(buffer: sourceBuffer, presentationTimeStamp: .zero), let outFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: .zero) else { failure = "cadres"; return }
        let parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: inFrame, destinationFrame: outFrame)
        do { _ = try await processor.process(parameters: parameters) } catch { failure = "traitement : \(error.localizedDescription)"; return }
        let done = DispatchTime.now().uptimeNanoseconds
        framesOut += 1; failure = nil
        onOutput?(Output(buffer: destination, width: width * 2, height: height * 2, decodeMs: Double(decoded - t0) / 1e6, processMs: Double(done - decoded) / 1e6, info: info))
    }

    func reset() { processor?.endSession(); processor = nil; pending = nil; size = (0, 0) }
    var report: String { "in=\(framesIn) out=\(framesOut) perdues=\(framesDropped)\(failure.map { " échec=\($0)" } ?? "")" }
}

/// Disponibilité sans erreur de version : l'upscaler d'Apple demande macOS 26.
enum SuperResolution {
    static var isSupported: Bool { if #available(macOS 26.0, *) { return SuperResolutionEngine.isSupported } else { return false } }
    static func accepts(width: Int, height: Int) -> Bool { if #available(macOS 26.0, *) { return SuperResolutionEngine.accepts(width: width, height: height) } else { return false } }
}

/// La vue qui montre les images agrandies par-dessus la vidéo de la page (jamais dans la page), sans prendre la souris.
@MainActor
final class VideoEnhancer {
    let overlay = EnhancerView()
    private var engineBox: AnyObject?
    private weak var web: WKWebView?
    private var lastShown = Date.distantPast
    private var watchdog: Timer?
    private(set) var latencies: [Double] = [], processTimes: [Double] = [], decodeTimes: [Double] = []
    private(set) var lastOutput: CVPixelBuffer?
    private(set) var lastRect = NSRect.zero
    var onFailure: ((String) -> Void)?

    @available(macOS 26.0, *) private var engine: SuperResolutionEngine { engineBox as! SuperResolutionEngine }

    init(web: WKWebView) {
        self.web = web
        if #available(macOS 26.0, *) {
            let engine = SuperResolutionEngine(); engineBox = engine
            Task { await engine.setOutput { [weak self] output in Task { @MainActor in self?.show(output) } } }
        }
    }

    /// Une image du script : ses rectangles (pixels CSS de la fenêtre d'affichage de la page) et le JPEG en base64.
    #if DEBUG
    private var lastBody: [String: Any]?
    private var feeder: Task<Void, Never>?
    /// Dev (debug seulement) : rejoue la dernière image reçue `count` fois à `fps` images/s, comme si la page l'envoyait : mesure la chaîne native (décodage, agrandissement, affichage)
    /// sans dépendre d'une page visible (une fenêtre d'essai cachée freine ses minuteurs).
    func feed(count: Int, fps: Double) {
        guard let body = lastBody else { return }
        feeder?.cancel()
        feeder = Task { @MainActor [weak self] in
            for _ in 0..<count {
                guard let self, !Task.isCancelled else { return }
                var copy = body; copy["sent"] = Date().timeIntervalSince1970 * 1000; self.receive(copy)
                try? await Task.sleep(for: .seconds(1 / fps))
            }
        }
    }
    func resetStats() { latencies = []; processTimes = []; decodeTimes = [] }
    #endif

    func receive(_ body: [String: Any]) {
        #if DEBUG
        lastBody = body
        #endif
        guard let base64 = body["jpeg"] as? String, let data = Data(base64Encoded: base64) else { return }
        let info = VideoFrameInfo(body)
        let width = info.sourceW, height = info.sourceH
        guard #available(macOS 26.0, *) else { onFailure?("macOS 26 requis"); return }
        if !SuperResolutionEngine.accepts(width: width, height: height) { onFailure?("taille \(width)×\(height) non prise en charge"); return }
        let engine = engine
        Task { await engine.submit(jpeg: data, info: info) }
        startWatchdog()
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil; overlay.hideNow()
        if #available(macOS 26.0, *) { let engine = engine; Task { await engine.reset() } }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        // Si plus aucune image n'arrive (pause, onglet caché, script arrêté), la vidéo d'origine reprend la place : une image figée ne doit jamais recouvrir une vidéo qui bouge.
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; if Date().timeIntervalSince(self.lastShown) > 0.3 { self.overlay.hideNow() } }
        }
    }

    @available(macOS 26.0, *)
    private func show(_ output: SuperResolutionEngine.Output) {
        let (x, y, w, h) = (output.info.x, output.info.y, output.info.w, output.info.h)
        guard let web, w > 1, h > 1 else { return }
        let zoom = max(web.pageZoom, 0.1)
        let inWeb = NSRect(x: x * zoom, y: web.isFlipped ? y * zoom : web.bounds.height - (y + h) * zoom, width: w * zoom, height: h * zoom)
        let target = overlay.convert(web.convert(inWeb, to: nil), from: nil)
        overlay.present(output.buffer, frame: target)
        lastRect = target
        lastShown = Date(); lastOutput = output.buffer
        if output.info.sent > 0 { latencies.append(Date().timeIntervalSince1970 * 1000 - output.info.sent); if latencies.count > 300 { latencies.removeFirst() } }
        processTimes.append(output.processMs); decodeTimes.append(output.decodeMs)
        if processTimes.count > 300 { processTimes.removeFirst(); decodeTimes.removeFirst() }
    }

    func report() async -> String {
        guard #available(macOS 26.0, *) else { return "macOS 26 requis" }
        func mean(_ a: [Double]) -> String { a.isEmpty ? "-" : String(format: "%.1f", a.reduce(0, +) / Double(a.count)) }
        return "\(await engine.report) latence_ms=\(mean(latencies)) agrandissement_ms=\(mean(processTimes)) décodage_ms=\(mean(decodeTimes)) visible=\(!overlay.isHidden) rect=\(Int(lastRect.minX)),\(Int(lastRect.minY)),\(Int(lastRect.width))x\(Int(lastRect.height))"
    }

    /// Dev (debug) : la dernière image agrandie en PNG, pour mesurer sa netteté.
    func dumpLast(to path: String) -> Bool {
        guard let buffer = lastOutput else { return false }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        return (try? CIContext().writePNGRepresentation(of: image, to: URL(fileURLWithPath: path), format: .RGBA8, colorSpace: colorSpace)) != nil
    }
}

/// Une couche d'affichage vidéo au-dessus de la page ; les clics la traversent.
@MainActor
final class EnhancerView: NSView {
    private let display = AVSampleBufferDisplayLayer()
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; isHidden = true
        display.videoGravity = .resize
        display.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(display)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(_ buffer: CVPixelBuffer, frame: NSRect) {
        isHidden = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        display.frame = frame
        CATransaction.commit()
        // Les tampons de l'upscaler sont en BT.709 : on le précise pour que les couleurs soient celles de la vidéo.
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if display.sampleBufferRenderer.status == .failed { display.sampleBufferRenderer.flush() }
        display.sampleBufferRenderer.enqueue(sample)
    }

    func hideNow() { if !isHidden { isHidden = true; display.sampleBufferRenderer.flush() } }
}
