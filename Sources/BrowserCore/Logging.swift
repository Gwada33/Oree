import os

/// Central place for the app's `os.Logger` instances, one per subsystem area
/// so Console.app filtering by category actually means something.
public enum Log {
    private static let subsystem = "com.nolhan.hyperbrowser"

    public static let tabs = Logger(subsystem: subsystem, category: "tabs")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let security = Logger(subsystem: subsystem, category: "security")
    public static let importing = Logger(subsystem: subsystem, category: "import")
}
