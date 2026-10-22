import XCTest
@testable import VideoCore

final class BrandDeliveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private func fixture() throws -> (Database, String, String) {
        var database = Database(); var workspace = Workspace(name: "隔离品牌规则测试", owner: "test"); workspace.id = "w"; database.workspaces = [workspace]
        let product = Product(workspaceID: "w", sku: "brand-reference", name: "品牌参数说明", checkout: "https://example.org/brand", audience: "需要核对参数的用户", task: "对照说明书", outcome: "识别一项参数", prerequisite: "阅读说明", scope: "说明书演示", prices: [Price(money: Money(99), from: .distantPast, source: "隔离规则测试凭证", verified: true)]); database.products = [product]
        var evidence = Evidence(workspaceID: "w", title: "隔离说明书凭证", source: "isolated-rules-document", claim: "说明书参数已核对", owner: "test", commercialAllowed: true, verified: true); evidence.checkedAt = now.addingTimeInterval(-60); database.evidence = [evidence]
        var revision = Revision(product: product, purpose: .brand, aspect: .portrait, scenes: [Scene(title: "核对原始参数", body: "请对照说明书标注的范围。")], cta: "打开说明书核对一次"); revision.dependencies = try DependencyRules.freeze(revision: revision, assets: [], evidence: [evidence], now: now); revision.review.text = true; revision.review.rights = true; revision.review.fullPreview = true; revision.review.sound = true; revision.review.captions = true; revision.review.reviewer = "作者看听确认"; revision.review.at = now.addingTimeInterval(-30); revision.review.digest = try revision.contentDigest()
        let project = Project(workspaceID: "w", name: "品牌待审项目", revision: revision); database.projects = [project]; database.jobs = [try job(project)]
        var deal = BrandDeal(workspaceID: "w", client: "隔离品牌客户", brief: "说明书参数解说", vertical: "数码", checklist: [:], revisionsAllowed: 1, usage: "指定账号自然分发", expiresAt: now.addingTimeInterval(86400 * 30), exclusivity: "非排他", settlements: [.production], quote: Money(500)); let template = VerticalChecklistTemplate.standard(for: "数码"); deal.checklistTemplate = template; deal.checklist = Dictionary(uniqueKeysWithValues: template.requirements.map { ($0.label, true) }); deal.checklistEvidence = Dictionary(uniqueKeysWithValues: template.requirements.map { ($0.id, [evidence.id]) }); try database.recordBrandDeal(deal)
        return (database, project.id, deal.id)
    }
    private func job(_ project: Project) throws -> Job { let revision = project.current; let digest = try revision.contentDigest(); let quote = Quote(projectID: project.id, revisionID: revision.id, digest: digest, upper: Money(0), unit: "CNY", provider: "native", expiresAt: now.addingTimeInterval(3600), confirmed: true); var job = Job(workspaceID: "w", projectID: project.id, revisionID: revision.id, digest: digest, requestKey: Codec.id(), quote: quote); job.state = .succeeded; job.artifacts = ["video/mp4", "image/png", "application/x-subrip", "text/plain"].enumerated().map { index, mime in Artifact(path: "/isolated-brand-rule/\(index)", mime: mime, bytes: 1, sha256: "rules-only", revision: revision.id) }; return job }
    private func approve(_ db: inout Database, projectID: String, dealID: String) throws { try db.bindBrandProject(dealID: dealID, projectID: projectID, reason: "测试中明确关联实际Brief"); let project = try db.project(projectID); try db.approveBrand(dealID: dealID, projectID: projectID, revisionID: project.current.id, reviewer: "品牌审核者", note: "核对具体版本及授权范围", now: now) }
    private func appendRevision(_ database: inout Database, projectID: String) throws -> String { let index = database.projects.firstIndex { $0.id == projectID }!; var revision = database.projects[index].current; revision.id = Codec.id(); revision.number += 1; revision.scenes[0].body += "请保留原文来源。"; revision.review.digest = try revision.contentDigest(); database.projects[index].revisions.append(revision); database.jobs.append(try job(database.projects[index])); return revision.id }
    func testAuthorReviewDoesNotGrantBrandApprovalButDraftRenderingRemainsPossible() throws {
        let (db, projectID, _) = try fixture(); let revision = try db.project(projectID).current
        XCTAssertTrue(try Quality.inspect(revision, database: db, requireReview: false, now: now).isEmpty)
        XCTAssertFalse(try Quality.inspect(revision, database: db, requireReview: true, now: now).isEmpty)
        XCTAssertTrue(try Quality.inspect(revision, database: db, requireReview: true, now: now, enforceBrandDelivery: false).isEmpty)
    }
    func testExplicitDealAndRevisionApprovalUnblocksOnlyThatDelivery() throws {
        var (db, projectID, dealID) = try fixture(); try db.bindBrandProject(dealID: dealID, projectID: projectID, reason: "明确客户"); XCTAssertFalse(BrandDeliveryRules.inspect(revision: try db.project(projectID).current, database: db, now: now).isEmpty)
        XCTAssertThrowsError(try db.approveBrand(dealID: dealID, projectID: projectID, reviewer: "品牌方", note: "未明确版本", now: now))
        let revision = try db.project(projectID).current; try db.approveBrand(dealID: dealID, projectID: projectID, revisionID: revision.id, reviewer: "品牌方", note: "已看指定版", now: now)
        XCTAssertTrue(try Quality.inspect(revision, database: db, requireReview: true, now: now).isEmpty); XCTAssertEqual(db.brandDeals[0].approvals?.count, 1); XCTAssertNotNil(db.brandDeals[0].approvals?.first?.termsDigest)
    }
    func testVersionOneApprovalCannotCoverVersionTwoOrBeBlindlyResubmitted() throws {
        var (db, projectID, dealID) = try fixture(); try approve(&db, projectID: projectID, dealID: dealID); let oldID = try db.project(projectID).current.id; _ = try appendRevision(&db, projectID: projectID)
        XCTAssertFalse(BrandDeliveryRules.inspect(revision: try db.project(projectID).current, database: db, now: now).isEmpty)
        XCTAssertThrowsError(try db.approveBrand(dealID: dealID, projectID: projectID, revisionID: oldID, reviewer: "品牌方", note: "旧版审批", now: now))
    }
    func testExpiryRevokesNewDeliveryButDoesNotDestroyHistoryOrBackup() throws {
        var (db, projectID, dealID) = try fixture(); try approve(&db, projectID: projectID, dealID: dealID); db.brandDeals[0].expiresAt = now.addingTimeInterval(-1)
        XCTAssertFalse(BrandDeliveryRules.inspect(revision: try db.project(projectID).current, database: db, now: now).isEmpty); XCTAssertEqual(try db.project(projectID).revisions.count, 1)
        db.jobs = []; let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrandHistory-" + Codec.id()); defer { try? FileManager.default.removeItem(at: root) }; let repository = try Repository(root: root); try repository.transaction { $0 = db }; XCTAssertFalse(try repository.backup().isEmpty)
    }
    func testTermsAndEvidenceChangesRequireReapprovalButTagsDoNot() throws {
        var (db, projectID, dealID) = try fixture(); try approve(&db, projectID: projectID, dealID: dealID); db.evidence[0].tags = ["新的检索标签"]
        XCTAssertTrue(BrandDeliveryRules.inspect(revision: try db.project(projectID).current, database: db, now: now).isEmpty)
        db.evidence[0].claim = "来源的实质事实已变化"; XCTAssertFalse(BrandDeliveryRules.inspect(revision: try db.project(projectID).current, database: db, now: now).isEmpty)
        var changed = db.brandDeals[0]; changed.exclusivity = "指定行业排他"; try db.recordBrandDeal(changed); XCTAssertNil(db.brandDeals[0].approvedRevisionID)
    }
    func testNewBrandVersionsConsumeRevisionAllowanceAndCannotBypassLimit() throws {
        var (db, projectID, dealID) = try fixture(); try approve(&db, projectID: projectID, dealID: dealID); let v2 = try appendRevision(&db, projectID: projectID)
        try db.approveBrand(dealID: dealID, projectID: projectID, revisionID: v2, reviewer: "品牌方", note: "第二版", now: now); XCTAssertEqual(db.brandDeals[0].revisionsUsed, 1)
        let v3 = try appendRevision(&db, projectID: projectID); XCTAssertThrowsError(try db.approveBrand(dealID: dealID, projectID: projectID, revisionID: v3, reviewer: "品牌方", note: "超额第三版", now: now))
    }
    func testManualRevisionRecordIsNotChargedTwiceAtApproval() throws {
        var (db, projectID, dealID) = try fixture(); try approve(&db, projectID: projectID, dealID: dealID); try db.recordBrandRevision(dealID: dealID, reason: "已明确一次改稿"); let v2 = try appendRevision(&db, projectID: projectID); try db.approveBrand(dealID: dealID, projectID: projectID, revisionID: v2, reviewer: "品牌方", note: "已登记的改稿", now: now); XCTAssertEqual(db.brandDeals[0].revisionsUsed, 1)
    }
    func testProfessionalEvidenceAndAuthorizationsCoverActualUsePeriod() throws {
        var (db, projectID, dealID) = try fixture(); db.brandDeals[0].settlements = [.distribution]; db.brandDeals[0].authorizations = [CommercialAuthorization(scope: .distribution, evidenceID: db.evidence[0].id, usage: "指定账号自然分发", from: now.addingTimeInterval(-1), until: now.addingTimeInterval(86400))]
        XCTAssertThrowsError(try approve(&db, projectID: projectID, dealID: dealID)); let validUntil=db.brandDeals[0].expiresAt; db.brandDeals[0].authorizations?[0].until = validUntil; try approve(&db, projectID: projectID, dealID: dealID)
        db.evidence[0].expiresAt = now.addingTimeInterval(-1); XCTAssertFalse(BrandDeliveryRules.inspect(revision: try db.project(projectID).current, database: db, now: now).isEmpty)
    }
    func testCashBookkeepingDoesNotSilentlyRevokeContentApproval() throws {
        var (db, projectID, dealID) = try fixture(); try approve(&db, projectID: projectID, dealID: dealID); try db.recordBrandSettlement(dealID: dealID, settlement: BrandSettlement(kind: .production, received: Money(200), at: now, receipt: "isolated-real-receipt-reference")); XCTAssertTrue(BrandDeliveryRules.inspect(revision: try db.project(projectID).current, database: db, now: now).isEmpty)
    }
    func testPlatformBackfillCannotBypassBrandDeliveryGate() throws {
        var (db, projectID, dealID) = try fixture(); let project = try db.project(projectID); let publication = Publication(workspaceID: "w", projectID: projectID, revisionID: project.current.id, platform: "通用", accountReference: "owned-channel-alias", aiLabel: true, commercialLabel: true, rightsChecked: true, ctaPermitted: true, channelAuthorized: true, trackingCode: "isolated-brand", title: "待品牌审核", description: "不向平台发送")
        XCTAssertThrowsError(try PublicationRules.prepare(publication, project: project, job: db.jobs[0], database: db, reviewer: "作者", now: now)); try approve(&db, projectID: projectID, dealID: dealID); XCTAssertNoThrow(try PublicationRules.prepare(publication, project: project, job: db.jobs[0], database: db, reviewer: "作者", now: now))
    }
}
