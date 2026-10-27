import Foundation

/// A snapshot of one mounted volume. Live mount/unmount events come from DiskArbitration in the app (Phase 3).
public struct MountedVolume: Sendable, Equatable {
    public var id: String
    public var name: String
    public var url: URL
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isInternal: Bool
    public var capacity: Int64
    public var free: Int64

    /// Card when marked as one, or (auto) removable/ejectable with a camera-card layout. Marked "ignored" or as a drive → never.
    public func isCard(role: VolumeRole?) -> Bool {
        if let role { return role == .card }
        return (isRemovable || isEjectable) && !isInternal && CardScanner.looksLikeCard(url)
    }

    public var destination: Destination { Destination(id: id, name: name, root: url) }
}

public enum Volumes {
    static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeUUIDStringKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsRootFileSystemKey,
    ]

    /// Mounted, user-visible volumes other than the boot volume.
    public static func mounted() -> [MountedVolume] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .compactMap(info)
            .filter { $0.url.path != "/" }
    }

    /// Volume for a root URL; nil if it can't be read.
    public static func info(_ url: URL) -> MountedVolume? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true else { return nil }
        let name = v.volumeName ?? url.lastPathComponent
        // TODO(verify): FAT/exFAT cards should expose a UUID derived from the volume serial; fall back to name+size.
        let id = v.volumeUUIDString ?? "noid:\(name):\(v.volumeTotalCapacity ?? 0)"
        return MountedVolume(id: id, name: name, url: url,
                             isRemovable: v.volumeIsRemovable ?? false, isEjectable: v.volumeIsEjectable ?? false,
                             isInternal: v.volumeIsInternal ?? false,
                             capacity: Int64(v.volumeTotalCapacity ?? 0), free: Int64(v.volumeAvailableCapacity ?? 0))
    }

    /// The non-boot volume holding `url` (or, if it doesn't exist yet, its nearest existing parent).
    public static func containing(_ url: URL) -> MountedVolume? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u = u.deletingLastPathComponent() }
        return (try? u.resourceValues(forKeys: [.volumeURLKey]).volume).flatMap(info)
    }

    /// A destination for any path: the volume itself when `url` is a mount point, otherwise the folder.
    public static func destination(for url: URL) -> Destination {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        if let vol = mounted().first(where: { $0.url.standardizedFileURL.path == url.path }) { return vol.destination }
        return Destination(id: "dir:\(url.path)", name: url.lastPathComponent, root: url)
    }
}
