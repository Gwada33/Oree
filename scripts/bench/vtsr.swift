// Outil d'essai : l'upscaler d'Apple (VideoToolbox, VTLowLatencySuperResolutionScaler, macOS 26+) sur une image PNG, pour mesurer sa vitesse et sa qualité.
//   swiftc -parse-as-library -O scripts/bench/vtsr.swift -o /tmp/vtsr ; OREE_VTSR=/tmp/vtsr python3 scripts/bench/upscale_check.py
// Les API « ForSpatialScaleFactor » du SDK 27 ne sont pas dans la version bêta de macOS installée : elles ne sont pas utilisées.

import Foundation
import VideoToolbox
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// Usage : vtsr entrée.png sortie.png facteur [images]
@main struct Tool {
    static func main() async {
        let a = CommandLine.arguments
        guard a.count >= 4, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("entrée illisible"); return }
        let scale = Float(a[3]) ?? 2, frames = a.count > 4 ? Int(a[4]) ?? 1 : 1
        let w = image.width, h = image.height
        print("VTLowLatencySuperResolutionScaler supporté:", VTLowLatencySuperResolutionScalerConfiguration.isSupported, "max source:", VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions, "min:", VTLowLatencySuperResolutionScalerConfiguration.minimumDimensions)
        let cfg = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: w, frameHeight: h, scaleFactor: scale)
        print("formats:", cfg.sourcePixelBufferAttributes, cfg.destinationPixelBufferAttributes)
        func buffer(_ attrs: [String: Any], _ width: Int, _ height: Int) -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            var at = attrs; at[kCVPixelBufferWidthKey as String] = width; at[kCVPixelBufferHeightKey as String] = height
            if at[kCVPixelBufferIOSurfacePropertiesKey as String] == nil { at[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] }
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, (attrs[kCVPixelBufferPixelFormatTypeKey as String] as? Int).map { OSType($0) } ?? kCVPixelFormatType_32BGRA, at as CFDictionary, &pb)
            precondition(status == kCVReturnSuccess, "CVPixelBufferCreate \\(status)")
            return pb!
        }
        let srcBuf = buffer(cfg.sourcePixelBufferAttributes, w, h)
        let ow = Int(Float(w) * scale), oh = Int(Float(h) * scale)
        let dstBuf = buffer(cfg.destinationPixelBufferAttributes, ow, oh)
        // Image → tampon source
        let ci = CIContext()
        ci.render(CIImage(cgImage: image), to: srcBuf)
        if frames == 0 {   // aller-retour sans traitement : mesure ce que la conversion d'espace colorimétrique (RGB → YUV 4:2:0 → RGB) coûte à elle seule
            try? ci.writePNGRepresentation(of: CIImage(cvPixelBuffer: srcBuf), to: URL(fileURLWithPath: a[2]), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return
        }
        let processor = VTFrameProcessor()
        do { try processor.startSession(configuration: cfg) } catch { print("startSession:", error); return }
        guard let s = VTFrameProcessorFrame(buffer: srcBuf, presentationTimeStamp: .zero), let d = VTFrameProcessorFrame(buffer: dstBuf, presentationTimeStamp: .zero) else { print("cadres"); return }
        let params = VTLowLatencySuperResolutionScalerParameters(sourceFrame: s, destinationFrame: d)
        do {
            _ = try await processor.process(parameters: params)           // chauffe
            let t0 = Date()
            for _ in 0..<frames { _ = try await processor.process(parameters: params) }
            let ms = Date().timeIntervalSince(t0) * 1000 / Double(frames)
            print(String(format: "%dx%d → %dx%d : %.1f ms/image (%.0f images/s)", w, h, ow, oh, ms, 1000 / ms))
        } catch { print("process:", error); return }
        let out = CIImage(cvPixelBuffer: dstBuf)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        try? ci.writePNGRepresentation(of: out, to: URL(fileURLWithPath: a[2]), format: .RGBA8, colorSpace: cs)
        processor.endSession()
    }
}
