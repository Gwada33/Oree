import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Compresses tab snapshots to HEIC so a suspended tab's "last known look"
/// costs a few tens of KB instead of megabytes of raw bitmap — the whole
/// point of suspending a tab is to free memory, so the snapshot shouldn't
/// quietly spend it back.
enum HEICSnapshotCodec {
    static func encode(_ image: NSImage, quality: CGFloat = 0.5) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func decode(_ data: Data) -> NSImage? {
        NSImage(data: data)
    }
}
