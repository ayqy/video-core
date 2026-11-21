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
        let cover=try XCTUnwrap(result.artifacts.first{$0.mime=="image/png"})
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:URL(fileURLWithPath:video.path)))
        generator.appliesPreferredTrackTransform=true;generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let first=try generator.copyCGImage(at:.zero,actualTime:nil)
        let expected=try CoverPainter.image(revision:revision,source:first)
        XCTAssertEqual(cover.sha256,Codec.hash(try ScenePainter.png(expected)),"封面应由同版成片画面经模板独立合成，不重新进入高级渲染器")
        XCTAssertNotEqual(cover.sha256,Codec.hash(try ScenePainter.png(first)),"默认封面须有特色标题版式，不能继续直接取首帧")
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

    func testCoverOnlyRevisionsReuseTheVerifiedMovieAndSubtitlesAcrossGenerations() async throws {
        let root = temporaryWorkspace()
        let restoredRoot = temporaryWorkspace()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: restoredRoot)
        }
        let (repo, parent, original) = try await renderCoverReuseParent(at: root)
        let (_, unscheduled) = try appendCover("第一版封面", to: repo, submit: false)
        XCTAssertNil(unscheduled)
        let originalMovie = try artifact("video/mp4", in: original)
        let originalCaptions = try artifact("application/x-subrip", in: original)
        let movieBytes = try Data(contentsOf: URL(fileURLWithPath: originalMovie.path))
        let captionBytes = try Data(contentsOf: URL(fileURLWithPath: originalCaptions.path))
        var previousCover = try artifact("image/png", in: original).sha256
        var finished = [(parent, original)]

        for title in ["为什么差一枚？", "谁先拿出那一枚？"] {
            let (revision, queuedJob) = try appendCover(title, to: repo)
            let job = try XCTUnwrap(queuedJob)
            let result = try await LocalJobExecutor.run(repository: repo, jobID: job.id,
                owner: "cover-test-worker", principal: "owner")
            XCTAssertEqual(result.state, .needsReview)
            XCTAssertTrue(result.message.contains("封面独立重绘"))
            XCTAssertEqual(result.revisionID, revision.id)
            XCTAssertEqual(result.digest, try revision.contentDigest())
            XCTAssertEqual(result.quote.revisionID, revision.id)
            XCTAssertEqual(result.actual, Money(0))
            XCTAssertFalse(revision.review.complete)
            try repo.verifyDelivery(result, revision: revision)
            for item in result.artifacts {
                XCTAssertEqual(item.revision, revision.id)
                XCTAssertEqual(URL(fileURLWithPath: item.path).deletingLastPathComponent().lastPathComponent, job.id)
            }
            let movie = try artifact("video/mp4", in: result)
            let captions = try artifact("application/x-subrip", in: result)
            XCTAssertEqual(movie.sha256, originalMovie.sha256)
            XCTAssertEqual(captions.sha256, originalCaptions.sha256)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: movie.path)), movieBytes)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: captions.path)), captionBytes)
            let cover = try artifact("image/png", in: result)
            XCTAssertNotEqual(cover.sha256, previousCover)
            previousCover = cover.sha256
            let notes = try artifact("text/plain", in: result)
            let text = try String(contentsOf: URL(fileURLWithPath: notes.path), encoding: .utf8)
            XCTAssertTrue(text.contains(revision.id))
            XCTAssertTrue(text.contains(title))
            finished.append((revision, result))
        }

        let restored = try Repository.restore(repo.backup(), to: restoredRoot)
        let restoredJobs = try restored.read().jobs
        for (revision, job) in finished {
            let restoredJob = try XCTUnwrap(restoredJobs.first { $0.id == job.id })
            try restored.verifyDelivery(restoredJob, revision: revision)
            XCTAssertEqual(restoredJob.artifacts.map(\.sha256), job.artifacts.map(\.sha256))
        }
    }

    func testCoverReuseRequiresPermissionToReadTheParentRevision() async throws {
        let root = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, parent, original) = try await renderCoverReuseParent(at: root)
        let (child, queuedJob) = try appendCover("只授权新版的封面", to: repo)
        let job = try XCTUnwrap(queuedJob)
        try repo.transaction { database in
            database.workspaces[0].grants = [Grant(principal: "editor", role: .collaborator,
                projectIDs: [job.projectID], revisionIDs: [child.id], expiresAt: Date().addingTimeInterval(300))]
        }
        let workspace = try repo.read().workspace(job.workspaceID)
        XCTAssertThrowsError(try workspace.authorize(principal: "editor", project: job.projectID, revision: parent.id))
        let (movie, damagedBytes) = try damageMovie(in: original)

        let rendered = try await LocalJobExecutor.run(repository: repo, jobID: job.id,
            owner: "cover-test-worker", principal: "editor")
        XCTAssertEqual(rendered.state, .needsReview)
        XCTAssertFalse(rendered.message.contains("封面独立重绘"))
        try repo.verifyDelivery(rendered, revision: child)
        XCTAssertEqual(try Data(contentsOf: movie), damagedBytes)
    }

    func testCoverReuseFailsWhenTheSelectedParentArtifactIsDamaged() async throws {
        let root = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, _, original) = try await renderCoverReuseParent(at: root)
        let (_, queuedJob) = try appendCover("损坏父版仍需保留", to: repo)
        let job = try XCTUnwrap(queuedJob)
        let (movie, damagedBytes) = try damageMovie(in: original)

        do {
            _ = try await LocalJobExecutor.run(repository: repo, jobID: job.id,
                owner: "cover-test-worker", principal: "owner")
            XCTFail("损坏的已选父作业应失败，不能回退到重新编码")
        } catch {
            XCTAssertNotNil(error as? VideoError)
        }
        let jobs = try repo.read().jobs
        let failed = try XCTUnwrap(jobs.first { $0.id == job.id })
        XCTAssertEqual(failed.state, .interrupted)
        XCTAssertTrue(failed.artifacts.isEmpty)
        let historical = try XCTUnwrap(jobs.first { $0.id == original.id })
        XCTAssertEqual(try Codec.digest(historical), try Codec.digest(original))
        XCTAssertEqual(try Data(contentsOf: movie), damagedBytes)
    }

    func testCoverReuseRechecksRevocationBeforePublishing() async throws {
        let root = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, parent, original) = try await renderCoverReuseParent(at: root)
        let (child, queuedJob) = try appendCover("权限撤销前的封面", to: repo)
        let job = try XCTUnwrap(queuedJob)
        try repo.transaction { database in
            database.workspaces[0].grants = [Grant(principal: "editor", role: .collaborator,
                projectIDs: [job.projectID], revisionIDs: [parent.id, child.id],
                expiresAt: Date().addingTimeInterval(300))]
        }
        do {
            _ = try await LocalJobExecutor.run(repository: repo, jobID: job.id,
                owner: "cover-test-worker", principal: "editor", progress: { value in
                    if value == 0.5 {
                        try? repo.transaction { $0.workspaces[0].grants[0].revoked = true }
                    }
                })
            XCTFail("已撤销的授权不可发布复用产物")
        } catch {
            XCTAssertEqual((error as? VideoError)?.exitCode, VideoError.permission("").exitCode)
        }
        let saved = try repo.read()
        let revoked = try XCTUnwrap(saved.workspaces[0].grants.first)
        let interrupted = try XCTUnwrap(saved.jobs.first { $0.id == job.id })
        XCTAssertTrue(revoked.revoked)
        XCTAssertEqual(interrupted.state, .interrupted)
        XCTAssertTrue(interrupted.artifacts.isEmpty)
        let output = repo.root.appendingPathComponent("exports/" + job.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
        try repo.verifyDelivery(original, revision: parent)
    }

    private func temporaryWorkspace() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cover-reuse-" + UUID().uuidString)
    }

    private func renderCoverReuseParent(at root: URL) async throws -> (Repository, Revision, Job) {
        let repo = try Repository(root: root)
        let workspace = Workspace(name: "封面局部复用", owner: "owner")
        var scene = Scene(title: "观察状态", body: "操作后对照前后结果。", durationFrames: 30)
        scene.captions = [Caption(text: "操作后对照前后结果。", startFrame: 0, endFrame: 30)]
        var revision = try Planner.create(workspaceID: workspace.id, name: "普通教学剪辑", scenes: [scene])
        revision.dependencies = try DependencyRules.freeze(revision: revision, assets: [], evidence: [])
        let project = Project(workspaceID: workspace.id, name: "普通教学剪辑", revision: revision)
        let queued = try repo.transaction { database in
            database.workspaces = [workspace]
            database.projects = [project]
            return try queue(project, in: &database)
        }
        let rendered = try await LocalJobExecutor.run(repository: repo, jobID: queued.id,
            owner: "cover-test-worker", principal: "owner")
        try repo.verifyDelivery(rendered, revision: revision)
        return (repo, revision, rendered)
    }

    private func appendCover(_ title: String, to repo: Repository, submit: Bool = true) throws -> (Revision, Job?) {
        try repo.transaction { database in
            let previous = database.projects[0]
            let cover = CoverPresentation(style: .pencil, template: .contrast, title: title)
            var project = try Editor.apply([.coverPresentation(cover)], to: previous,
                baseRevision: previous.current.id, assets: database.assets, message: "更换封面标题")
            project.revisions[project.revisions.count - 1].dependencies = try DependencyRules.freeze(
                revision: project.current, assets: database.assets, evidence: database.evidence)
            database.projects[0] = project
            let job = submit ? try queue(project, in: &database) : nil
            return (project.current, job)
        }
    }

    private func queue(_ project: Project, in database: inout Database) throws -> Job {
        let revision = project.current
        let quote = Quote(projectID: project.id, revisionID: revision.id, digest: try revision.contentDigest(),
            upper: Money(0), unit: "CNY", provider: "native", expiresAt: Date().addingTimeInterval(300), confirmed: true)
        let job = try JobRules.submit(workspaceID: project.workspaceID, project: project, quote: quote,
            requestKey: UUID().uuidString, existing: database.jobs, budget: database.budget)
        database.jobs.append(job)
        return job
    }

    private func artifact(_ mime: String, in job: Job) throws -> Artifact {
        try XCTUnwrap(job.artifacts.first { $0.mime == mime })
    }

    private func damageMovie(in job: Job) throws -> (URL, Data) {
        let path = URL(fileURLWithPath: try artifact("video/mp4", in: job).path)
        let damaged = Data("已损坏的测试制片原件".utf8)
        try damaged.write(to: path, options: .atomic)
        return (path, damaged)
    }
}
