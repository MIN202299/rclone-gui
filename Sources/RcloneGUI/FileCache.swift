import Foundation

/// On-disk cache for files opened from remotes, at <root>/<remote>/<path> (default root:
/// ~/Library/Caches/RcloneGUI/files; or "Rclone Cache" inside a folder the user picks).
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

    // MARK: Location

    /// UserDefaults key holding the folder the user picked (the parent of the cache folder).
    static let locationKey = "cacheLocation"
    /// The cache always lives in its own subfolder of the chosen folder, so clearing or evicting
    /// can never touch the user's other files.
    static let folderName = "Rclone Cache"

    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RcloneGUI/files", isDirectory: true)
    }

    /// The folder the user picked, if any (may currently be unavailable, e.g. an unplugged drive).
    static var chosenParent: URL? {
        guard let path = UserDefaults.standard.string(forKey: locationKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func customRoot(in parent: URL) -> URL {
        parent.appendingPathComponent(folderName, isDirectory: true)
    }

    /// True when a custom location is set but can't be used right now, so the default is used.
    static var isUsingFallback: Bool {
        guard let parent = chosenParent else { return false }
        return !isUsable(parent)
    }

    static func isUsable(_ parent: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir) && isDir.boolValue
            && FileManager.default.isWritableFile(atPath: parent.path)
    }

    /// Where cached files live right now.
    static var root: URL {
        if let parent = chosenParent, isUsable(parent) { return customRoot(in: parent) }
        return defaultRoot
    }

    enum RelocateError: LocalizedError {
        case notWritable, nested
        var errorDescription: String? {
            switch self {
            case .notWritable: return "That folder can't be written to."
            case .nested: return "Choose a folder outside the current cache folder."
            }
        }
    }

    /// Switches the cache to `newParent` (nil = default location). With `moveFiles`, cached files are
    /// moved over (instant on the same disk, copied across disks); otherwise the old cache is deleted.
    static func relocate(to newParent: URL?, moveFiles: Bool) throws {
        let fm = FileManager.default
        // Plain paths: standardizing can drop a "/private" prefix only for paths that exist.
        let oldRoot = root
        let newRoot = newParent.map(customRoot(in:)) ?? defaultRoot
        if let newParent, !isUsable(newParent) { throw RelocateError.notWritable }
        guard oldRoot.path != newRoot.path else {
            UserDefaults.standard.set(newParent?.path, forKey: locationKey)
            return
        }
        if newRoot.path.hasPrefix(oldRoot.path + "/") || oldRoot.path.hasPrefix(newRoot.path + "/") {
            throw RelocateError.nested
        }
        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        if moveFiles, let items = try? fm.contentsOfDirectory(at: oldRoot, includingPropertiesForKeys: nil) {
            for item in items {
                let dest = newRoot.appendingPathComponent(item.lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    try? merge(item, into: dest)
                } else {
                    try fm.moveItem(at: item, to: dest)
                }
            }
        }
        try? fm.removeItem(at: oldRoot)
        UserDefaults.standard.set(newParent?.path, forKey: locationKey)
    }

    /// Moves files from `source` into an existing folder `dest`, keeping whatever is already there.
    private static func merge(_ source: URL, into dest: URL) throws {
        let fm = FileManager.default
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let target = dest.appendingPathComponent(item.lastPathComponent)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: target.path, isDirectory: &isDir) {
                if isDir.boolValue { try merge(item, into: target) }
            } else {
                try fm.moveItem(at: item, to: target)
            }
        }
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
