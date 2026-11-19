import XCTest
import Darwin
@testable import VideoCore

final class StreamingBackupTests: XCTestCase {
    private struct Fixture {
        var directory: URL; var repository: Repository; var asset: Asset; var export: Data
    }
    private func fixture(compressed: Bool = false) throws -> Fixture {
        let directory=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("stream-backup-"+Codec.id())
        let repository=try Repository(root: directory.appendingPathComponent("source"))
        let workspace=Workspace(name: "完整流式工程", owner: "local")
        let asset=try repository.ingest(Data("完整原件保持".utf8), name: "source.txt", workspaceID: workspace.id, mediaType: "text")
        var alias=asset; alias.id=Codec.id(); alias.name="同源引用不重复负载"
        var revision=try Planner.create(workspaceID: workspace.id, name: "完整历史", scenes: [Scene(title: "保留场景", body: "保留原内容。", durationFrames: 60)])
        revision.dependencies=try DependencyRules.freeze(revision: revision, assets: [asset, alias], evidence: [])
        var project=Project(workspaceID: workspace.id, name: "完整历史", revision: revision)
        for n in 1...3 {
            project=try Editor.apply([.cta("第\(n)次编辑")], to: project, baseRevision: project.current.id, assets: [asset, alias], message: "保留全部历史")
            project.revisions[project.revisions.count-1].dependencies=try DependencyRules.freeze(revision: project.current, assets: [asset, alias], evidence: [])
        }
        let digest=try project.current.contentDigest()
        let quote=Quote(projectID: project.id, revisionID: project.current.id, digest: digest, upper: Money(0), unit: "CNY", provider: "native", expiresAt: Date().addingTimeInterval(60), confirmed: true)
        var job=Job(workspaceID: workspace.id, projectID: project.id, revisionID: project.current.id, digest: digest, requestKey: "stream-fixture", quote: quote)
        let export=Data("真实历史导出字节".utf8), path=repository.root.appendingPathComponent("exports/\(job.id)/payload.bin")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try export.write(to: path)
        job.artifacts=[Artifact(path: path.path, mime: "application/octet-stream", bytes: export.count, sha256: Codec.hash(export), revision: project.current.id)]
        try repository.transaction {
            $0.workspaces=[workspace]; $0.assets=[asset, alias]; $0.projects=[project]; $0.jobs=[job]
            if compressed { $0.terminology["完整词条"]=String(repeating: "原样中文UTF-8历史；", count: 90_000) }
        }
        return Fixture(directory: directory, repository: repository, asset: asset, export: export)
    }
    private func backup(_ f: Fixture, name: String = "complete") throws -> URL {
        let file=f.directory.appendingPathComponent(name+".videobackup")
        _=try f.repository.backup(to: file); return file
    }
    private func unpack(_ data: Data) throws -> (object: [String: Any], snapshot: Data, files: Data) {
        XCTAssertEqual(Data(data.prefix(8)), StreamingBackupRules.magic)
        let count=Int(data[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
        let object=try XCTUnwrap(PropertyListSerialization.propertyList(from: data.subdata(in: 16..<(16+count)), options: [], format: nil) as? [String: Any])
        let stored=try XCTUnwrap(object["snapshotStoredBytes"] as? Int)
        return (object, data.subdata(in: (16+count)..<(16+count+stored)), data.subdata(in: (16+count+stored)..<data.count))
    }
    private func wire(_ object: [String: Any], snapshot: Data, files: Data) throws -> Data {
        let index=try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        let count=UInt64(index.count)
        var data=StreamingBackupRules.magic
        data.append(contentsOf: (0..<8).reversed().map { UInt8(truncatingIfNeeded: count >> UInt64($0*8)) })
        data.append(index); data.append(snapshot); data.append(files); return data
    }
    private func reject(_ data: Data, under directory: URL, label: String) throws {
        let source=directory.appendingPathComponent(label+".videobackup"), destination=directory.appendingPathComponent(label+"-cold")
        try data.write(to: source)
        XCTAssertThrowsError(try Repository.restore(from: source, to: destination), label)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), label)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".video-backup-") }, "失败仅清理本次暂存")
    }

    func testRawRoundTripRetainsEveryHistoryCASReferenceExportAndReview() throws {
        let f=try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let before=try Codec.data(f.repository.read()), destination=f.directory.appendingPathComponent("complete.videobackup")
        let receipt=try f.repository.backup(to: destination), bytes=try Data(contentsOf: destination), parts=try unpack(bytes)
        XCTAssertEqual(receipt.bytes, bytes.count); XCTAssertEqual(receipt.sha256, Codec.hash(bytes))
        XCTAssertEqual(parts.object["snapshotEncoding"] as? String, BackupSnapshotCodec.rawEncoding)
        XCTAssertEqual((parts.object["entries"] as? [[String: Any]])?.count, 2, "相同hash和扩展名只存一次负载")
        let cold=try Repository.restore(from: destination, to: f.directory.appendingPathComponent("cold"))
        XCTAssertEqual(try cold.read().projects[0].revisions.count, 4); XCTAssertEqual(try cold.read().assets.count, 2)
        XCTAssertEqual(try Data(contentsOf: cold.assetURL(f.asset)), Data("完整原件保持".utf8))
        let artifact=try XCTUnwrap(cold.read().jobs.first?.artifacts.first)
        XCTAssertTrue(artifact.path.hasPrefix(cold.root.path+"/exports/")); XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: artifact.path)), f.export)
        XCTAssertEqual(try Codec.data(f.repository.read()), before)
        XCTAssertEqual(try f.repository.backupSemanticDigest(), try Repository.backupSemanticDigest(from: destination))
        XCTAssertEqual(try f.repository.backupSemanticDigest(), try cold.backupSemanticDigest())
        XCTAssertFalse(try cold.read().projects[0].current.review.complete)
    }

    func testCompressedRoundTripRetainsBothOptionalCacheFormats() throws {
        let f=try fixture(compressed: true); defer { try? FileManager.default.removeItem(at: f.directory) }
        let cacheFixture=VisualCacheBackupCoreTests()
        var cache=try cacheFixture.pair("stream-whole", frames: 121)
        cache.merge(try cacheFixture.pair("stream-interval", interval: true), uniquingKeysWith: { first, _ in first })
        try cacheFixture.write(cache, to: f.repository.root)
        let source=try backup(f), parts=try unpack(Data(contentsOf: source))
        XCTAssertEqual(parts.object["snapshotEncoding"] as? String, BackupSnapshotCodec.encoding)
        XCTAssertLessThan(try XCTUnwrap(parts.object["snapshotStoredBytes"] as? Int), try XCTUnwrap(parts.object["snapshotBytes"] as? Int))
        let cold=try Repository.restore(from: source, to: f.directory.appendingPathComponent("cold"))
        for (name, data) in cache { XCTAssertEqual(try Data(contentsOf: cold.root.appendingPathComponent("cache/visuals/"+name)), data) }
        XCTAssertEqual(try cold.backupSemanticDigest(), try f.repository.backupSemanticDigest())
    }

    func testFileEntryPointRestoresLegacyVersionsOneTwoAndThree() throws {
        let f=try fixture(compressed: true); defer { try? FileManager.default.removeItem(at: f.directory) }
        let original=try PropertyListDecoder().decode(Repository.Backup.self, from: f.repository.backup())
        for version in [1, 2, 3] {
            var value=original; value.version=version
            if version < 3 { value.snapshot=try original.decodedSnapshot(); value.snapshotEncoding=nil; value.snapshotBytes=nil }
            if version == 1 { value.exports=nil }
            let file=f.directory.appendingPathComponent("legacy-\(version).videobackup")
            try PropertyListEncoder().encode(value).write(to: file)
            let cold=try Repository.restore(from: file, to: f.directory.appendingPathComponent("cold-\(version)"))
            XCTAssertEqual(try cold.read().projects[0].revisions.count, 4)
            XCTAssertEqual(try Data(contentsOf: cold.assetURL(f.asset)), Data("完整原件保持".utf8))
            if version == 1 { XCTAssertTrue(try cold.read().jobs[0].artifacts.isEmpty) }
            else { XCTAssertTrue(try XCTUnwrap(cold.read().jobs[0].artifacts.first).path.hasPrefix(cold.root.path+"/exports/")) }
        }
        var invalid=original, invalidState=try Codec.decoder().decode(Database.self, from: original.decodedSnapshot())
        for index in invalidState.assets.indices { invalidState.assets[index].ext="INVALID" }
        invalid.version=2; invalid.snapshot=try Codec.data(invalidState); invalid.digest=Codec.hash(invalid.snapshot)
        invalid.snapshotEncoding=nil; invalid.snapshotBytes=nil
        invalid.assets=["assets/"+f.asset.hash+".INVALID": try XCTUnwrap(original.assets[f.asset.relativePath])]
        let bad=f.directory.appendingPathComponent("legacy-invalid-extension.videobackup")
        try PropertyListEncoder().encode(invalid).write(to: bad)
        XCTAssertThrowsError(try Repository.backupSemanticDigest(from: bad), "语义比较与旧版恢复使用相同路径/扩展名边界")
    }

    func testTruncationTrailingBytesAndChangedPayloadNeverPublishRecovery() throws {
        let f=try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let raw=try Data(contentsOf: backup(f))
        try reject(Data(raw.prefix(7)), under: f.directory, label: "short-header")
        try reject(Data(raw.dropLast()), under: f.directory, label: "truncated")
        var trailing=raw; trailing.append(0); try reject(trailing, under: f.directory, label: "trailing")
        var altered=raw; altered[altered.count-1] ^= 1; try reject(altered, under: f.directory, label: "altered-payload")
    }

    func testManifestRejectsUnknownFieldsBooleanIntegersDuplicateAndUnsortedPaths() throws {
        let f=try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let parts=try unpack(Data(contentsOf: backup(f)))
        var cases: [[String: Any]]=[]
        var unknown=parts.object; unknown["unexpected"]=1; cases.append(unknown)
        var boolean=parts.object; boolean["version"]=true; cases.append(boolean)
        var order=parts.object, entries=try XCTUnwrap(order["entries"] as? [[String: Any]])
        order["entries"]=Array(entries.reversed()); cases.append(order)
        var duplicate=parts.object; duplicate["entries"]=[entries[0], entries[0]]; cases.append(duplicate)
        var unsafe=parts.object; entries[0]["path"]="assets/../outside"; unsafe["entries"]=entries; cases.append(unsafe)
        for (index, object) in cases.enumerated() { try reject(wire(object, snapshot: parts.snapshot, files: parts.files), under: f.directory, label: "bad-index-\(index)") }
    }

    func testCompressedSnapshotRejectsWrongLengthTrailingAndConcatenatedStreams() throws {
        let f=try fixture(compressed: true); defer { try? FileManager.default.removeItem(at: f.directory) }
        let parts=try unpack(Data(contentsOf: backup(f)))
        for kind in ["short", "tail", "concat", "length", "digest"] {
            var object=parts.object, snapshot=parts.snapshot
            switch kind {
            case "short": snapshot.removeLast()
            case "tail": snapshot.append(0)
            case "concat": snapshot.append(parts.snapshot)
            case "length": object["snapshotBytes"]=(object["snapshotBytes"] as! Int)+1
            default: object["snapshotDigest"]=String(repeating: "0", count: 64)
            }
            object["snapshotStoredBytes"]=snapshot.count
            try reject(wire(object, snapshot: snapshot, files: parts.files), under: f.directory, label: "bad-snapshot-"+kind)
        }
    }

    func testManifestInventoryMustExactlyBindAllSourceAndHistoricalExportReferences() throws {
        let f=try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let parts=try unpack(Data(contentsOf: backup(f)))
        var object=parts.object, entries=try XCTUnwrap(object["entries"] as? [[String: Any]])
        entries[0]["bytes"]=(entries[0]["bytes"] as! Int)+1
        object["entries"]=entries; object["totalFileBytes"]=(object["totalFileBytes"] as! Int)+1
        var files=parts.files; files.append(0)
        try reject(wire(object, snapshot: parts.snapshot, files: files), under: f.directory, label: "mismatched-reference")
        object=parts.object; entries=try XCTUnwrap(object["entries"] as? [[String: Any]])
        let removed=entries.removeLast(); object["entries"]=entries
        object["totalFileBytes"]=(object["totalFileBytes"] as! Int)-(removed["bytes"] as! Int)
        try reject(wire(object, snapshot: parts.snapshot, files: Data(parts.files.dropLast(removed["bytes"] as! Int))), under: f.directory, label: "missing-export")
    }

    func testMissingOrChangedSourceCannotReplaceAnExistingBackup() throws {
        let f=try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let destination=try backup(f), original=try Data(contentsOf: destination)
        try Data("变化原件保持".utf8).write(to: f.repository.assetURL(f.asset))
        XCTAssertThrowsError(try f.repository.backup(to: destination, replaceExisting: true))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        try FileManager.default.removeItem(at: f.repository.assetURL(f.asset))
        XCTAssertThrowsError(try f.repository.backup(to: destination, replaceExisting: true))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testRestoreBindsEveryExportToItsOriginalJobRevisionAndAllowedLocation() throws {
        let f=try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let parts=try unpack(Data(contentsOf: backup(f)))
        for mutation in ["revision", "other-job", "draft-mime"] {
            var state=try Codec.decoder().decode(Database.self, from: parts.snapshot), object=parts.object
            var entries=try XCTUnwrap(object["entries"] as? [[String: Any]])
            if mutation == "revision" { state.jobs[0].artifacts[0].revision="unbound-revision" }
            else {
                let path=mutation == "other-job" ? "exports/another-job/payload.bin" : "drafts/"+state.jobs[0].id+".txt"
                state.jobs[0].artifacts[0].path=path
                let index=try XCTUnwrap(entries.firstIndex { $0["kind"] as? String == "exports" }); entries[index]["path"]=path
            }
            let snapshot=try Codec.data(state)
            object["entries"]=entries; object["snapshotBytes"]=snapshot.count; object["snapshotStoredBytes"]=snapshot.count; object["snapshotDigest"]=Codec.hash(snapshot)
            try reject(wire(object, snapshot: snapshot, files: parts.files), under: f.directory, label: "unbound-"+mutation)
        }
    }

    func testSourceSymlinkHardlinkAndLinkedParentAreRejected() throws {
        for kind in ["symlink", "hardlink", "parent"] {
            let f=try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            let source=f.repository.assetURL(f.asset), outside=f.directory.appendingPathComponent("outside.txt")
            if kind == "parent" {
                let moved=f.directory.appendingPathComponent("moved-assets")
                try FileManager.default.moveItem(at: source.deletingLastPathComponent(), to: moved)
                try FileManager.default.createSymbolicLink(at: source.deletingLastPathComponent(), withDestinationURL: moved)
            } else {
                try FileManager.default.moveItem(at: source, to: outside)
                if kind == "symlink" { try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside) }
                else { try FileManager.default.linkItem(at: outside, to: source) }
            }
            let output=f.directory.appendingPathComponent("must-not-exist.videobackup")
            XCTAssertThrowsError(try f.repository.backup(to: output)); XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testExistingBackupRequiresExplicitReplacementAndRecoveryNeverOverwrites() throws {
        let f=try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let destination=try backup(f), original=try Data(contentsOf: destination)
        XCTAssertThrowsError(try f.repository.backup(to: destination)); XCTAssertEqual(try Data(contentsOf: destination), original)
        try f.repository.transaction { $0.terminology["新词条"]="明确变更" }
        _=try f.repository.backup(to: destination, replaceExisting: true)
        XCTAssertNotEqual(try Data(contentsOf: destination), original)
        let occupied=f.directory.appendingPathComponent("occupied"); try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        let marker=occupied.appendingPathComponent("keep.txt"); try Data("原目录保持".utf8).write(to: marker)
        XCTAssertThrowsError(try Repository.restore(from: destination, to: occupied))
        XCTAssertEqual(try Data(contentsOf: marker), Data("原目录保持".utf8))
    }

    func testBackupDestinationCannotOverwriteLiveWorkspaceFilesEvenWhenReplacementIsExplicit() throws {
        let f=try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let artifact=try XCTUnwrap(f.repository.read().jobs[0].artifacts.first)
        let marker=f.repository.root.appendingPathComponent("independent.videolicense")
        try Data("必要内部状态保留".utf8).write(to: marker)
        let sqlite=f.repository.root.appendingPathComponent("workspace.sqlite")
        for target in [f.repository.assetURL(f.asset), URL(fileURLWithPath: artifact.path), sqlite, marker] {
            let before=try Data(contentsOf: target)
            XCTAssertThrowsError(try f.repository.backup(to: target, replaceExisting: true))
            XCTAssertEqual(try Data(contentsOf: target), before)
        }
        let before=try Codec.data(f.repository.read())
        XCTAssertNoThrow(try StreamingBackupRules.validateBackupDestination(f.directory.appendingPathComponent("external.videobackup"), repositoryRoot: f.repository.root), "合法外部父目录遍历到/后必须终止")
        for temporaryPath in ["/tmp", "/private/tmp"] {
            XCTAssertNoThrow(try StreamingBackupRules.validateBackupDestination(URL(fileURLWithPath: temporaryPath, isDirectory: true).appendingPathComponent("backup-system-alias.videobackup"), repositoryRoot: f.repository.root), "系统临时目录及其物理别名均可使用")
        }
        let systemBackup=URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("video-stream-backup-rule-"+Codec.id()+".videobackup")
        let systemCold=URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("video-stream-cold-rule-"+Codec.id(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: systemBackup); try? FileManager.default.removeItem(at: systemCold) }
        _=try f.repository.backup(to: systemBackup)
        let restoredViaSystemAlias=try Repository.restore(from: systemBackup, to: systemCold)
        XCTAssertEqual(try restoredViaSystemAlias.backupSemanticDigest(), try f.repository.backupSemanticDigest())
        XCTAssertThrowsError(try f.repository.backup(to: f.repository.root.appendingPathComponent("assets/new.videobackup")))
        let linkedRoot=f.directory.appendingPathComponent("workspace-directory-alias")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: f.repository.root)
        XCTAssertThrowsError(try f.repository.backup(to: linkedRoot.appendingPathComponent(f.asset.relativePath), replaceExisting: true))
        let caseAlias=f.repository.root.deletingLastPathComponent().appendingPathComponent(f.repository.root.lastPathComponent.uppercased())
        var actual=stat(), alias=stat()
        if lstat(caseAlias.path, &alias) == 0, lstat(f.repository.root.path, &actual) == 0,
           alias.st_dev == actual.st_dev, alias.st_ino == actual.st_ino {
            XCTAssertThrowsError(try f.repository.backup(to: caseAlias.appendingPathComponent(f.asset.relativePath), replaceExisting: true))
            let archiveViaAlias=caseAlias.appendingPathComponent("backup-case-alias.videobackup")
            _=try f.repository.backup(to: archiveViaAlias)
            XCTAssertEqual(try Repository.backupSemanticDigest(from: archiveViaAlias), try f.repository.backupSemanticDigest())
        }
        XCTAssertEqual(try Codec.data(f.repository.read()), before)
        let normal=f.repository.root.appendingPathComponent("backup-"+Codec.id()+".videobackup")
        _=try f.repository.backup(to: normal)
        _=try f.repository.backup(to: normal, replaceExisting: true)
        XCTAssertEqual(try Repository.backupSemanticDigest(from: normal), try f.repository.backupSemanticDigest())
    }

    func testPublicationBindsSelectedExistingFileAndPreservesConcurrentReplacement() throws {
        let directory=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("backup-publication-"+Codec.id())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let final=directory.appendingPathComponent("selected.videobackup"); try Data("旧备份".utf8).write(to: final)
        let publication=try StreamingBackupPublication(destination: final, directory: false, replaceExisting: true)
        try Data("另一个更新后的备份".utf8).write(to: final, options: .atomic)
        XCTAssertThrowsError(try publication.publish())
        XCTAssertEqual(try Data(contentsOf: final), Data("另一个更新后的备份".utf8))
    }

    func testStreamingSourceDetectsInPlaceMutationAndPathReplacementDuringRead() throws {
        for replace in [false, true] {
            let directory=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("backup-race-"+Codec.id())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source=directory.appendingPathComponent("original.bin"), data=Data(repeating: 7, count: StreamingBackupRules.blockBytes+16)
            try data.write(to: source)
            let input=try StreamingBackupInput(root: directory, relative: source.lastPathComponent, bytes: data.count, maximumBytes: data.count)
            var changed=false
            try input.blocks(bytes: data.count) { _ in
                if !changed { changed=true; try Data(repeating: 8, count: data.count).write(to: source, options: replace ? .atomic : []) }
            }
            XCTAssertThrowsError(try input.finish(), "读取期间同长度变更和inode替换均拒绝")
        }
    }

    func testCancelledBackupAndRestoreDoNotPublishAnything() async throws {
        let f=try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let original=try backup(f), destination=f.directory.appendingPathComponent("cancelled.videobackup"), cold=f.directory.appendingPathComponent("cancelled-cold")
        let writing=Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            _=try f.repository.backup(to: destination)
        }
        do { try await writing.value; XCTFail("取消必须传播") } catch is CancellationError {} catch { XCTFail("取消错误类型不符") }
        let restoring=Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            _=try Repository.restore(from: original, to: cold)
        }
        do { try await restoring.value; XCTFail("取消必须传播") } catch is CancellationError {} catch { XCTFail("取消错误类型不符") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: cold.path))
    }

    func testV4LimitsAreSeparateAndMetadataRejectsOverflowWithoutLargeAllocations() throws {
        XCTAssertEqual(BackupSnapshotCodec.maximumSnapshotBytes, 350 * 1024 * 1024)
        XCTAssertEqual(BackupSnapshotCodec.maximumStreamingSnapshotBytes, 1_000_000_000)
        let raw=Data("{}".utf8), digest=Codec.hash(raw)
        var manifest=StreamingBackupRules.Manifest(version: 4, snapshotEncoding: BackupSnapshotCodec.rawEncoding, snapshotBytes: 2, snapshotStoredBytes: 2, snapshotDigest: digest, entries: [], totalFileBytes: 0)
        XCTAssertNoThrow(try StreamingBackupRules.validate(manifest))
        manifest.totalFileBytes=Int.max; XCTAssertThrowsError(try StreamingBackupRules.validate(manifest))
        manifest.totalFileBytes=0; manifest.snapshotBytes=1_000_000_001; XCTAssertThrowsError(try StreamingBackupRules.validate(manifest))
        XCTAssertThrowsError(try BackupSnapshotCodec.decode(version: 3, snapshot: raw, encoding: BackupSnapshotCodec.encoding, snapshotBytes: 350 * 1024 * 1024+1, digest: digest))
        XCTAssertThrowsError(try BackupSnapshotCodec.decodeStreamingSnapshot(raw, encoding: BackupSnapshotCodec.rawEncoding, snapshotBytes: 1_000_000_001, digest: digest))
    }

    func testSemanticDigestIgnoresGenerationButBindsHistoryAndExportPayload() throws {
        let f=try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let digest=try f.repository.backupSemanticDigest()
        try f.repository.transaction { _ in }
        XCTAssertEqual(try f.repository.backupSemanticDigest(), digest)
        try f.repository.transaction { $0.terminology["完整业务变更"]="不得漏比较" }
        XCTAssertNotEqual(try f.repository.backupSemanticDigest(), digest)
        let artifact=try XCTUnwrap(f.repository.read().jobs[0].artifacts.first)
        try Data("被改的历史导出".utf8).write(to: URL(fileURLWithPath: artifact.path))
        XCTAssertThrowsError(try f.repository.backupSemanticDigest())
    }

    func testArchiveFileSymlinksAndHardlinksAreRejectedWithoutRecovery() throws {
        let f=try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let original=try backup(f), linked=f.directory.appendingPathComponent("linked.videobackup")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: original)
        XCTAssertThrowsError(try Repository.restore(from: linked, to: f.directory.appendingPathComponent("symlink-cold")))
        try FileManager.default.removeItem(at: linked); try FileManager.default.linkItem(at: original, to: linked)
        XCTAssertThrowsError(try Repository.restore(from: linked, to: f.directory.appendingPathComponent("hardlink-cold")))
    }
}
