import XCTest
import CSQLite
import Dispatch
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

    private func invokeCLI(_ f:Fixture,dry:Bool=false,principal:String="rules-owner") throws -> (Int32,[String:Any]) {
        guard let executable=ProcessInfo.processInfo.environment["VIDEO_TEST_CLI"] else {throw XCTSkip("需由有限编译批次提供本次正常Release CLI，不能用旧二进制代验")}
        let input:AgentValue = .object(["workspace_id":.string(f.workspaceID),"project_id":.string(f.projectID),"base_revision":.string(f.revisionID),"job_id":.string(f.jobID),"path":.string(f.destination.path),"request_id":.string("isolated-cli-export"),"principal":.string(principal)])
        let process=Process(),stdin=Pipe(),stdout=Pipe(),stderr=Pipe(),done=DispatchSemaphore(value:0)
        process.executableURL=URL(fileURLWithPath:executable)
        process.arguments=["production","export","--workspace",f.repository.root.path,"--input","-"]+(dry ? ["--dry-run"]:[])
        process.standardInput=stdin;process.standardOutput=stdout;process.standardError=stderr
        process.terminationHandler={_ in done.signal()}
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf:Codec.data(input));try stdin.fileHandleForWriting.close()
        if done.wait(timeout:.now()+15) == .timedOut {process.terminate();process.waitUntilExit();throw VideoError.unavailable("隔离CLI导出规则超时；子进程已终止")}
        process.waitUntilExit()
        let bytes=stdout.fileHandleForReading.readDataToEndOfFile(),diagnostics=stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertTrue(diagnostics.isEmpty,"机器协议不得混入诊断")
        return (process.terminationStatus,try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any]))
    }
    func testCLIExportDryRunPublishesExactFourAndRejectsRepeatedDirectory() throws {
        let f=try fixture();defer{remove(f)}
        let before=try f.repository.read(),digest=try Codec.digest(before)
        let dry=try invokeCLI(f,dry:true)
        XCTAssertEqual(dry.0,0);XCTAssertEqual(dry.1["state"] as? String,"dry_run")
        XCTAssertEqual((dry.1["result"] as? [String:Any])?["directory"] as? String,f.final.path)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:f.destination.path).isEmpty)
        XCTAssertEqual(try Codec.digest(f.repository.read()),digest)
        let actual=try invokeCLI(f)
        XCTAssertEqual(actual.0,0);XCTAssertEqual(actual.1["state"] as? String,"files_exported")
        XCTAssertEqual((actual.1["result"] as? [String:Any])?["record_saved"] as? Bool,true)
        let names=["video/mp4":"video.mp4","image/png":"cover.png","application/x-subrip":"subtitles.srt","text/plain":"source.txt"]
        for artifact in before.jobs[0].artifacts {
            let name=try XCTUnwrap(names[artifact.mime])
            XCTAssertEqual(try Data(contentsOf:f.final.appendingPathComponent(name)),try Data(contentsOf:URL(fileURLWithPath:artifact.path)))
        }
        XCTAssertEqual(try f.repository.read().projects[0].deliveryRecords?.count,1)
        let repeated=try invokeCLI(f)
        XCTAssertEqual(repeated.0,6)
        XCTAssertEqual(try f.repository.read().projects[0].deliveryRecords?.count,1)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:f.destination.path)),[f.final.lastPathComponent])
    }
    func testCLIReportsPublishedFilesWithoutRecordAsNonRetryablePartialSuccess() throws {
        let f=try fixture();defer{remove(f)}
        let before=try Codec.digest(f.repository.read())
        var connection:OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(f.repository.root.appendingPathComponent("workspace.sqlite").path,&connection,SQLITE_OPEN_READWRITE,nil),SQLITE_OK)
        defer{sqlite3_close(connection)}
        XCTAssertEqual(sqlite3_exec(connection,"CREATE TRIGGER isolated_cli_export_failure BEFORE INSERT ON snapshot BEGIN SELECT RAISE(ABORT, 'isolated rules write failure'); END;",nil,nil,nil),SQLITE_OK)
        let result=try invokeCLI(f)
        XCTAssertEqual(result.0,8);XCTAssertEqual(result.1["ok"] as? Bool,false)
        XCTAssertEqual(result.1["state"] as? String,"files_exported_record_pending")
        let value=try XCTUnwrap(result.1["result"] as? [String:Any])
        XCTAssertEqual(value["directory"] as? String,f.final.path)
        XCTAssertEqual(value["files_exported"] as? Bool,true);XCTAssertEqual(value["record_saved"] as? Bool,false)
        let failure=try XCTUnwrap(result.1["error"] as? [String:Any])
        XCTAssertEqual(failure["code"] as? String,"delivery_record_pending");XCTAssertEqual(failure["retryable"] as? Bool,false)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:f.final.path)),["video.mp4","cover.png","subtitles.srt","source.txt"])
        XCTAssertEqual(try Codec.digest(f.repository.read()),before)
        XCTAssertNil(try f.repository.read().projects[0].deliveryRecords)
        XCTAssertEqual(try invokeCLI(f).0,6)
    }
    func testCLIUnreviewedAndNonOwnerCallsCannotCreateAnyOutputOrReceipt() throws {
        let f=try fixture();defer{remove(f)}
        XCTAssertEqual(try invokeCLI(f,dry:true,principal:"other").0,3)
        XCTAssertEqual(try invokeCLI(f,principal:"other").0,3)
        try f.repository.transaction{$0.projects[0].revisions[0].review=Review()}
        let before=try Codec.digest(f.repository.read())
        XCTAssertEqual(try invokeCLI(f,dry:true).0,5);XCTAssertEqual(try invokeCLI(f).0,5)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:f.destination.path).isEmpty)
        XCTAssertEqual(try Codec.digest(f.repository.read()),before)
    }
    func testReadOnlyPreviewReportsExactFourWithoutDatabaseOrDestinationChanges() throws {
        let f=try fixture();defer{remove(f)}
        let before=try f.repository.read(),digest=try Codec.digest(before)
        let original=try Dictionary(uniqueKeysWithValues:before.jobs[0].artifacts.map{($0.path,try Data(contentsOf:URL(fileURLWithPath:$0.path)))})
        let repository=try Repository(root:f.repository.root,readOnly:true)
        let plan=try repository.previewProductionExport(projectID:f.projectID,revisionID:f.revisionID,jobID:f.jobID,principal:"rules-owner",destination:f.destination)
        XCTAssertEqual(plan.workspaceID,f.workspaceID);XCTAssertEqual(plan.projectID,f.projectID)
        XCTAssertEqual(plan.revisionID,f.revisionID);XCTAssertEqual(plan.jobID,f.jobID)
        XCTAssertEqual(plan.contentDigest,try before.projects[0].current.contentDigest())
        XCTAssertEqual(plan.directory,f.final.path)
        XCTAssertEqual(Set(plan.artifacts.map(\.name)),["video.mp4","cover.png","subtitles.srt","source.txt"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:plan.artifacts.map{($0.mime,$0.sha256)}),Dictionary(uniqueKeysWithValues:before.jobs[0].artifacts.map{($0.mime,$0.sha256)}))
        XCTAssertEqual(try Codec.decoder().decode(ProductionExportPlan.self,from:Codec.data(plan)),plan)
        XCTAssertEqual(try Codec.digest(f.repository.read()),digest)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:f.destination.path).isEmpty)
        for (path,bytes) in original {XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path)),bytes)}
    }
    func testPreviewRejectsStaleUnreviewedAndUnauthorizedTargetsWithoutStaging() throws {
        let f=try fixture();defer{remove(f)}
        let repository=try Repository(root:f.repository.root,readOnly:true)
        for (revision,job,principal) in [("old",f.jobID,"rules-owner"),(f.revisionID,"missing","rules-owner"),(f.revisionID,f.jobID,"other")] {
            XCTAssertThrowsError(try repository.previewProductionExport(projectID:f.projectID,revisionID:revision,jobID:job,principal:principal,destination:f.destination))
        }
        try f.repository.transaction{$0.projects[0].revisions[0].review=Review()}
        XCTAssertThrowsError(try repository.previewProductionExport(projectID:f.projectID,revisionID:f.revisionID,jobID:f.jobID,principal:"rules-owner",destination:f.destination))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:f.destination.path).isEmpty)
        XCTAssertNil(try f.repository.read().projects[0].deliveryRecords)
    }
    func testPreviewRejectsChangedOriginalAndExistingOutputWithoutDeletingEither() throws {
        for changedOriginal in [true,false] {
            let f=try fixture();defer{remove(f)}
            let changed:URL
            if changedOriginal {changed=URL(fileURLWithPath:try f.repository.read().jobs[0].artifacts[0].path)}
            else {try FileManager.default.createDirectory(at:f.final,withIntermediateDirectories:false);changed=f.final.appendingPathComponent("user-file.txt")}
            let bytes=Data("preserve changed or existing file".utf8);try bytes.write(to:changed)
            let repository=try Repository(root:f.repository.root,readOnly:true)
            XCTAssertThrowsError(try repository.previewProductionExport(projectID:f.projectID,revisionID:f.revisionID,jobID:f.jobID,principal:"rules-owner",destination:f.destination))
            XCTAssertEqual(try Data(contentsOf:changed),bytes)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:f.destination.path).contains{$0.hasSuffix(".preparing")})
            XCTAssertNil(try f.repository.read().projects[0].deliveryRecords)
        }
    }
    func testPreviewAndPrepareRefuseADanglingDestinationLinkWithoutReplacingIt() throws {
        let f=try fixture();defer{remove(f)}
        let missing=f.directory.appendingPathComponent("missing-original")
        try FileManager.default.createSymbolicLink(at:f.final,withDestinationURL:missing)
        let repository=try Repository(root:f.repository.root,readOnly:true)
        XCTAssertThrowsError(try repository.previewProductionExport(projectID:f.projectID,revisionID:f.revisionID,jobID:f.jobID,principal:"rules-owner",destination:f.destination))
        XCTAssertThrowsError(try prepare(f))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:f.final.path),missing.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:f.destination.path),[f.final.lastPathComponent])
    }
    func testPreviewCannotReserveADirectoryOrAuthorizeLaterChangedReview() throws {
        let f=try fixture();defer{remove(f)}
        let repository=try Repository(root:f.repository.root,readOnly:true)
        _=try repository.previewProductionExport(projectID:f.projectID,revisionID:f.revisionID,jobID:f.jobID,principal:"rules-owner",destination:f.destination)
        XCTAssertThrowsError(try repository.prepareProductionExport(projectID:f.projectID,revisionID:f.revisionID,jobID:f.jobID,principal:"rules-owner",destination:f.destination))
        try f.repository.transaction{$0.projects[0].revisions[0].review.rights=false}
        XCTAssertThrowsError(try prepare(f))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:f.destination.path).isEmpty)
    }
    func testLegacyExpiredBriefBlocksPreviewAndPrepareDespiteMatchingReviewedArtifacts() throws {
        let f=try fixture(withProduct:true);defer{remove(f)}
        try f.repository.transaction { db in
            var revision=db.projects[0].current
            revision.productionBrief=ProductionBrief(objective:"仅隔离规则",intendedUse:"期限检查",evidenceIDs:[db.evidence[0].id],permittedUntil:Date().addingTimeInterval(-1),approvalRequired:false)
            revision.review.digest=try revision.contentDigest()
            db.projects[0].revisions[0]=revision
            db.jobs[0].digest=try revision.contentDigest();db.jobs[0].quote.digest=try revision.contentDigest()
        }
        let repository=try Repository(root:f.repository.root,readOnly:true)
        XCTAssertThrowsError(try repository.previewProductionExport(projectID:f.projectID,revisionID:f.revisionID,jobID:f.jobID,principal:"rules-owner",destination:f.destination))
        XCTAssertThrowsError(try prepare(f))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:f.destination.path).isEmpty)
    }
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
