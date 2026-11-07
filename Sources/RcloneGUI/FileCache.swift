import Foundation

/// On-disk cache for files opened from remotes, at ~/Library/Caches/RcloneGUI/files/<remote>/<path>.
/// Re-opening uses `rclone copyto`, which skips the download when the cached copy still matches
/// the remote (size + modification time). Least-recently-used files are evicted past the size limit.
enum FileCache {
    static let limitKey = "cacheLimitBytes"
    static let defaultLimit: Int64 = 2_000_000_000 // 2 GB
    static let limitChoices: [Int64] = [500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000,
                                        10_000_000_000, 20_000_000_000, 50_000_000_000]

    private static let lastUsedAttr = "com.rclone-gui.lastUsed"

    static var limit: Int64 {
        (UserDefaults.standard.object(forKey: limitKey) as? NSNumber)?.int64Value ?? defaultLimit
    }

    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RcloneGUI/files", isDirectory: true)
    }

    /// Cache location for a remote file, or nil if the path would escape the cache folder.
    static func url(remote: String, path: String) -> URL? {
        let parts = ([remote] + path.split(separator: "/").map(String.init))
        guard !path.isEmpty, !remote.contains("/"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    /// Records use for LRU eviction without touching the file's modification time
    /// (rclone compares that against the remote).
    static func markUsed(_ url: URL) {
        var now = Date().timeIntervalSince1970
        _ = setxattr(url.path, lastUsedAttr, &now, MemoryLayout<Double>.size, 0, 0)
    }

    private static func lastUsed(_ url: URL) -> Double {
        var value: Double = 0
        if getxattr(url.path, lastUsedAttr, &value, MemoryLayout<Double>.size, 0, 0) == MemoryLayout<Double>.size {
            return value
        }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return date?.timeIntervalSince1970 ?? 0
    }

    private static func files() -> [(url: URL, size: Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        return e.compactMap { item in
            guard let url = item as? URL,
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return (url, Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0))
        }
    }

    /// Total bytes used on disk by the cache.
    static func usage() -> Int64 {
        files().reduce(0) { $0 + $1.size }
    }

    /// Deletes least-recently-used files until the cache fits the limit.
    /// `keeping` (the file just opened) is never deleted.
    static func enforceLimit(keeping: URL? = nil) {
        let limit = limit
        var all = files()
        var total = all.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }
        let keep = keeping?.resolvingSymlinksInPath().path
        all.sort { lastUsed($0.url) < lastUsed($1.url) }
        for file in all where total > limit {
            if file.url.resolvingSymlinksInPath().path == keep { continue }
            if (try? FileManager.default.removeItem(at: file.url)) != nil { total -= file.size }
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: root)
    }
}
