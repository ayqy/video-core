import XCTest
@testable import VideoCore

final class BackupSnapshotCodecTests: XCTestCase {
    private func fixture(large: Bool) throws -> (URL, Repository, Asset) {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-backup-"+UUID().uuidString)
        let repository=try Repository(root:directory.appendingPathComponent("source"))
        let workspace=Workspace(name:"完整历史与来源",owner:"local")
        let asset=try repository.ingest(Data("原素材字节保持".utf8),name:"source.txt",workspaceID:workspace.id,mediaType:"text")
        var revision=try Planner.create(workspaceID:workspace.id,name:"历史工程",scenes:[Scene(title:"保留场景",body:"保留原内容。",durationFrames:60)])
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[asset],evidence:[])
        var project=Project(workspaceID:workspace.id,name:"历史工程",revision:revision)
        for index in 1...3 {
            project=try Editor.apply([.cta("第\(index)次明确编辑")],to:project,baseRevision:project.current.id,assets:[asset],message:"保留前序历史")
            project.revisions[project.revisions.count-1].dependencies=try DependencyRules.freeze(revision:project.current,assets:[asset],evidence:[])
        }
        try repository.transaction { state in
            state.workspaces=[workspace];state.assets=[asset];state.projects=[project]
            if large {state.terminology["原样保留的大快照边界"]=String(repeating:"原样中文/UTF-8/12345；",count:60000)}
        }
        return(directory,repository,asset)
    }
    private func archive(_ data:Data)throws->Repository.Backup {
        try PropertyListDecoder().decode(Repository.Backup.self,from:data)
    }
    private func reject(_ value:Repository.Backup,directory:URL,label:String)throws {
        let target=directory.appendingPathComponent(label)
        XCTAssertThrowsError(try Repository.restore(PropertyListEncoder().encode(value),to:target))
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path),"无效封套在建目录前拒绝")
    }

    func testLargeNormalBackupCompressesExactJSONAndRetainsAllHistorySourcesAndReview()throws {
        let(directory,repository,asset)=try fixture(large:true);defer{try? FileManager.default.removeItem(at:directory)}
        let before=try repository.read(),beforeJSON=try Codec.data(before)
        let data=try repository.backup(),value=try archive(data)
        XCTAssertEqual(value.version,3);XCTAssertEqual(value.snapshotEncoding,BackupSnapshotCodec.encoding)
        XCTAssertEqual(value.snapshotBytes,beforeJSON.count)
        XCTAssertLessThan(value.snapshot.count,beforeJSON.count/4)
        XCTAssertEqual(try value.decodedSnapshot(),beforeJSON)
        XCTAssertEqual(try Codec.data(repository.read()),beforeJSON,"备份不改在线SQLite JSON或业务内容")
        let restored=try Repository.restore(data,to:directory.appendingPathComponent("cold"))
        let after=try restored.read();var expected=before;expected.generation=after.generation
        XCTAssertEqual(try Codec.data(after),try Codec.data(expected))
        XCTAssertEqual(after.projects[0].revisions.count,4)
        XCTAssertEqual(try Data(contentsOf:restored.assetURL(asset)),Data("原素材字节保持".utf8))
    }

    func testSmallBackupStaysVersionTwoAndBothLegacyVersionsStillRestore()throws {
        let(directory,repository,_)=try fixture(large:false);defer{try? FileManager.default.removeItem(at:directory)}
        let data=try repository.backup(),value=try archive(data)
        XCTAssertEqual(value.version,2);XCTAssertNil(value.snapshotEncoding);XCTAssertNil(value.snapshotBytes)
        for version in [1,2] {
            var legacy=value;legacy.version=version
            let restored=try Repository.restore(PropertyListEncoder().encode(legacy),to:directory.appendingPathComponent("legacy-\(version)"))
            XCTAssertEqual(try restored.read().projects[0].revisions.count,4)
        }
    }

    func testRFC1951RawDeflateFixtureIsPortableAndDigestBindsDecodedBytes()throws {
        let raw=Data("{\"sample\":\"standard raw deflate\"}".utf8)
        let compressed=Data([171,86,42,78,204,45,200,73,85,178,82,42,46,73,204,75,73,44,74,81,40,74,44,87,72,73,77,203,73,44,73,85,170,5,0])
        XCTAssertEqual(try BackupSnapshotCodec.decode(version:3,snapshot:compressed,encoding:BackupSnapshotCodec.encoding,
            snapshotBytes:raw.count,digest:Codec.hash(raw)),raw)
        let encoded=try BackupSnapshotCodec.compress(raw)
        XCTAssertEqual(try BackupSnapshotCodec.decode(version:3,snapshot:encoded,encoding:BackupSnapshotCodec.encoding,
            snapshotBytes:raw.count,digest:Codec.hash(raw)),raw)
    }

    func testTruncatedTrailingAndConcatenatedStreamsFailBeforeRestoreWrites()throws {
        let(directory,repository,_)=try fixture(large:true);defer{try? FileManager.default.removeItem(at:directory)}
        let original=try archive(repository.backup())
        for mutation in ["truncated","trailing","concatenated"] {
            var value=original
            if mutation=="truncated" {value.snapshot.removeLast()}
            if mutation=="trailing" {value.snapshot.append(0)}
            if mutation=="concatenated" {value.snapshot.append(original.snapshot)}
            try reject(value,directory:directory,label:mutation)
        }
    }

    func testWrongDeclaredLengthsDigestAndEncodingFailBeforeRestoreWrites()throws {
        let(directory,repository,_)=try fixture(large:true);defer{try? FileManager.default.removeItem(at:directory)}
        let original=try archive(repository.backup())
        for mutation in ["short","long","digest","encoding","missing","oversized"] {
            var value=original
            if mutation=="short" {value.snapshotBytes=value.snapshotBytes!-1}
            if mutation=="long" {value.snapshotBytes=value.snapshotBytes!+1}
            if mutation=="digest" {value.digest=String(repeating:"0",count:64)}
            if mutation=="encoding" {value.snapshotEncoding="unknown"}
            if mutation=="missing" {value.snapshotBytes=nil}
            if mutation=="oversized" {value.snapshotBytes=BackupSnapshotCodec.maximumSnapshotBytes+1}
            try reject(value,directory:directory,label:mutation)
        }
    }

    func testExpansionCannotExceedSmallDeclaredBudgetEvenForHighlyCompressedInput()throws {
        let raw=Data(repeating:65,count:2*1024*1024),compressed=try BackupSnapshotCodec.compress(raw)
        XCTAssertLessThan(compressed.count,raw.count/100)
        XCTAssertThrowsError(try BackupSnapshotCodec.decode(version:3,snapshot:compressed,
            encoding:BackupSnapshotCodec.encoding,snapshotBytes:1,digest:Codec.hash(raw)))
        XCTAssertThrowsError(try BackupSnapshotCodec.decode(version:3,snapshot:compressed,
            encoding:BackupSnapshotCodec.encoding,snapshotBytes:BackupSnapshotCodec.maximumSnapshotBytes+1,digest:Codec.hash(raw)))
    }

    func testUnknownVersionsAndCompressionMetadataOnLegacySnapshotsAreRejected()throws {
        let raw=Data("{}".utf8)
        for version in [0,4] {
            XCTAssertThrowsError(try BackupSnapshotCodec.decode(version:version,snapshot:raw,encoding:nil,snapshotBytes:nil,digest:Codec.hash(raw)))
        }
        for version in [1,2] {
            XCTAssertThrowsError(try BackupSnapshotCodec.decode(version:version,snapshot:raw,
                encoding:BackupSnapshotCodec.encoding,snapshotBytes:raw.count,digest:Codec.hash(raw)))
        }
    }

    func testCompressedRestoreStillRejectsUnregisteredSourceFilesAndExtraExports()throws {
        let(directory,repository,_)=try fixture(large:true);defer{try? FileManager.default.removeItem(at:directory)}
        let original=try archive(repository.backup())
        var extraSource=original;extraSource.assets["assets/unregistered.txt"]=Data("extra".utf8)
        try reject(extraSource,directory:directory,label:"extra-source")
        var extraExport=original;extraExport.exports=["exports/unregistered/video.mp4":Data("extra".utf8)]
        try reject(extraExport,directory:directory,label:"extra-export")
    }

    func testCompressedRestoreRetainsVisualCacheValidationAndNewDirectoryGuard()throws {
        let(directory,repository,_)=try fixture(large:true);defer{try? FileManager.default.removeItem(at:directory)}
        let original=try archive(repository.backup())
        var badCache=original;badCache.visualCache=["bad.mp4":Data("not a registered hint".utf8)]
        try reject(badCache,directory:directory,label:"bad-cache")
        let target=directory.appendingPathComponent("already-exists")
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        let marker=target.appendingPathComponent("retained.txt");try Data("keep".utf8).write(to:marker)
        XCTAssertThrowsError(try Repository.restore(PropertyListEncoder().encode(original),to:target))
        XCTAssertEqual(try Data(contentsOf:marker),Data("keep".utf8))
    }
}
