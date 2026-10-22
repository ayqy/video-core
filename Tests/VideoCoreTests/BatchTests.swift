import XCTest
@testable import VideoCore

final class BatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private func product(_ sku: String) -> Product { Product(workspaceID: "w", sku: sku, name: sku, checkout: "https://example.org/" + sku, audience: "材料整理学习者", task: "标注原文依据", outcome: "完成有来源的结论", prerequisite: "中文阅读", scope: "材料整理", prices: [Price(money: Money(99), from: .distantPast, source: "独立批次规则测试", verified: true)]) }
    private func topic(_ product: Product, hook: String, budget: Decimal = 20) -> Topic { Topic(workspaceID: "w", productID: product.id, audience: product.audience, task: product.task, knowledge: "先提问题，再找原文依据。", hook: hook, outcome: product.outcome, proof: "对照原文标注一句依据。", grammar: NarrativeGrammar.practice.rawValue, cta: "打开原文练习一次", channel: "测试渠道", evidenceIDs: [], series: "材料小课", budget: Money(budget)) }
    private func fixture() throws -> (Database, TopicBatch, [Project]) {
        var db = Database(); var workspace = Workspace(name: "隔离批次规则测试", owner: "test"); workspace.id = "w"; db.workspaces = [workspace]; let products = [product("a"), product("b")]; db.products = products
        var batch = try BatchRules.create(workspaceID: "w", title: "两个SKU独立对照", topics: [topic(products[0], hook: "问题一"), topic(products[1], hook: "问题二")], products: products, now: now)
        var projects: [Project] = []
        for index in batch.items.indices { let item = batch.items[index]; var revision = Revision(product: item.productSnapshot!, purpose: .education, aspect: .portrait, scenes: [Scene(title: item.topic.hook, body: item.topic.knowledge)], cta: item.topic.cta); revision.dependencies = try DependencyRules.freeze(revision: revision, assets: [], evidence: [], now: now); var project = Project(workspaceID: "w", name: item.topic.hook, revision: revision); project.batchID = batch.id; batch.items[index].projectID = project.id; batch.items[index].revisionID = revision.id; batch.items[index].state = .ready; projects.append(project) }
        db.projects = projects; db.topicBatches = [batch]; return (db, batch, projects)
    }
    private func quote(_ project: Project, upper: Decimal) throws -> Quote { Quote(projectID: project.id, revisionID: project.current.id, digest: try project.current.contentDigest(), upper: Money(upper), unit: "CNY", provider: "configured-provider", expiresAt: now.addingTimeInterval(3600), confirmed: true) }
    func testFiveRowsShareOneBatchAndOneInvalidRowDoesNotDestroyOthers() throws {
        let product = product("a"); var rows = (0..<5).map { topic(product, hook: "钩子\($0)") }; rows[2].proof = ""
        let batch = try BatchRules.create(workspaceID: "w", title: "五条对照", topics: rows, products: [product], now: now)
        XCTAssertEqual(batch.items.count, 5); XCTAssertTrue(batch.items.allSatisfy { $0.topic.batchID == batch.id }); XCTAssertEqual(batch.items.filter { $0.state == .failed }.count, 1); XCTAssertEqual(batch.items.filter { $0.state == .planned }.count, 4); XCTAssertEqual(batch.maximumByCurrency["CNY"], 100)
    }
    func testOneSKUPriceChangeInvalidatesOnlyItsOwnItem() throws {
        var (db, batch, _) = try fixture(); db.products[0].prices[0].money = Money(200); let updated = BatchRules.refreshed(batch, database: db, now: now)
        XCTAssertEqual(updated.items[0].state, .invalidated); XCTAssertEqual(updated.items[1].state, .ready); XCTAssertEqual(updated.items[1].productSnapshot, batch.items[1].productSnapshot); XCTAssertEqual(updated.items[1].budget, batch.items[1].budget)
    }
    func testOneJobFailureDoesNotResubmitOrInvalidateSibling() throws {
        var (db, batch, projects) = try fixture(); let quote = try quote(projects[0], upper: 5); var job = Job(workspaceID: "w", projectID: projects[0].id, revisionID: projects[0].current.id, digest: quote.digest, requestKey: "one-failed-job", quote: quote); job.state = .failed; job.message = "独立输入错误"; db.jobs = [job]
        let updated = BatchRules.refreshed(batch, database: db, now: now); XCTAssertEqual(updated.items[0].state, .failed); XCTAssertEqual(updated.items[0].error, "独立输入错误"); XCTAssertEqual(updated.items[1].state, .ready); XCTAssertEqual(db.jobs.count, 1); XCTAssertTrue(db.publications.isEmpty)
    }
    func testPerItemBudgetIsEnforcedInAdditionToGlobalBudget() throws {
        let (_, batch, projects) = try fixture(); try BatchRules.validateSubmission(project: projects[0], quote: quote(projects[0], upper: 20), batches: [batch]); XCTAssertThrowsError(try BatchRules.validateSubmission(project: projects[0], quote: quote(projects[0], upper: 21), batches: [batch]))
    }
    func testUnknownPastExposureCountsAndIdempotentReplayDoesNotReserveTwice() throws {
        let (_, batch, projects) = try fixture(); let confirmed = try quote(projects[0], upper: 15); var old = Job(workspaceID: "w", projectID: projects[0].id, revisionID: projects[0].current.id, digest: confirmed.digest, requestKey: "same-request", quote: confirmed); old.state = .unknownRemote
        try BatchRules.validateSubmission(project: projects[0], quote: confirmed, batches: [batch], existingJobs: [old], requestKey: "same-request")
        XCTAssertThrowsError(try BatchRules.validateSubmission(project: projects[0], quote: confirmed, batches: [batch], existingJobs: [old], requestKey: "new-request"))
    }
    func testMissingBatchOrWrongCurrencyCannotSilentlyDropCeiling() throws {
        let (_, batch, projects) = try fixture(); XCTAssertThrowsError(try BatchRules.validateSubmission(project: projects[0], quote: quote(projects[0], upper: 0), batches: [])); var wrong = try quote(projects[0], upper: 0); wrong.upper = Money(0, "USD"); XCTAssertThrowsError(try BatchRules.validateSubmission(project: projects[0], quote: wrong, batches: [batch]))
    }
    func testAcceptingNewRevisionPreservesOldFactsHistoryAndDoesNotIncreaseBudget() throws {
        var (db, batch, projects) = try fixture(); var newProduct = db.products[0]; newProduct.prices[0].money = Money(200); db.products[0] = newProduct; projects[0] = Editor.updateFacts(newProduct, project: projects[0]); projects[0].revisions[projects[0].revisions.count - 1].dependencies = try DependencyRules.freeze(revision: projects[0].current, assets: [], evidence: [], now: now); db.projects = projects
        try db.acceptBatchRevision(batchID: batch.id, itemID: batch.items[0].id, now: now)
        let result = try XCTUnwrap(db.topicBatches?.first); XCTAssertEqual(result.items[0].budget, batch.items[0].budget); XCTAssertEqual(result.items[0].history?.first?.product, batch.items[0].productSnapshot); XCTAssertEqual(result.items[0].revisionID, projects[0].current.id); XCTAssertEqual(result.items[1].revisionID, batch.items[1].revisionID)
    }
    func testAudienceChangeCannotMasqueradeAsSameComparisonCondition() throws {
        var (db, batch, projects) = try fixture(); projects[0].revisions[0].product.audience = "不同目标受众"; db.projects = projects; db.products[0] = projects[0].current.product; db.projects[0].revisions[0].dependencies = try DependencyRules.freeze(revision: db.projects[0].current, assets: [], evidence: [], now: now)
        XCTAssertThrowsError(try db.acceptBatchRevision(batchID: batch.id, itemID: batch.items[0].id, now: now))
    }
}
