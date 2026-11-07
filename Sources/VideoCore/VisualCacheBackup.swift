import Foundation

/// Portable hints for the two existing VisualClipCache manifest formats.
/// Core owns backup validation without depending on the media renderer. The
/// interval's encoded field names and digest remain identical to that renderer.
enum VisualCacheBackup {
    static let maximumBytes = 32 * 1024 * 1024
    static let maximumManifestBytes = 64 * 1024
    static let maximumSceneFrames = 270_000 // 54,000 / minimum speed .25 + pause 54,000
    struct Entry: Codable {
        var key: String; var bytes: Int; var sha256: String; var frames: Int
    }
    struct Interval: Codable {
        var version: String; var sceneKey: String; var lowerBound: Int; var upperBound: Int
    }
    struct IntervalEntry: Codable { var interval: Interval; var artifact: Entry }

    static func key(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
    static func manifest(_ data: Data, key expected: String) throws -> Entry {
        guard key(expected), !data.isEmpty, data.count <= maximumManifestBytes,
              let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw VideoError.invalid("备份绘制缓存清单无效")
        }
        let decoder = PropertyListDecoder()
        let entry: Entry
        if Set(object.keys) == ["interval", "artifact"] {
            let value = try decoder.decode(IntervalEntry.self, from: data), interval = value.interval
            guard interval.version == "native-scene-interval-1", key(interval.sceneKey),
                  interval.lowerBound >= 0, interval.upperBound > interval.lowerBound,
                  interval.upperBound <= maximumSceneFrames else { throw VideoError.invalid("备份绘制缓存时间范围无效") }
            let frames = interval.upperBound - interval.lowerBound
            guard ((interval.lowerBound % 120 == 0 && frames <= 120)
                   || (interval.lowerBound % 30 == 0 && frames <= 30)),
                  try Codec.digest(interval) == expected, value.artifact.frames == frames else {
                throw VideoError.invalid("备份绘制缓存区间与摘要不一致")
            }
            entry = value.artifact
        } else {
            guard Set(object.keys) == ["key", "bytes", "sha256", "frames"] else { throw VideoError.invalid("备份绘制缓存清单格式无效") }
            entry = try decoder.decode(Entry.self, from: data)
        }
        guard entry.key == expected, entry.bytes > 0, entry.bytes <= maximumBytes,
              key(entry.sha256), (1...maximumSceneFrames).contains(entry.frames) else {
            throw VideoError.invalid("备份绘制缓存文件绑定无效")
        }
        return entry
    }

    /// Restore treats an optional cache as untrusted archive input. Unlike a
    /// damaged live hint, a malformed included file is rejected before writing.
    static func validate(_ files: [String: Data]?, availableBytes: Int) throws -> [String: Data] {
        let files = files ?? [:]
        var total = 0, stems = Set<String>()
        for (path, data) in files {
            let name = path
            guard name.utf8.count == 68 || name.utf8.count == 70,
                  name.hasSuffix(".mp4") || name.hasSuffix(".plist") else { throw VideoError.invalid("备份绘制缓存文件名无效") }
            let stem = String(name.dropLast(name.hasSuffix(".mp4") ? 4 : 6))
            guard key(stem), data.count <= maximumBytes - total,
                  data.count <= availableBytes - total else { throw VideoError.invalid("备份绘制缓存超过读取上限或路径无效") }
            total += data.count; stems.insert(stem)
        }
        for stem in stems {
            guard let metadata = files[stem + ".plist"], let clip = files[stem + ".mp4"] else {
                throw VideoError.invalid("备份绘制缓存缺少配对文件")
            }
            let entry = try manifest(metadata, key: stem)
            guard clip.count == entry.bytes, Codec.hash(clip) == entry.sha256 else { throw VideoError.invalid("备份绘制缓存原件摘要不符") }
        }
        return files
    }
}
