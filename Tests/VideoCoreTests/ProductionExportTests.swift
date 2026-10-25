import XCTest
import CSQLite
@testable import VideoCore

/// Disposable protocol fixtures, not real videos, prices or human review evidence.
final class ProductionExportTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let destination: URL
        let repository: Repository
        let workspaceID: String
        let projectID: String
        let revisionID: String
        let jobID: String
        var final: URL { destination.appendingPathComponent("隔离导出规则-v1",isDirectory:true) }
    }
    private func fixture(withProduct:Bool=false) throws -> Fixture {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("video-export-rules-"+Codec.id())
        let repository=try Repository(root:directory.appendingPathComponent("workspace"))
        let destination=directory.appendingPathComponent("chosen-output")
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        let workspace=Workspace(name:"隔离文件导出规则",owner:"rules-owner")
        var evidence=Evidence(workspaceID:workspace.id,title:"规则资料",source:"isolated-test-document",claim:"仅为确定性规则输入",owner:"规则作者",commercialAllowed:false,verified:true)
        evidence.checkedAt=Date().addingTimeInterval(-5);evidence.expiresAt=Date().addingTimeInterval(3600)
        var scene=Scene(title:"隔离规则",body:"这些文件不是实际媒体，不代表真实看听审核。",durationFrames:60)
        scene.evidenceIDs=[evidence.id]
        var products:[Product]=[]
        var revision=try Planner.create(workspaceID:workspace.id,name:"隔离导出规则",aspect:.landscape,scenes:[scene])
        if withProduct {
            var product=Product(workspaceID:workspace.id,sku:"RULES-ONLY",name:"隔离价格条件",checkout:"https://example.org/isolated-rules",audience:"规则测试",task:"核对失效",outcome:"不导出旧版",prerequisite:"仅测试",scope:"不是实际商品或售价",prices:[Price(money:Money(99),from:.distantPast,source:"仅隔离规则条件，不代表真实价格",verified:true)])
            product.isExample=true;products=[product]
            revision=Revision(product:product,purpose:.education,aspect:.landscape,scenes:[scene],cta:"")
        }
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[],evidence:[evidence])
        revision.review.text=true;revision.review.rights=true;revision.review.sound=true
        revision.review.captions=true;revision.review.fullPreview=true
        revision.review.digest=try revision.contentDigest();revision.review.at=Date()
        revision.review.reviewer="隔离规则声明，不是实际人审"
        let project=Project(workspaceID:workspace.id,name:"隔离导出规则",revision:revision)
        let digest=try revision.contentDigest()
        let quote=Quote(projectID:project.id,revisionID:revision.id,digest:digest,upper:Money(0),unit:"CNY",provider:"native",expiresAt:Date().addingTimeInterval(3600),confirmed:true)
        var job=Job(workspaceID:workspace.id,projectID:project.id,revisionID:revision.id,digest:digest,requestKey:"isolated-rules",quote:quote)
        job.state = .succeeded
        let names=[("video/mp4","video.mp4"),("image/png","cover.png"),("application/x-subrip","captions.srt"),("text/plain","publication.txt")]
        let files=repository.root.appendingPathComponent("exports/"+job.id)
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        for (mime,name) in names {
            let data=Data(("isolated protocol bytes: "+name).utf8),path=files.appendingPathComponent(name)
            try data.write(to:path)
            job.artifacts.append(Artifact(path:path.path,mime:mime,bytes:data.count,sha256:Codec.hash(data),revision:revision.id))
        }
        try repository.transaction{db in db.workspaces=[workspace];db.projects=[project];db.products=products;db.evidence=[evidence];db.jobs=[job]}
        XCTAssertTrue(try Quality.inspect(revision,database:repository.read(),requireReview:true).isEmpty)
        return Fixture(directory:directory,destination:destination,repository:repository,workspaceID:workspace.id,projectID:project.id,revisionID:revision.id,jobID:job.id)
    }
    private func prepare(_ f:Fixture) throws -> PreparedProductionExport {
        try f.repository.prepareProductionExport(projectID:f.projectID,revisionID:f.revisionID,jobID:f.jobID,principal:"rules-owner",destination:f.destination)
    }
    private func staging(_ f:Fixture) throws -> URL {
        try XCTUnwrap(FileManager.default.contentsOfDirectory(at:f.destination,includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasSuffix(".preparing")})
    }
    private func remove(_ f:Fixture) { try? FileManager.default.removeItem(at:f.directory) }

    func testTwoPhaseExportPublishesExactFourAndRecordsWithoutReapproval() throws {
        let f=try fixture();defer{remove(f)}
        let before=try f.repository.read(),prepared=try prepare(f)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.final.path))
        XCTAssertEqual(try f.repository.read().generation,before.generation)
        let result=try f.repository.publishProductionExport(prepared)
        XCTAssertEqual(result.directory,f.final);XCTAssertTrue(result.recordSaved)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:f.final.path)),["video.mp4","cover.png","subtitles.srt","source.txt"])
        let after=try f.repository.read()
        XCTAssertEqual(after.projects[0].revisions.count,before.projects[0].revisions.count)
        XCTAssertEqual(try Codec.digest(after.projects[0].current),try Codec.digest(before.projects[0].current))
        XCTAssertEqual(after.projects[0].deliveryRecords?.count,1)
        XCTAssertThrowsError(try f.repository.publishProductionExport(prepared))
        prepared.cancel();XCTAssertTrue(FileManager.default.fileExists(atPath:f.final.path))
    }

    func testSecondRepositoryVersionChangeAfterCopyRejectsBeforeFinalDirectoryExists() throws {
        let f=try fixture();defer{remove(f)}
        let prepared=try prepare(f),other=try Repository(root:f.repository.root)
        try other.transaction { db in
            var scene=db.projects[0].current.scenes[0];scene.body="另一调用已实际改动版本。"
            db.projects[0]=try Editor.apply([.replaceScene(scene.id,scene)],to:db.projects[0],baseRevision:f.revisionID,assets:[],message:"隔离并发规则")
        }
        XCTAssertThrowsError(try f.repository.publishProductionExport(prepared))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.final.path))
        XCTAssertEqual(try other.read().projects[0].revisions.count,2)
        XCTAssertNil(try other.read().projects[0].deliveryRecords)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:f.destination.path).isEmpty)
    }

    func testFactAndIsolatedPriceChangesAfterCopyCannotPublishFrozenFour() throws {
        for price in [false,true] {
            let f=try fixture(withProduct:price);defer{remove(f)}
            let prepared=try prepare(f),other=try Repository(root:f.repository.root)
            try other.transaction { db in
                if price {db.products[0].prices[0].money=Money(200)}
                else {db.evidence[0].claim="规则输入的适用范围发生变化"}
            }
            XCTAssertThrowsError(try f.repository.publishProductionExport(prepared))
            XCTAssertFalse(FileManager.default.fileExists(atPath:f.final.path))
            XCTAssertNil(try other.read().projects[0].deliveryRecords)
        }
    }

    func testRestoreCreatesANewUnreviewedRevisionRatherThanReusingPreparedPermit() throws {
        let f=try fixture();defer{remove(f)}
        let prepared=try prepare(f),other=try Repository(root:f.repository.root)
        try other.transaction { db in
            db.projects[0]=try Editor.apply([.restore(f.revisionID)],to:db.projects[0],baseRevision:f.revisionID,assets:[],message:"隔离恢复规则")
        }
        XCTAssertThrowsError(try f.repository.publishProductionExport(prepared))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.final.path))
        XCTAssertFalse(try other.read().projects[0].current.review.complete)
    }

    func testChangedArtifactIndexOrStagedFileRejectsWithoutFinalOutput() throws {
        let f=try fixture();defer{remove(f)}
        let prepared=try prepare(f)
        try Data("changed staged bytes".utf8).write(to:try staging(f).appendingPathComponent("video.mp4"))
        XCTAssertThrowsError(try f.repository.publishProductionExport(prepared))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.final.path))
        XCTAssertNil(try f.repository.read().projects[0].deliveryRecords)
        let second=try prepare(f),other=try Repository(root:f.repository.root)
        try other.transaction{$0.jobs[0].artifacts[0].sha256=String(repeating:"f",count:64)}
        XCTAssertThrowsError(try f.repository.publishProductionExport(second))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.final.path))
    }

    func testExistingUserDirectoryCreatedAfterPrepareIsNeverOverwrittenOrDeleted() throws {
        let f=try fixture();defer{remove(f)}
        let prepared=try prepare(f)
        try FileManager.default.createDirectory(at:f.final,withIntermediateDirectories:false)
        let keep=f.final.appendingPathComponent("existing-user-file.txt"),data=Data("keep original output".utf8)
        try data.write(to:keep)
        XCTAssertThrowsError(try f.repository.publishProductionExport(prepared))
        XCTAssertEqual(try Data(contentsOf:keep),data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:f.final.path),["existing-user-file.txt"])
        prepared.cancel();XCTAssertEqual(try Data(contentsOf:keep),data)
    }

    func testExtraFileOrReplacedStageIsPreservedRatherThanDeletingUnknownUserData() throws {
        let f=try fixture();defer{remove(f)}
        let prepared=try prepare(f),stage=try staging(f)
        let keep=stage.appendingPathComponent("unexpected-user-file.txt"),data=Data("preserve unknown".utf8)
        try data.write(to:keep)
        XCTAssertThrowsError(try f.repository.publishProductionExport(prepared))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.final.path))
        XCTAssertEqual(try Data(contentsOf:keep),data)
    }

    func testUnrelatedProjectChangesDoNotInvalidateThisTargetExport() throws {
        let f=try fixture();defer{remove(f)}
        let prepared=try prepare(f),other=try Repository(root:f.repository.root)
        try other.transaction { db in
            let revision=try Planner.create(workspaceID:f.workspaceID,name:"不相关兄弟",scenes:[])
            db.projects.append(Project(workspaceID:f.workspaceID,name:"不相关兄弟",revision:revision))
        }
        XCTAssertTrue(try f.repository.publishProductionExport(prepared).recordSaved)
        XCTAssertEqual(try other.read().projects.count,2)
        XCTAssertEqual(try other.read().projects[0].deliveryRecords?.count,1)
    }

    func testReadOnlyAndUnreviewedInputsCannotEvenCreateStaging() throws {
        let f=try fixture();defer{remove(f)}
        let readOnly=try Repository(root:f.repository.root,readOnly:true)
        XCTAssertThrowsError(try readOnly.prepareProductionExport(projectID:f.projectID,revisionID:f.revisionID,jobID:f.jobID,principal:"rules-owner",destination:f.destination))
        try f.repository.transaction{$0.projects[0].revisions[0].review=Review()}
        XCTAssertThrowsError(try prepare(f))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:f.destination.path).isEmpty)
    }

    func testSQLiteWriteFailureAfterRenamePreservesVerifiedOutputAndReportsMissingRecord() throws {
        let f=try fixture();defer{remove(f)}
        let prepared=try prepare(f)
        // Real SQLite failure in a disposable rules database; no production fault hook.
        var connection:OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(f.repository.root.appendingPathComponent("workspace.sqlite").path,&connection,SQLITE_OPEN_READWRITE,nil),SQLITE_OK)
        defer{sqlite3_close(connection)}
        XCTAssertEqual(sqlite3_exec(connection,"CREATE TRIGGER isolated_export_write_failure BEFORE INSERT ON snapshot BEGIN SELECT RAISE(ABORT, 'isolated rules write failure'); END;",nil,nil,nil),SQLITE_OK)
        let result=try f.repository.publishProductionExport(prepared)
        XCTAssertEqual(result.directory,f.final);XCTAssertFalse(result.recordSaved)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:f.final.path)),["video.mp4","cover.png","subtitles.srt","source.txt"])
        XCTAssertNil(try f.repository.read().projects[0].deliveryRecords)
        XCTAssertThrowsError(try f.repository.publishProductionExport(prepared))
        prepared.cancel();XCTAssertTrue(FileManager.default.fileExists(atPath:f.final.path))
    }
}
