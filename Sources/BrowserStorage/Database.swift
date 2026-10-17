import Foundation
import GRDB

/// Owns the single `DatabasePool` for the app. `DatabasePool` (as opposed to
/// `DatabaseQueue`) runs in WAL mode and allows concurrent readers while one
/// writer is active — the standard GRDB choice for an app with a UI that
/// keeps reading (address bar suggestions, history list) while writes
/// happen in the background.
///
/// `@unchecked Sendable`: `DatabasePool` is internally synchronized by GRDB;
/// this wrapper adds no further mutable state of its own.
public final class AppDatabase: @unchecked Sendable {
    public static let shared: AppDatabase = {
        do {
            return try AppDatabase()
        } catch {
            // A database that will not open (bad HB_DB_PATH, damaged file, full disk) must not make the app crash at launch
            // (crash report of 12 Oct 19:41): start on a temporary one instead. History of this session is then not kept.
            NSLog("Orée: could not open the database (\(error)); using a temporary one")
            let temporary = NSTemporaryDirectory() + "oree-fallback-\(UUID().uuidString).sqlite"
            do { return try AppDatabase(path: temporary) } catch { fatalError("Could not open any database: \(error)") }
        }
    }()

    public let dbPool: DatabasePool

    /// Tests construct their own instance pointed at a temporary file so
    /// they never touch the real user database.
    public init(path: String? = nil) throws {
        let resolvedPath: String
        if let path {
            resolvedPath = path
        } else if let override = ProcessInfo.processInfo.environment["HB_DB_PATH"] {
            resolvedPath = override   // dev/benchmark only: keep experiments off the real database
        } else {
            let fm = FileManager.default
            let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("HyperBrowser", isDirectory: true)
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
            resolvedPath = appSupport.appendingPathComponent("browser.sqlite").path
        }

        var config = Configuration()
        config.foreignKeysEnabled = true
        dbPool = try DatabasePool(path: resolvedPath, configuration: config)
        try Self.migrator.migrate(dbPool)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("visitCount", .integer).notNull().defaults(to: 1)
                t.column("lastVisitedAt", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            // Full-text search over history, kept in sync with the `history`
            // table automatically by GRDB-generated triggers.
            try db.create(virtualTable: "history_fts", using: FTS5()) { t in
                t.synchronize(withTable: "history")
                t.column("title")
                t.column("url")
            }

            try db.create(table: "bookmarks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        // Session restoration: one row per open tab, replaced wholesale on
        // every save rather than diffed — simple, and cheap enough at the
        // scale of "a browser window's worth of tabs".
        migrator.registerMigration("v2_sessions") { db in
            try db.create(table: "tabSessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("orderIndex", .integer).notNull()
                t.column("url", .text).notNull()
                t.column("isPrivate", .boolean).notNull()
                t.column("interactionState", .blob)
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // Per-site permissions (camera, microphone, location). `session`
        // rows are the default ("temporary") and are purged at launch;
        // `permanent` rows only exist when the user explicitly asked to
        // remember the choice.
        migrator.registerMigration("v3_sitePermissions") { db in
            try db.create(table: "sitePermissions") { t in
                t.column("origin", .text).notNull()
                t.column("permission", .text).notNull()
                t.column("decision", .text).notNull()
                t.column("scope", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["origin", "permission"])
            }
        }

        // Saved logins. `sealedPassword` is a ChaChaPoly box (see CredentialVault);
        // nothing sensitive is stored in the clear.
        migrator.registerMigration("v4_credentials") { db in
            try db.create(table: "credentials") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("origin", .text).notNull().indexed()
                t.column("username", .text).notNull()
                t.column("sealedPassword", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["origin", "username"])
            }
        }

        // Titles of saved tabs, so a sleeping restored tab shows its real title
        // instead of just a hostname.
        migrator.registerMigration("v5_tabTitles") { db in
            try db.alter(table: "tabSessions") { t in
                t.add(column: "title", .text)
            }
        }

        // Which space (Perso / Travail / Lecture) each saved tab belongs to.
        migrator.registerMigration("v6_tabSpaces") { db in
            try db.alter(table: "tabSessions") { t in
                t.add(column: "spaceIndex", .integer).notNull().defaults(to: 0)
            }
        }

        // What the browser learned about each site's memory use (host + numbers only).
        migrator.registerMigration("v7_siteMemory") { db in
            try db.create(table: "siteMemory") { t in
                t.primaryKey("host", .text)
                t.column("samples", .integer).notNull()
                t.column("averageMB", .double).notNull()
                t.column("peakMB", .double).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // Tab groups, which group each saved tab is in, and per-space favorites
        // (`spaceIndex` NULL = shown in every space, which keeps older favorites visible).
        migrator.registerMigration("v8_groupsAndSpaceFavorites") { db in
            try db.create(table: "tabGroups") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("spaceIndex", .integer).notNull()
                t.column("collapsed", .boolean).notNull().defaults(to: false)
                t.column("position", .integer).notNull()
            }
            try db.alter(table: "tabSessions") { t in t.add(column: "groupID", .text) }
            try db.alter(table: "bookmarks") { t in t.add(column: "spaceIndex", .integer) }
        }

        // Pages saved to read later.
        migrator.registerMigration("v9_readingList") { db in
            try db.create(table: "readingList") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("addedAt", .datetime).notNull()
            }
        }

        // Where the user was in each page (video position, reading position).
        migrator.registerMigration("v10_resumePoints") { db in
            try db.create(table: "resumePoints") { t in
                t.primaryKey("key", .text)
                t.column("title", .text).notNull()
                t.column("videoSeconds", .double)
                t.column("videoDuration", .double)
                t.column("readFraction", .double)
                t.column("anchor", .text)
                t.column("updatedAt", .datetime).notNull().indexed()
            }
        }

        // What the user changed on each site (CSS rules the local model wrote and the app checked).
        migrator.registerMigration("v11_boosts") { db in
            try db.create(table: "boosts") { t in
                t.primaryKey("host", .text)
                t.column("prompt", .text).notNull()
                t.column("rulesJSON", .text).notNull()
                t.column("calm", .boolean).notNull().defaults(to: false)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // Tabs of the windows opened after the first one (the first window's tabs stay in `tabSessions`).
        migrator.registerMigration("v12_extraWindows") { db in
            try db.create(table: "extraWindowTabs") { t in
                t.column("windowIndex", .integer).notNull()
                t.column("orderIndex", .integer).notNull()
                t.column("url", .text).notNull()
                t.column("interactionState", .blob)
                t.column("title", .text)
                t.column("spaceIndex", .integer).notNull().defaults(to: 0)
                t.column("isActive", .boolean).notNull().defaults(to: false)
            }
        }

        // Notes written in the browser; a note can belong to a page (`url`) or stand alone.
        migrator.registerMigration("v13_notes") { db in
            try db.create(table: "notes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("body", .text).notNull().defaults(to: "")
                t.column("url", .text)
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // Secrets de codes à usage unique (2FA), un par compte enregistré ; chiffrés comme les mots de passe.
        migrator.registerMigration("v14_totp") { db in
            try db.create(table: "totpSecrets") { t in
                t.column("origin", .text).notNull()
                t.column("username", .text).notNull()
                t.column("sealed", .blob).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["origin", "username"])
            }
        }

        // Adresses et cartes pour le remplissage automatique : un enregistrement chiffré par ligne.
        migrator.registerMigration("v15_autofill") { db in
            try db.create(table: "autofill") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("kind", .text).notNull()
                t.column("label", .text).notNull().defaults(to: "")
                t.column("sealed", .blob).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // La mémoire ambiante : les pages lues (extrait de texte) et leur index de recherche.
        migrator.registerMigration("v16_pageMemory") { db in
            try db.create(table: "pageMemory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().unique()
                t.column("host", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                t.column("readAt", .datetime).notNull().indexed()
                t.column("visits", .integer).notNull().defaults(to: 1)
            }
            try db.create(virtualTable: "pageMemory_fts", using: FTS5()) { t in
                t.synchronize(withTable: "pageMemory")
                t.column("title")
                t.column("body")
            }
        }

        return migrator
    }
}
