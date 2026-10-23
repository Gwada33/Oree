// Attend qu'une NOUVELLE fenêtre d'une application apparaisse à l'écran et dit au bout de combien de temps.
//   winwatch <nom de l'application> <délai max en s>   (écrit « prêt », attend une ligne sur l'entrée, puis)  →  {"t": 0.83, "pid": 1234}  (t = -1 si rien n'apparaît)
// Ne demande aucune autorisation : la position et le propriétaire d'une fenêtre sont publics, pas son contenu.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: winwatch <app> <timeout>"); exit(64) }
let app = args[1].folding(options: .diacriticInsensitive, locale: nil).lowercased(), timeout = Double(args[2]) ?? 30

func windows() -> [(pid: Int, width: Double, height: Double)] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
        guard let owner = (w[kCGWindowOwnerName as String] as? String)?.folding(options: .diacriticInsensitive, locale: nil).lowercased(), owner.contains(app),
              (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? Int,
              let b = w[kCGWindowBounds as String] as? [String: Double], let width = b["Width"], let height = b["Height"] else { return nil }
        return (pid, width, height)
    }
}

print("prêt"); fflush(stdout); _ = readLine()                 // le chronomètre démarre quand le script envoie une ligne, juste avant `open`
let already = Set(windows().map(\.pid))
let start = Date()
while Date().timeIntervalSince(start) < timeout {
    if let w = windows().first(where: { !already.contains($0.pid) && $0.width >= 400 && $0.height >= 300 }) {
        print("{\"t\": \(String(format: "%.3f", Date().timeIntervalSince(start))), \"pid\": \(w.pid)}"); exit(0)
    }
    usleep(4000)
}
print("{\"t\": -1, \"pid\": 0}")
