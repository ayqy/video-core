import XCTest
import AVFoundation
import VideoCore
@testable import VideoMedia

final class ContentProjectMediaTests:XCTestCase {
    func testOrdinaryJobRendersRealMediaWithoutProductAndBackupRestoresArtifacts()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("content-media-"+UUID().uuidString)
        let restoredRoot=FileManager.default.temporaryDirectory.appendingPathComponent("content-media-restored-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:restoredRoot)}
        let repo=try Repository(root:root),workspace=Workspace(name:"隔离媒体规则",owner:"owner")
        var scene=Scene(title:"观察状态",body:"操作后对照前后结果。",durationFrames:30)
        scene.captions=[Caption(text:"操作后对照前后结果。",startFrame:0,endFrame:30)]
        var revision=try Planner.create(workspaceID:workspace.id,name:"普通教学剪辑",scenes:[scene])
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[],evidence:[])
        let project=Project(workspaceID:workspace.id,name:"普通教学剪辑",revision:revision)
        let quote=Quote(projectID:project.id,revisionID:revision.id,digest:try revision.contentDigest(),upper:Money(0),unit:"CNY",provider:"native",expiresAt:Date().addingTimeInterval(300),confirmed:true)
        let job=try JobRules.submit(workspaceID:workspace.id,project:project,quote:quote,requestKey:"normal",existing:[],budget:BudgetPolicy())
        try repo.transaction{$0.workspaces=[workspace];$0.projects=[project];$0.jobs=[job]}
        let result=try await LocalJobExecutor.run(repository:repo,jobID:job.id,owner:"host-rule")
        XCTAssertEqual(result.state,.needsReview);XCTAssertEqual(result.artifacts.count,4)
        XCTAssertTrue(try repo.read().products.isEmpty);XCTAssertNil(try repo.read().projects[0].current.product)
        try repo.verifyDelivery(result,revision:revision)
        let video=try XCTUnwrap(result.artifacts.first{$0.mime=="video/mp4"})
        let inspection=try await MediaInspection.inspect(URL(fileURLWithPath:video.path))
        XCTAssertEqual(inspection.width,1280);XCTAssertEqual(inspection.height,720);XCTAssertEqual(inspection.duration,1,accuracy:0.1)
        XCTAssertEqual(inspection.videoCodec,"avc1");XCTAssertEqual(inspection.audioCodec,"aac ");XCTAssertEqual(inspection.sampleRate,48000)
        let notes=try XCTUnwrap(result.artifacts.first{$0.mime=="text/plain"})
        let text=try String(contentsOf:URL(fileURLWithPath:notes.path),encoding:.utf8)
        XCTAssertTrue(text.contains("普通教学剪辑"));XCTAssertFalse(text.contains("SKU："));XCTAssertFalse(text.contains("已有承接页："))
        let restored=try Repository.restore(repo.backup(),to:restoredRoot),database=try restored.read()
        XCTAssertTrue(database.products.isEmpty);XCTAssertEqual(database.projects[0].current.schemaVersion,2)
        XCTAssertEqual(database.projects[0].current.contentContext?.id,revision.contentContext?.id)
        let restoredJob=try XCTUnwrap(database.jobs.first{$0.id==job.id});try restored.verifyDelivery(restoredJob,revision:database.projects[0].current)
        XCTAssertEqual(restoredJob.artifacts.map(\.sha256),result.artifacts.map(\.sha256))
    }
    func testEmptyContentDraftCannotRenderOrDrawUnprovenProductPrice()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("content-empty-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let repo=try Repository(root:root),empty=try Planner.create(workspaceID:"w",name:"真实空工程")
        do{_=try await MediaRenderer().render(revision:empty,repository:repo,output:root.appendingPathComponent("rejected"));XCTFail("empty draft rendered")}
        catch{XCTAssertEqual((error as? VideoError)?.exitCode,5)}
        var price=try Planner.create(workspaceID:"w",name:"无商品说明",scenes:[Scene(title:"说明",body:"实际内容",durationFrames:30)])
        price.scenes[0].showPrice=true
        XCTAssertThrowsError(try ScenePainter.image(revision:price,frame:0))
    }
}
