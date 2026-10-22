import XCTest
@testable import VideoCore

final class PublicationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private func fixture() throws -> (Database, Project, Job, Publication) {
        var db = Database(); var workspace = Workspace(name: "隔离发布规则测试", owner: "test"); workspace.id = "w"; db.workspaces = [workspace]
        let product = Product(workspaceID: "w", sku: "existing", name: "材料整理课", checkout: "https://example.org/existing", audience: "需要整理材料的人", task: "整理一段原文", outcome: "写一条有来源的结论", prerequisite: "中文阅读", scope: "材料标注", prices: [Price(money: Money(99), from: .distantPast, source: "独立规则测试凭证", verified: true)])
        db.products = [product]
        var revision = Revision(product: product, purpose: .education, aspect: .portrait, scenes: [Scene(title: "回到原文", body: "先提问题，再核对原文依据。")], cta: "打开原文练习一次")
        revision.dependencies = try DependencyRules.freeze(revision: revision, assets: [], evidence: [], now: now)
        revision.review.text = true; revision.review.rights = true; revision.review.fullPreview = true; revision.review.sound = true; revision.review.captions = true; revision.review.reviewer = "隔离测试声明"; revision.review.at = now.addingTimeInterval(-60); revision.review.digest = try revision.contentDigest()
        let project = Project(workspaceID: "w", name: "隔离发布项目", revision: revision); db.projects = [project]
        let quote = Quote(projectID: project.id, revisionID: revision.id, digest: try revision.contentDigest(), upper: Money(0), unit: "CNY", provider: "native", expiresAt: now.addingTimeInterval(3600), confirmed: true)
        var job = Job(workspaceID: "w", projectID: project.id, revisionID: revision.id, digest: try revision.contentDigest(), requestKey: "isolated-publication-rule", quote: quote); job.state = .succeeded
        let mimes = ["video/mp4", "image/png", "application/x-subrip", "text/plain"]
        job.artifacts = mimes.enumerated().map { index, mime in Artifact(path: "/isolated-test/\(index)", mime: mime, bytes: 1, sha256: "rules-only", revision: revision.id) }; db.jobs = [job]
        let publication = Publication(workspaceID: "w", projectID: project.id, revisionID: revision.id, platform: "通用", accountReference: "", aiLabel: false, commercialLabel: false, rightsChecked: false, ctaPermitted: false, channelAuthorized: false, trackingCode: "", title: "材料小课", description: "这是一条规则测试输入，不向平台发送")
        return (db, project, job, publication)
    }
    private func published(_ source: Publication) -> Publication { var p = source; p.accountReference = "owned-channel-alias"; p.aiLabel = true; p.commercialLabel = true; p.rightsChecked = true; p.ctaPermitted = true; p.channelAuthorized = true; p.remoteContentID = "actual-backfill-rule-fixture"; p.publishedAt = now.addingTimeInterval(-10); return p }
    func testUnknownChannelPermissionsProducePendingManualPackageWithoutPublication() throws {
        let (db, project, job, draft) = try fixture(); var input = draft; input.scheduledAt = now.addingTimeInterval(3600); input.publishedAt = now
        let result = try PublicationRules.prepare(input, project: project, job: job, database: db, reviewer: "test", now: now)
        XCTAssertNil(result.remoteContentID); XCTAssertNil(result.publishedAt); XCTAssertEqual(result.state, "待核对·待人工发布"); XCTAssertFalse(result.validationWarnings?.isEmpty ?? true); XCTAssertEqual(result.targetDigest, try project.current.contentDigest()); XCTAssertEqual(result.deliveryJobID, job.id); XCTAssertFalse(result.trackingCode.isEmpty)
    }
    func testHistoricalTargetCannotBorrowCurrentVersionReview() throws {
        var (db, project, job, publication) = try fixture(); project.revisions[0].review = Review(); var current = project.revisions[0]; current.id = Codec.id(); current.number = 2; current.review.text = true; current.review.rights = true; current.review.fullPreview = true; current.review.sound = true; current.review.captions = true; current.review.reviewer = "test"; current.review.at = now; current.review.digest = try current.contentDigest(); project.revisions.append(current); db.projects = [project]
        XCTAssertEqual(publication.revisionID, project.revisions[0].id)
        XCTAssertThrowsError(try PublicationRules.prepare(publication, project: project, job: job, database: db, reviewer: "test", now: now))
    }
    func testJobDigestAndUnreviewedStateCannotBeUsedForPublication() throws {
        let (db, project, job, publication) = try fixture(); var wrong = job; wrong.digest = "other-revision"; XCTAssertThrowsError(try PublicationRules.prepare(publication, project: project, job: wrong, database: db, reviewer: "test", now: now)); wrong = job; wrong.state = .needsReview; XCTAssertThrowsError(try PublicationRules.prepare(publication, project: project, job: wrong, database: db, reviewer: "test", now: now))
    }
    func testPublishedBackfillRequiresAllChecksAndRealTimeAfterApproval() throws {
        let (db, project, job, draft) = try fixture(); var p = published(draft); p.channelAuthorized = false; XCTAssertThrowsError(try PublicationRules.prepare(p, project: project, job: job, database: db, reviewer: "test", now: now)); p = published(draft); p.ctaPermitted = false; XCTAssertThrowsError(try PublicationRules.prepare(p, project: project, job: job, database: db, reviewer: "test", now: now)); p = published(draft); p.publishedAt = now.addingTimeInterval(1); XCTAssertThrowsError(try PublicationRules.prepare(p, project: project, job: job, database: db, reviewer: "test", now: now)); p = published(draft); p.publishedAt = now.addingTimeInterval(-100); XCTAssertThrowsError(try PublicationRules.prepare(p, project: project, job: job, database: db, reviewer: "test", now: now))
        p = published(draft); p.scheduledAt = now.addingTimeInterval(3600); let verified = try PublicationRules.prepare(p, project: project, job: job, database: db, reviewer: "test", now: now); XCTAssertEqual(verified.state, "已发布·已回填ID"); XCTAssertNil(verified.scheduledAt)
    }
    func testRepeatedRemoteBackfillIsIdempotentAndCannotChangeTargetVersion() throws {
        var (db, project, job, draft) = try fixture(); let first = published(draft); try db.recordPublication(first, jobID: job.id, reviewer: "test", now: now); var duplicate = first; duplicate.id = Codec.id(); try db.recordPublication(duplicate, jobID: job.id, reviewer: "test", now: now); XCTAssertEqual(db.publications.count, 1)
        var next = project.current; next.id = Codec.id(); next.number += 1; next.review.digest = try next.contentDigest(); project.revisions.append(next); db.projects = [project]; var nextJob = job; nextJob.id = Codec.id(); nextJob.revisionID = next.id; nextJob.digest = try next.contentDigest(); nextJob.artifacts = nextJob.artifacts.map { artifact in var a = artifact; a.revision = next.id; return a }; db.jobs.append(nextJob); duplicate.revisionID = next.id
        XCTAssertThrowsError(try db.recordPublication(duplicate, jobID: nextJob.id, reviewer: "test", now: now))
    }
    func testPendingManualQueueIsWorkspaceScopedAndSortedByActualSchedule() throws {
        let (_, _, _, draft) = try fixture(); var late = draft; late.id = "late"; late.scheduledAt = now.addingTimeInterval(3600); var overdue = draft; overdue.id = "overdue"; overdue.scheduledAt = now.addingTimeInterval(-3600); var other = draft; other.workspaceID = "other"; var done = published(draft); done.id = "done"
        XCTAssertEqual(PublicationRules.awaitingManual([late, done, other, overdue], workspaceID: "w").map(\.id), ["overdue", "late"])
    }
    func testAccountFieldRejectsCredentialsWithoutEchoingThem() throws {
        let (db, project, job, draft) = try fixture(); var p = draft; p.accountReference = "authorization: Bearer isolated-invalid-fixture"
        XCTAssertThrowsError(try PublicationRules.prepare(p, project: project, job: job, database: db, reviewer: "test", now: now)) { error in XCTAssertFalse(error.localizedDescription.contains("isolated-invalid-fixture")) }
    }
    func testPhysicalArtifactValidationDetectsMissingModifiedAndWrongRevisionFiles() throws {
        let (database, project, source, _) = try fixture(); let root = FileManager.default.temporaryDirectory.appendingPathComponent("PublicationRules-" + Codec.id()); defer { try? FileManager.default.removeItem(at: root) }; let repository = try Repository(root: root); var job = source
        let directory = root.appendingPathComponent("exports/" + job.id); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        job.artifacts = try job.artifacts.enumerated().map { index, artifact in let bytes = Data("isolated-hash-rule-\(index)".utf8); let path = directory.appendingPathComponent("part-\(index)"); try bytes.write(to: path); return Artifact(path: path.path, mime: artifact.mime, bytes: bytes.count, sha256: Codec.hash(bytes), revision: project.current.id) }
        // Physical reads are authorized against the persisted workspace, frozen
        // revision and original job, as they are through normal App/CLI callers.
        try repository.transaction { $0=database;$0.jobs=[job] }
        try repository.verifyDelivery(job, revision: project.current)
        var wrong=job;wrong.artifacts[0].revision=Codec.id()
        try repository.transaction { $0.jobs=[wrong] }
        XCTAssertThrowsError(try repository.verifyDelivery(wrong,revision:project.current))
        try repository.transaction { $0.jobs=[job] }
        let original=try Data(contentsOf:URL(fileURLWithPath:job.artifacts[0].path))
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: job.artifacts[0].path)); XCTAssertThrowsError(try repository.verifyDelivery(job, revision: project.current))
        try original.write(to:URL(fileURLWithPath:job.artifacts[0].path));try repository.verifyDelivery(job,revision:project.current)
        try FileManager.default.removeItem(atPath: job.artifacts[1].path); XCTAssertThrowsError(try repository.verifyDelivery(job, revision: project.current))
    }
}
