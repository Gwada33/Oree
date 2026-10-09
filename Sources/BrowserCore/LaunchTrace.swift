import Foundation
import Darwin

/// Logs how long each launch stage takes, measured from when the OS created the
/// process (so it includes loading frameworks before `main`). Enabled by
/// `HB_LAUNCH_TRACE=1`; costs nothing otherwise.
public enum LaunchTrace {
    private static let enabled = ProcessInfo.processInfo.environment["HB_LAUNCH_TRACE"] == "1"

    private static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }()

    public static func mark(_ stage: String) {
        guard enabled, let start = processStart else { return }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        Log.tabs.notice("launch +\(ms)ms \(stage, privacy: .public)")
    }
}
