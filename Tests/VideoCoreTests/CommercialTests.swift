import XCTest
@testable import VideoCore

final class CommercialTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private func database() -> Database { var db = Database(); var workspace = Workspace(name: "隔离商业规则测试", owner: "test"); workspace.id = "w"; db.workspaces = [workspace]; return db }
    private func sale(paid: Bool = true, subscription: Bool = false) -> ToolSale {
        var sale = ToolSale(workspaceID: "w", buyerReference: "anonymous-buyer", plan: "高级模块", paid: paid ? Money(100) : nil, paidAt: paid ? now.addingTimeInterval(-86400 * 10) : nil, expiresAt: subscription ? now.addingTimeInterval(86400 * 20) : nil, supportUntil: now.addingTimeInterval(86400 * 20), supportScope: "安装与故障支持", license: "本工具许可不代替上游模型和素材许可", receipt: paid ? "receipt-1" : "", subscription: subscription)
        sale.orderReference = paid ? "actual-order-1" : nil; sale.thirdPartyCosts = "客户自带模型账户，按上游实际用量付款"; return sale
    }
    private func deal(_ settlements: Set<Settlement> = [.production, .distribution]) -> BrandDeal { BrandDeal(workspaceID: "w", client: "匿名品牌", brief: "按说明书制作解说", vertical: "数码", checklist: [:], revisionsAllowed: 1, usage: "指定账号自然分发", expiresAt: now.addingTimeInterval(86400 * 30), exclusivity: "非排他", settlements: settlements, quote: Money(500)) }
    func testInquiryIsNotCashAndRepeatedOrderUpdatesSameSale() throws {
        var db = database(); try db.recordToolSale(sale(paid: false)); XCTAssertTrue(try CommercialAccounting.reconciledCash(database: db, workspaceID: "w").isEmpty)
        let first = sale(); try db.recordToolSale(first); var importedAgain = first; importedAgain.id = Codec.id(); importedAgain.refunded = 20; try db.recordToolSale(importedAgain)
        XCTAssertEqual(db.toolSales.filter { $0.paid != nil }.count, 1); XCTAssertEqual(db.cash.filter { $0.kind == .tool }.count, 1); XCTAssertEqual(try CommercialAccounting.reconciledCash(database: db, workspaceID: "w").reduce(Decimal(0)) { $0 + $1.received.amount - $1.refunded }, 80)
    }
    func testManualReceiptCopyIsNotDoubleCountedAndConflictIsVisible() throws {
        var db = database(); let sale = sale(); try db.recordToolSale(sale); db.cash.append(CashEntry(workspaceID: "w", kind: .tool, label: "手工凭证副本", received: Money(100), at: now, receipt: sale.receipt))
        XCTAssertEqual(try CommercialAccounting.reconciledCash(database: db, workspaceID: "w").filter { $0.kind == .tool }.count, 1)
        db.cash[db.cash.count - 1].received = Money(101); XCTAssertThrowsError(try CommercialAccounting.reconciledCash(database: db, workspaceID: "w"))
    }
    func testUnlinkedDuplicateManualReceiptsAreRejected() throws {
        var db = database(); db.cash = [CashEntry(workspaceID: "w", kind: .incentive, label: "记录一", received: Money(10), receipt: "same"), CashEntry(workspaceID: "w", kind: .incentive, label: "记录二", received: Money(10), receipt: "same")]
        XCTAssertThrowsError(try CommercialAccounting.reconciledCash(database: db, workspaceID: "w"))
    }
    func testBrandSettlementBreakdownAndReceiptIdempotency() throws {
        var db = database(); let deal = deal(); try db.recordBrandDeal(deal)
        try db.recordBrandSettlement(dealID: deal.id, settlement: BrandSettlement(id: "p1", kind: .production, received: Money(300), at: now, receipt: "aggregate-receipt"))
        try db.recordBrandSettlement(dealID: deal.id, settlement: BrandSettlement(id: "d1", kind: .distribution, received: Money(200), refunded: 20, at: now, receipt: "aggregate-receipt"))
        try db.recordBrandSettlement(dealID: deal.id, settlement: BrandSettlement(id: "p1-new-import-id", kind: .production, received: Money(300), at: now, receipt: "aggregate-receipt"))
        XCTAssertEqual(db.brandDeals[0].settlementRecords?.count, 2)
        let cash = try CommercialAccounting.reconciledCash(database: db, workspaceID: "w"); XCTAssertEqual(cash.reduce(Decimal(0)) { $0 + $1.received.amount - $1.refunded }, 480)
        let report = try CommercialAccounting.report(database: db, workspaceID: "w", start: now.addingTimeInterval(-86400), now: now); XCTAssertEqual(report.actualBrandBySettlement[Settlement.production.rawValue], 300); XCTAssertEqual(report.actualBrandBySettlement[Settlement.distribution.rawValue], 180)
    }
    func testQuoteGiftAndEstimatedCommissionNeverBecomeCash() throws {
        var db = database(); var deal = deal([.cps]); deal.noncash = "品牌赠送试用装"; deal.rate = Decimal(string: "0.2")!; deal.validGMV = 1000; try db.recordBrandDeal(deal)
        XCTAssertEqual(deal.cpsEstimate, 200); XCTAssertTrue(try CommercialAccounting.reconciledCash(database: db, workspaceID: "w").isEmpty)
    }
    func testAdvertisingShareUsesActualAdSpendAndFixedLicenceIsExclusive() throws {
        var deal = deal([.adShare]); deal.rate = Decimal(string: "0.2")!; deal.validGMV = 10000; deal.actualAdSpend = 1000; deal.shareCap = 150
        XCTAssertEqual(deal.cpsEstimate, 2000); XCTAssertEqual(deal.adShareEstimate, 150); deal.settlements.insert(.fixedLicense); XCTAssertThrowsError(try deal.validate())
    }
    func testSubscriptionValidityAndRenewalKeepOneCustomer() throws {
        var db = database(); var old = sale(subscription: true); old.paidAt = now.addingTimeInterval(-86400 * 20); old.expiresAt = now.addingTimeInterval(-86400); try db.recordToolSale(old)
        var renewal = sale(subscription: true); renewal.id = Codec.id(); renewal.receipt = "renewal-receipt"; renewal.orderReference = "renewal-order"; renewal.renewalOf = old.id; renewal.paidAt = now.addingTimeInterval(-100); try db.recordToolSale(renewal)
        let report = try CommercialAccounting.report(database: db, workspaceID: "w", start: now.addingTimeInterval(-86400 * 15), now: now)
        XCTAssertEqual(report.paidCustomers, 1); XCTAssertEqual(report.activeSubscriptions, 1); XCTAssertEqual(report.openingSubscriptionCustomers, 1); XCTAssertEqual(report.churnedSubscriptionCustomers, 0); XCTAssertEqual(report.renewedCustomers, 1)
        var invalid = renewal; invalid.paidAt = now.addingTimeInterval(100); XCTAssertFalse(invalid.active(at: now)); invalid.paidAt = now; invalid.refunded = 100; XCTAssertFalse(invalid.active(at: now))
        var stoppedRenewal = renewal; stoppedRenewal.autoRenew = false; XCTAssertTrue(stoppedRenewal.active(at: now)); stoppedRenewal.cancelled = true; XCTAssertFalse(stoppedRenewal.active(at: now))
    }
    func testMissingSubscriptionExpiryIsUnknownNotPermanentActive() throws {
        var db = database(); var sale = sale(subscription: true); sale.expiresAt = nil; XCTAssertFalse(sale.active(at: now)); XCTAssertThrowsError(try db.recordToolSale(sale))
    }
    func testSupportCostsEnterSharedExpenseOnceAndUnknownStaysUnknown() throws {
        var db = database(); var support = SupportRecord(workspaceID: "w", subject: "anonymous-free-user", audience: .free, topic: "安装支持", hours: 2, cost: nil, at: now, reference: "ticket-1")
        try db.recordSupport(support); support.id = Codec.id(); support.hours = 3; try db.recordSupport(support)
        XCTAssertEqual(db.expenses.count, 1); XCTAssertNil(db.expenses.first?.money); XCTAssertEqual(db.expenses.first?.hours, 3)
        let report = try CommercialAccounting.report(database: db, workspaceID: "w", start: now.addingTimeInterval(-86400), now: now); XCTAssertEqual(report.supportHoursByAudience[SupportAudience.free.rawValue], 3); XCTAssertEqual(report.unknownSupportCosts, 1)
    }
    func testFunnelUsesActualPaymentAndSameSubjectAndDeduplicatesEvidence() throws {
        var db = database(); var event = FunnelEvent(workspaceID: "w", subject: "anonymous-buyer", stage: FunnelStage.paid.rawValue, at: now); event.evidenceReference = "missing"
        XCTAssertThrowsError(try db.recordFunnel(event)); let sale = sale(); try db.recordToolSale(sale); event.evidenceReference = sale.id; try db.recordFunnel(event); var copy = event; copy.id = Codec.id(); try db.recordFunnel(copy); XCTAssertEqual(db.funnel.count, 1)
        copy.subject = "another-user"; XCTAssertThrowsError(try db.recordFunnel(copy)); event.stage = FunnelStage.refund.rawValue; XCTAssertThrowsError(try db.recordFunnel(event))
    }
    func testFunnelCannotTreatUnreviewedOutputAsValid() throws {
        var db = database(); var event = FunnelEvent(workspaceID: "w", subject: "anonymous-user", stage: FunnelStage.firstOutput.rawValue, at: now); event.evidenceReference = "missing-job"; XCTAssertThrowsError(try db.recordFunnel(event))
    }
    func testRevisionLimitAndApprovalInvalidation() throws {
        var db = database(); var deal = deal(); deal.approvedRevisionID = "previous-approved"; try db.recordBrandDeal(deal); try db.recordBrandRevision(dealID: deal.id, reason: "根据客户已核对参数修改")
        XCTAssertNil(db.brandDeals[0].approvedRevisionID); XCTAssertEqual(db.brandDeals[0].revisionNotes?.first, "根据客户已核对参数修改"); XCTAssertThrowsError(try db.recordBrandRevision(dealID: deal.id, reason: "超范围修改"))
    }
    func testOldCommercialRecordsDecodeWithoutNewOptionalMetadata() throws {
        let original = sale(); let decoded = try Codec.decoder().decode(ToolSale.self, from: Codec.data(original)); XCTAssertEqual(decoded.plan, original.plan); XCTAssertNil(decoded.renewalOf)
        let oldDeal = deal(); let restored = try Codec.decoder().decode(BrandDeal.self, from: Codec.data(oldDeal)); XCTAssertNil(restored.settlementRecords); XCTAssertNil(restored.checklistTemplate)
    }
    func testConfigurableChecklistRequiresExplicitItemsAndValidAge() throws {
        var template = VerticalChecklistTemplate(name: "自定义数码", requirements: [ChecklistRequirement(label: "指定固件的实机拍摄", maximumAgeDays: 30)]); try template.validate(); template.requirements[0].maximumAgeDays = 0; XCTAssertThrowsError(try template.validate())
    }
}
