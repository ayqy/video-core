import XCTest
@testable import VideoCore

final class CohortFinanceTests: XCTestCase {
    private let paidAt = "2024-09-06T04:00:00Z"
    private let refundAt = "2024-10-10T04:00:00Z"
    private func setup() -> (Database, Workspace) {
        let workspace = Workspace(name: "隔离月度核对", owner: "test-owner")
        var database = Database(); database.workspaces = [workspace]
        return (database, workspace)
    }
    private func csv(paid: String = "2024-09-06T04:00:00Z", fee: String = "2", currency: String = "CNY", refunded: Bool = false) -> String {
        let header = "platform,order_id,buyer_id,sku,paid_at,amount,currency,fee,customer_kind,source_code,maturity_days,refund_id,refund_amount,refund_at"
        let row = "隔离平台,isolated-order,isolated-buyer,合成月度课程,\(paid),200,\(currency),\(fee),新客,isolated-source,0," + (refunded ? "isolated-refund,50,\(refundAt)" : ",,")
        return header + "\n" + row
    }
    @discardableResult private func apply(_ text: String, database: inout Database, workspace: Workspace) throws -> String {
        let preview = try ImportRules.orders(text, workspace: workspace, existing: database.orders)
        try database.importOrders(preview.rows, batchID: preview.batchID)
        return preview.batchID
    }
    func testLateRefundRevisesRecordedCohortAndCurrentCashWithoutReplacingOriginal() throws {
        var (database, workspace) = setup()
        let firstImport = try apply(csv(), database: &database, workspace: workspace)
        let original = try database.recordCourseCohort(workspaceID: workspace.id, month: "2024-09")
        XCTAssertEqual(original.report.contribution, 198); XCTAssertEqual(original.version, 1)
        XCTAssertEqual(original.sourceImportIDs, [firstImport]); XCTAssertNil(original.previousID)
        let refundImport = try apply(csv(refunded: true), database: &database, workspace: workspace)
        let history = try XCTUnwrap(database.courseCohortStatements)
        XCTAssertEqual(history.map(\.report.contribution), [198, 148])
        XCTAssertEqual(history[0].inputDigest, original.inputDigest)
        XCTAssertEqual(history[1].previousID, original.id); XCTAssertEqual(history[1].triggerImportID, refundImport)
        let order = try XCTUnwrap(database.orders.first), receipt = try XCTUnwrap(database.imports.first { $0.id == refundImport })
        let change = try XCTUnwrap(history[1].refundChanges.first)
        XCTAssertEqual(change.orderID, order.id); XCTAssertEqual(change.refundID, order.refunds[0].id)
        XCTAssertEqual(change.refundAt, try ImportRules.date(refundAt)); XCTAssertEqual(change.importID, receipt.id)
        XCTAssertEqual(change.importedAt, receipt.at); XCTAssertEqual(change.beforeContribution, receipt.previousOrders.first?.net)
        XCTAssertEqual(change.beforeContribution, 198); XCTAssertEqual(change.afterContribution, 148)
        XCTAssertEqual(history[0].sourceFacts.first?.refunds.count, 0)
        XCTAssertEqual(history[1].sourceFacts.first?.refunds.count, 1)
        let priorCash = try CohortFinance.cash(database: database, workspaceID: workspace.id, month: "2024-09")
        let currentCash = try CohortFinance.cash(database: database, workspaceID: workspace.id, month: "2024-10")
        XCTAssertEqual(priorCash.netChange, 198); XCTAssertEqual(priorCash.knownFees, 2)
        XCTAssertEqual(currentCash.netChange, -50); XCTAssertEqual(currentCash.knownFees, 0)
        XCTAssertEqual(currentCash.refundCount, 1)
        try database.validate()
    }
    func testDuplicateRefundAndEquivalentNewBatchDoNotCreateCashOrRevisionDuplicates() throws {
        var (database, workspace) = setup()
        try apply(csv(), database: &database, workspace: workspace)
        _ = try database.recordCourseCohort(workspaceID: workspace.id, month: "2024-09")
        try apply(csv(refunded: true), database: &database, workspace: workspace)
        let history = try Codec.data(database.courseCohortStatements)
        try apply(csv(refunded: true), database: &database, workspace: workspace)
        try apply(csv(refunded: true) + "\n", database: &database, workspace: workspace)
        _ = try database.recordCourseCohort(workspaceID: workspace.id, month: "2024-09")
        XCTAssertEqual(try Codec.data(database.courseCohortStatements), history)
        XCTAssertEqual(database.orders.count, 1); XCTAssertEqual(database.orders[0].refunds.count, 1)
        XCTAssertEqual(try CohortFinance.cash(database: database, workspaceID: workspace.id, month: "2024-10").netChange, -50)
    }
    func testBeijingMonthBoundaryUsesHalfOpenMonthsAndOriginalFeeOnlyOnce() throws {
        var (database, workspace) = setup()
        var order = try Order(workspaceID: workspace.id, platform: "isolated", rawOrderID: "boundary", rawBuyerID: "", salt: workspace.salt,
                              sku: "boundary", paidAt: ImportRules.date("2024-08-31T16:00:00Z"), paid: Money(200), fee: 2,
                              refunds: [Refund(id: "boundary-refund", amount: 50, at: ImportRules.date("2024-09-30T16:00:00Z"))], importID: "boundary-batch")
        database.orders = [order]
        XCTAssertEqual(try CohortFinance.cohort(database: database, workspaceID: workspace.id, month: "2024-08").orderCount, 0)
        XCTAssertEqual(try CohortFinance.cohort(database: database, workspaceID: workspace.id, month: "2024-09").contribution, 148)
        XCTAssertEqual(try CohortFinance.cash(database: database, workspaceID: workspace.id, month: "2024-09").netChange, 198)
        XCTAssertEqual(try CohortFinance.cash(database: database, workspaceID: workspace.id, month: "2024-10").netChange, -50)
        order.refunds[0].at = try ImportRules.date("2024-09-30T15:59:59Z"); database.orders = [order]
        XCTAssertEqual(try CohortFinance.cash(database: database, workspaceID: workspace.id, month: "2024-09").netChange, 148)
        XCTAssertEqual(try CohortFinance.cash(database: database, workspaceID: workspace.id, month: "2024-10").netChange, 0)
    }
    func testCurrenciesUnknownFeesAndWorkspacesRemainIndependent() throws {
        var (database, workspace) = setup()
        let other = Workspace(name: "别的空间", owner: "other-owner"); database.workspaces.append(other)
        try apply(csv(fee: "", refunded: true), database: &database, workspace: workspace)
        try apply(csv(currency: "USD").replacingOccurrences(of: "isolated-order", with: "isolated-usd-order"), database: &database, workspace: workspace)
        try apply(csv(), database: &database, workspace: other)
        let unknown = try CohortFinance.cohort(database: database, workspaceID: workspace.id, month: "2024-09")
        XCTAssertEqual(unknown.orderCount, 1); XCTAssertEqual(unknown.unknownFeeOrders, 1); XCTAssertNil(unknown.contribution)
        XCTAssertNil(try CohortFinance.cash(database: database, workspaceID: workspace.id, month: "2024-09").netChange)
        XCTAssertEqual(try CohortFinance.cash(database: database, workspaceID: workspace.id, month: "2024-10").netChange, -50, "已知退款不受原付款月未知费用影响")
        XCTAssertEqual(try CohortFinance.cohort(database: database, workspaceID: workspace.id, month: "2024-09", currency: "USD").contribution, 198)
        XCTAssertEqual(try CohortFinance.cohort(database: database, workspaceID: other.id, month: "2024-09").contribution, 198)
        _ = try database.recordCourseCohort(workspaceID: other.id, month: "2024-09")
        XCTAssertTrue(database.courseCohortStatements?.allSatisfy { $0.workspaceID == other.id } == true)
        XCTAssertThrowsError(try CohortFinance.cohort(database: database, workspaceID: "missing", month: "2024-09"))
        XCTAssertThrowsError(try CohortFinance.cohort(database: database, workspaceID: workspace.id, month: "2024-09", currency: "?"))
    }
    func testRefundImportWithoutAnIssuedReportNeverInventsOriginalReport() throws {
        var (database, workspace) = setup()
        try apply(csv(), database: &database, workspace: workspace)
        try apply(csv(refunded: true), database: &database, workspace: workspace)
        XCTAssertNil(database.courseCohortStatements)
        let issued = try database.recordCourseCohort(workspaceID: workspace.id, month: "2024-09")
        XCTAssertEqual(issued.version, 1); XCTAssertEqual(issued.report.contribution, 148)
        XCTAssertNil(issued.previousID); XCTAssertNil(issued.triggerImportID)
        XCTAssertTrue(issued.refundChanges.isEmpty)
    }
    func testRollbackKeepsIssuedRevisionsAndAddsCorrectionIncludingEmptyCohort() throws {
        var (database, workspace) = setup()
        let first = try apply(csv(), database: &database, workspace: workspace)
        _ = try database.recordCourseCohort(workspaceID: workspace.id, month: "2024-09")
        let refund = try apply(csv(refunded: true), database: &database, workspace: workspace)
        try database.rollbackImport(refund)
        XCTAssertEqual(database.courseCohortStatements?.map(\.report.contribution), [198, 148, 198])
        XCTAssertEqual(try CohortFinance.cash(database: database, workspaceID: workspace.id, month: "2024-10").netChange, 0)
        try database.rollbackImport(first)
        XCTAssertEqual(database.courseCohortStatements?.map(\.report.contribution), [198, 148, 198, 0])
        XCTAssertEqual(database.courseCohortStatements?.last?.sourceFacts.count, 0)
        XCTAssertEqual(database.courseCohortStatements?.last?.triggerImportID, first)
        try database.validate()
    }
    func testInvalidRefundDuringRevisionLeavesDatabaseUnchangedAndRejectsBrokenHistory() throws {
        var (database, workspace) = setup()
        try apply(csv(), database: &database, workspace: workspace)
        _ = try database.recordCourseCohort(workspaceID: workspace.id, month: "2024-09")
        let before = try Codec.data(database)
        var invalid = database.orders[0]; invalid.refunds = [Refund(id: "invalid", amount: 1, at: invalid.paidAt.addingTimeInterval(-1))]
        invalid.importID = "invalid-batch"
        XCTAssertThrowsError(try database.importOrders([invalid], batchID: "invalid-batch"))
        XCTAssertEqual(try Codec.data(database), before)
        database.courseCohortStatements?[0].report.contribution = 999
        XCTAssertThrowsError(try database.validate())
    }
    func testOptionalHistorySurvivesRepositoryReopenAndPortableBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cohort-finance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Repository(root: root.appendingPathComponent("source"))
        let (initial, workspace) = setup()
        try repository.transaction { $0 = initial }
        try repository.transaction { database in
            try apply(csv(), database: &database, workspace: workspace)
            _ = try database.recordCourseCohort(workspaceID: workspace.id, month: "2024-09")
            try apply(csv(refunded: true), database: &database, workspace: workspace)
        }
        let reopened = try Repository(root: repository.root).read()
        XCTAssertEqual(reopened.courseCohortStatements?.map(\.report.contribution), [198, 148])
        let restored = try Repository.restore(repository.backup(), to: root.appendingPathComponent("restored"))
        XCTAssertEqual(try restored.read().courseCohortStatements?.map(\.report.contribution), [198, 148])
        let legacy = try Codec.decoder().decode(Database.self, from: Codec.data(initial))
        XCTAssertNil(legacy.courseCohortStatements); try legacy.validate()
    }
    func testRevisionValidationRejectsCrossWorkspaceReceiptsAndInventedBeforeValues() throws {
        var (database, workspace) = setup()
        let other = Workspace(name: "另一核对空间", owner: "other-owner"); database.workspaces.append(other)
        try apply(csv(), database: &database, workspace: workspace)
        _ = try database.recordCourseCohort(workspaceID: workspace.id, month: "2024-09")
        try apply(csv(refunded: true), database: &database, workspace: workspace)
        let otherImport = try apply(csv(), database: &database, workspace: other)
        try database.validate()
        var crossWorkspace = database
        crossWorkspace.courseCohortStatements?[0].sourceImportIDs = [otherImport]
        XCTAssertThrowsError(try crossWorkspace.validate())
        var inventedBefore = database
        inventedBefore.courseCohortStatements?[1].refundChanges[0].beforeContribution = 999
        XCTAssertThrowsError(try inventedBefore.validate())
        var inventedEvent = database
        inventedEvent.courseCohortStatements?[1].refundChanges[0].refundID = "not-the-imported-event"
        XCTAssertThrowsError(try inventedEvent.validate())
    }
    func testReimportAfterRollbackPinsEachActualReceiptWithoutReplacingOldRevisions() throws {
        var (database, workspace) = setup()
        try apply(csv(), database: &database, workspace: workspace)
        _ = try database.recordCourseCohort(workspaceID: workspace.id, month: "2024-09")
        let refundBatch = try apply(csv(refunded: true), database: &database, workspace: workspace)
        let originalChange = try XCTUnwrap(database.courseCohortStatements?[1].refundChanges.first)
        let originalBytes = try Codec.data(Array(try XCTUnwrap(database.courseCohortStatements).prefix(2)))
        try database.rollbackImport(refundBatch)
        XCTAssertEqual(try apply(csv(refunded: true), database: &database, workspace: workspace), refundBatch)
        let history = try XCTUnwrap(database.courseCohortStatements)
        XCTAssertEqual(history.map(\.report.contribution), [198, 148, 198, 148])
        XCTAssertEqual(try Codec.data(Array(history.prefix(2))), originalBytes)
        let receipts = database.imports.filter { $0.id == refundBatch }
        XCTAssertEqual(receipts.count, 2); XCTAssertTrue(receipts[0].rolledBack); XCTAssertFalse(receipts[1].rolledBack)
        XCTAssertEqual(history[1].refundChanges.first?.importedAt, originalChange.importedAt)
        XCTAssertEqual(history[3].refundChanges.first?.importedAt, receipts[1].at)
        XCTAssertEqual(history[3].triggerImportID, refundBatch)
        XCTAssertEqual(try CohortFinance.cash(database: database, workspaceID: workspace.id, month: "2024-10").netChange, -50)
        try database.validate()
    }
    func testAgentFreshRollbackAfterSameBatchReimportAndOriginalRequestReplay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cohort-agent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Repository(root: root), (initial, workspace) = setup()
        try repository.transaction { $0 = initial }
        func domainBytes() throws -> Data {
            var state = try repository.read(); state.generation = 0
            return try Codec.data(state)
        }
        func importInput(_ text: String) throws -> Data {
            let preview = try ImportRules.orders(text, workspace: workspace, existing: repository.read().orders)
            return try Codec.data(AgentValue.object(["workspace_id": .string(workspace.id), "batch_id": .string(preview.batchID),
                "orders": try Codec.decoder().decode(AgentValue.self, from: Codec.data(preview.rows))]))
        }
        _ = try repository.performAgentMutation(command: "orders import", data: importInput(csv()), principal: workspace.owner, requestID: "original-order")
        try repository.transaction { _ = try $0.recordCourseCohort(workspaceID: workspace.id, month: "2024-09") }
        let refundInput = try importInput(csv(refunded: true))
        _ = try repository.performAgentMutation(command: "orders import", data: refundInput, principal: workspace.owner, requestID: "first-refund-import")
        let batch = try XCTUnwrap(repository.read().imports.last?.id)
        let rollbackInput = try Codec.data(AgentValue.object(["workspace_id": .string(workspace.id), "batch_id": .string(batch)]))
        let firstRollback = try repository.performAgentMutation(command: "imports rollback", data: rollbackInput, principal: workspace.owner, requestID: "first-rollback")
        _ = try repository.performAgentMutation(command: "orders import", data: refundInput, principal: workspace.owner, requestID: "reimport-same-refund")
        let before = try domainBytes()
        XCTAssertEqual(try repository.performAgentMutation(command: "imports rollback", data: rollbackInput, principal: workspace.owner, requestID: "first-rollback"), firstRollback)
        XCTAssertEqual(try domainBytes(), before, "相同请求重放原回执，不回滚后来重新导入的相同批次")
        let beforePreview = try Codec.data(repository.read())
        _ = try AgentMutationExecutor.preview(command: "imports rollback", data: rollbackInput, database: repository.read(), principal: workspace.owner)
        XCTAssertEqual(try Codec.data(repository.read()), beforePreview, "预演只核对当前可执行回滚，不改月报或回执")
        let second = try repository.performAgentMutation(command: "imports rollback", data: rollbackInput, principal: workspace.owner, requestID: "fresh-second-rollback")
        let after = try repository.read()
        XCTAssertEqual(after.courseCohortStatements?.map(\.report.contribution), [198, 148, 198, 148, 198])
        XCTAssertFalse(after.imports.contains { $0.id == batch && !$0.rolledBack })
        let afterBytes = try domainBytes()
        XCTAssertEqual(try repository.performAgentMutation(command: "imports rollback", data: rollbackInput, principal: workspace.owner, requestID: "fresh-second-rollback"), second)
        XCTAssertEqual(try domainBytes(), afterBytes)
    }
}
