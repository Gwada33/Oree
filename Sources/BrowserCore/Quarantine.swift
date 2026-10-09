import Foundation

/// Marks downloaded files with the macOS quarantine attribute, so Gatekeeper
/// checks (and warns about) anything that was fetched from the web — the same
/// thing Safari and Chrome do.
public enum Quarantine {
    /// Applies a "web download" quarantine tag. Failure is non-fatal (the file
    /// is still usable), so it's reported to the caller rather than thrown.
    @discardableResult
    public static func apply(to file: URL, originURL: URL?, agentName: String = "HyperBrowser") -> Bool {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: agentName,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineTimeStampKey as String: Date(),
        ]
        if let originURL { properties[kLSQuarantineDataURLKey as String] = originURL }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var target = file
        do {
            try target.setResourceValues(values)
            return true
        } catch {
            Log.network.error("Could not quarantine download: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public static func isQuarantined(_ file: URL) -> Bool {
        (try? file.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties != nil
    }
}
