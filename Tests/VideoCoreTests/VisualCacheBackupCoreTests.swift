import XCTest
@testable import VideoCore

final class VisualCacheBackupCoreTests: XCTestCase {
    struct Fixture {
        let directory: URL; let repository: Repository; let asset: Asset
    }
    func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("visual-backup-" + UUID().uuidString)
        let repository = try Repository(root: directory.appendingPathComponent("source"))
        let workspace = Workspace(name: "绘制恢复", owner: "local")
        let asset = try repository.ingest(Data("保留原音和素材".utf8), name: "original.txt", workspaceID: workspace.id, mediaType: "text")
        try repository.transaction { $0.workspaces = [workspace]; $0.assets = [asset] }
        return Fixture(directory: directory, repository: repository, asset: asset)
    }
    func pair(_ label: String, frames: Int = 30, interval: Bool = false, clip: Data = Data("cache-file-bytes".utf8)) throws -> [String: Data] {
        let sceneKey = Codec.hash(Data(label.utf8))
        let range = VisualCacheBackup.Interval(version: "native-scene-interval-1", sceneKey: sceneKey, lowerBound: 0, upperBound: frames)
        let key = try interval ? Codec.digest(range) : sceneKey
        let entry = VisualCacheBackup.Entry(key: key, bytes: clip.count, sha256: Codec.hash(clip), frames: frames)
        let metadata = try interval
            ? PropertyListEncoder().encode(VisualCacheBackup.IntervalEntry(interval: range, artifact: entry))
            : PropertyListEncoder().encode(entry)
        return [key + ".plist": metadata, key + ".mp4": clip]
    }
    func write(_ files: [String: Data], to root: URL) throws {
        let directory = root.appendingPathComponent("cache/visuals")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, bytes) in files { try bytes.write(to: directory.appendingPathComponent(name), options: .atomic) }
    }
    func archive(_ repository: Repository) throws -> Repository.Backup {
        try PropertyListDecoder().decode(Repository.Backup.self, from: repository.backup())
    }
    func reject(_ backup: Repository.Backup, under directory: URL, label: String) throws {
        let destination = directory.appendingPathComponent(label)
        XCTAssertThrowsError(try Repository.restore(PropertyListEncoder().encode(backup), to: destination), label)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), label)
    }

    func testBothPublishedFormatsSurviveNormalBackupAndIndependentColdRestore() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        var files = try pair("whole", frames: 121)
        files.merge(try pair("interval", interval: true), uniquingKeysWith: { first, _ in first })
        try write(files, to: f.repository.root)
        let before = try Codec.data(f.repository.read())
        let backup = try f.repository.backup()
        XCTAssertEqual(try archive(f.repository).visualCache, files)
        XCTAssertEqual(try Codec.data(f.repository.read()), before, "备份不得改变业务、原音或审核状态")
        let cold = try Repository.restore(backup, to: f.directory.appendingPathComponent("cold"))
        for (name, bytes) in files {
            XCTAssertEqual(try Data(contentsOf: cold.root.appendingPathComponent("cache/visuals/" + name)), bytes)
        }
        XCTAssertEqual(try archive(cold).visualCache, files)
        XCTAssertEqual(try Data(contentsOf: cold.assetURL(f.asset)), Data("保留原音和素材".utf8))
    }

    func testLiveIncompleteTemporaryAndCorruptHintsAreIgnoredWithoutLosingSource() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let valid = try pair("valid")
        try write(valid, to: f.repository.root)
        var invalid = try pair("corrupt")
        invalid[Codec.hash(Data("corrupt".utf8)) + ".mp4"] = Data("changed".utf8)
        let orphan = try pair("orphan").filter { $0.key.hasSuffix(".plist") }
        invalid.merge(orphan, uniquingKeysWith: { first, _ in first })
        invalid[UUID().uuidString + ".mp4"] = Data("unfinished writer".utf8)
        try write(invalid, to: f.repository.root)
        let backup = try archive(f.repository)
        XCTAssertEqual(backup.visualCache, valid)
        XCTAssertEqual(backup.assets[f.asset.relativePath], Data("保留原音和素材".utf8))
    }

    func testLiveFinalSymlinkAndHardlinkAreNeverArchived() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        for (label, hardlink) in [("symlink", false), ("hardlink", true)] {
            let files = try pair(label), key = Codec.hash(Data(label.utf8))
            try write(files, to: f.repository.root)
            let clip = f.repository.root.appendingPathComponent("cache/visuals/" + key + ".mp4")
            let other = f.directory.appendingPathComponent(label + "-outside.mp4")
            try FileManager.default.moveItem(at: clip, to: other)
            if hardlink { try FileManager.default.linkItem(at: other, to: clip) }
            else { try FileManager.default.createSymbolicLink(at: clip, withDestinationURL: other) }
        }
        XCTAssertNil(try archive(f.repository).visualCache)
    }

    func testLiveParentDirectorySymlinkIsNeverArchived() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let outside = f.directory.appendingPathComponent("outside")
        try write(pair("outside"), to: outside)
        try FileManager.default.createDirectory(at: f.repository.root.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.repository.root.appendingPathComponent("cache/visuals"), withDestinationURL: outside.appendingPathComponent("cache/visuals"))
        XCTAssertNil(try archive(f.repository).visualCache)
    }

    func testRestoreRejectsUnpairedTamperedOrUnsafeHintsBeforeCreatingDestination() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let files = try pair("portable"), key = Codec.hash(Data("portable".utf8))
        let base = try archive(f.repository)
        var cases: [[String: Data]] = [
            files.filter { $0.key.hasSuffix(".mp4") },
            files.filter { $0.key.hasSuffix(".plist") },
            ["../" + key + ".mp4": Data("escape".utf8)],
            ["cache/visuals/" + key + ".plist": files[key + ".plist"]!],
            [key.uppercased() + ".plist": files[key + ".plist"]!]
        ]
        var tampered = files; tampered[key + ".mp4"] = Data("tampered payload".utf8); cases.append(tampered)
        for (index, hints) in cases.enumerated() {
            var backup = base; backup.visualCache = hints
            try reject(backup, under: f.directory, label: "bad-\(index)")
        }
    }

    func testRestoreRejectsWrongKeyFramesAndIntervalDigest() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let base = try archive(f.repository), clip = Data("opaque encoded clip".utf8)
        let key = Codec.hash(Data("bad-metadata".utf8))
        let entries = [
            VisualCacheBackup.Entry(key: String(repeating: "a", count: 64), bytes: clip.count, sha256: Codec.hash(clip), frames: 30),
            VisualCacheBackup.Entry(key: key, bytes: clip.count, sha256: Codec.hash(clip), frames: 0),
            VisualCacheBackup.Entry(key: key, bytes: clip.count, sha256: Codec.hash(clip), frames: Int.max)
        ]
        for (index, entry) in entries.enumerated() {
            var backup = base; backup.visualCache = [key + ".plist": try PropertyListEncoder().encode(entry), key + ".mp4": clip]
            try reject(backup, under: f.directory, label: "bad-entry-\(index)")
        }
        var hints = try pair("interval-bad", interval: true)
        let manifestName = try XCTUnwrap(hints.keys.first { $0.hasSuffix(".plist") })
        var value = try PropertyListDecoder().decode(VisualCacheBackup.IntervalEntry.self, from: XCTUnwrap(hints[manifestName]))
        value.interval.sceneKey = String(repeating: "b", count: 64)
        hints[manifestName] = try PropertyListEncoder().encode(value)
        var backup = base; backup.visualCache = hints
        try reject(backup, under: f.directory, label: "bad-interval-digest")
    }

    func testOptionalCacheBudgetSkipsOversizedLivePairAndEnforcesCombinedAllowance() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let large = try pair("over-budget", clip: Data(repeating: 7, count: VisualCacheBackup.maximumBytes))
        try write(large, to: f.repository.root)
        XCTAssertNil(try archive(f.repository).visualCache, "32MiB包含清单；可选缓存不挤掉必要源")
        let small = try pair("budget-boundary"), total = small.values.reduce(0) { $0 + $1.count }
        XCTAssertEqual(try VisualCacheBackup.validate(small, availableBytes: total), small)
        XCTAssertThrowsError(try VisualCacheBackup.validate(small, availableBytes: total - 1))
        var backup = try archive(f.repository); backup.visualCache = large
        try reject(backup, under: f.directory, label: "oversized-cache")
    }

    func testLegacyV1AndV2WithoutOptionalHintsRemainCompatible() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let backup = try archive(f.repository)
        for version in [1, 2] {
            var old = backup; old.version = version; old.visualCache = nil
            let data = try PropertyListEncoder().encode(old)
            let dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
            XCTAssertNil(dictionary["visualCache"])
            let cold = try Repository.restore(data, to: f.directory.appendingPathComponent("legacy-\(version)"))
            XCTAssertEqual(try Data(contentsOf: cold.assetURL(f.asset)), Data("保留原音和素材".utf8))
            XCTAssertNil(try archive(cold).visualCache)
        }
    }

    func testOptionalHintsCannotRelaxTheRequiredSourceInventory() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        var backup = try archive(f.repository); backup.visualCache = try pair("valid-hint")
        backup.assets = [:]
        try reject(backup, under: f.directory, label: "missing-required-source")
    }
}
