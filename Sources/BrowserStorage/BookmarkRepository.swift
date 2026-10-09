import Foundation
import GRDB
import BrowserCore

public struct BookmarkRepository: Sendable {
    private let dbPool: DatabasePool

    public init(database: AppDatabase = .shared) {
        self.dbPool = database.dbPool
    }

    public func add(url: String, title: String, spaceIndex: Int? = nil) throws {
        try dbPool.write { db in
            guard try Bookmark.filter(Column("url") == url).fetchCount(db) == 0 else { return }
            var bookmark = Bookmark(url: url, title: title, spaceIndex: spaceIndex)
            try bookmark.insert(db)
        }
    }

    public func contains(url: String) throws -> Bool {
        try dbPool.read { db in try Bookmark.filter(Column("url") == url).fetchCount(db) > 0 }
    }

    public func remove(url: String) throws {
        try dbPool.write { db in
            _ = try Bookmark.filter(Column("url") == url).deleteAll(db)
        }
    }

    public func all() throws -> [Bookmark] {
        try dbPool.read { db in
            try Bookmark.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    /// Favorites of one space plus the ones shared by every space, newest first.
    public func all(forSpace space: Int) throws -> [Bookmark] {
        try dbPool.read { db in
            try Bookmark.filter(Column("spaceIndex") == nil || Column("spaceIndex") == space)
                .order(Column("createdAt").desc).fetchAll(db)
        }
    }

    /// Keeps favorites attached to the right space after space `deleted` was removed.
    public func reindex(afterDeletingSpace deleted: Int) throws {
        try dbPool.write { db in
            for var bookmark in try Bookmark.filter(Column("spaceIndex") != nil).fetchAll(db) {
                bookmark.spaceIndex = SpaceReindex.newFavoriteIndex(bookmark.spaceIndex, afterDeleting: deleted)
                try bookmark.update(db)
            }
        }
    }

    public func clear() throws {
        try dbPool.write { db in _ = try Bookmark.deleteAll(db) }
    }
}
