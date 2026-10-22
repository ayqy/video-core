import XCTest
@testable import VideoCore

final class AttributionEditingTests: XCTestCase {
    private func book() throws -> (Database, Order, Order) {
        var db = Database()
        let workspace = Workspace(name: "隔离规则测试", owner: "owner")
        db.workspaces = [workspace]
        let entry = try Order(workspaceID: workspace.id, platform: "shop", rawOrderID: "entry", rawBuyerID: "same-buyer", salt: workspace.salt, sku: "入口", paidAt: Date().addingTimeInterval(-86400), paid: Money(1), fee: 0, kind: .new, importID: "entry")
        let upgrade = try Order(workspaceID: workspace.id, platform: "shop", rawOrderID: "upgrade", rawBuyerID: "same-buyer", salt: workspace.salt, sku: "升单", paidAt: Date(), paid: Money(200), fee: 0, kind: .upgrade, importID: "upgrade")
        try db.importOrders([entry, upgrade], batchID: "both")
        return (db, entry, upgrade)
    }
    func testTwoPaymentsShareOneAcquisitionAndOneExistingExpense() throws {
        var (db, entry, upgrade) = try book()
        let before = try AttributionAccounting.report(database: db, workspaceID: entry.workspaceID)
        XCTAssertEqual(before.paymentCount, 2); XCTAssertEqual(before.paid.amount, 201)
        XCTAssertEqual(before.acquiredCustomers, 1); XCTAssertEqual(before.missingCostCustomers, 1)
        for order in [entry, upgrade] {
            try db.recordCustomerAcquisitionCost(workspaceID: entry.workspaceID, orderID: order.id, label: "真实获客事项", amount: Money(10))
        }
        XCTAssertEqual(db.expenses.count, 1)
        let after = try AttributionAccounting.report(database: db, workspaceID: entry.workspaceID)
        XCTAssertEqual(after.acquisitionCost.amount, 10); XCTAssertEqual(after.missingCostCustomers, 0)
        let finance = try Finance.report(orders: db.orders, cash: db.cash, expenses: db.expenses, baseline: nil)
        XCTAssertEqual(finance.sharedCashCost, 10)
        XCTAssertThrowsError(try db.recordCustomerAcquisitionCost(workspaceID: entry.workspaceID, orderID: upgrade.id, label: "真实获客事项", amount: Money(20)))
        XCTAssertEqual(db.expenses.count, 1)
    }
    func testExplicitTouchesRejectDuplicatesAndOverflowAtomically() throws {
        var (db, entry, _) = try book()
        try db.recordOrderAttribution(workspaceID: entry.workspaceID, orderID: entry.id, touchReference: "touch-A", weight: Decimal(string: "0.6")!, method: "人工多触点", confidence: "已核原凭据")
        XCTAssertThrowsError(try db.recordOrderAttribution(workspaceID: entry.workspaceID, orderID: entry.id, touchReference: "touch-A", weight: Decimal(string: "0.1")!, method: "重复", confidence: "重复触达"))
        XCTAssertThrowsError(try db.recordOrderAttribution(workspaceID: entry.workspaceID, orderID: entry.id, touchReference: "touch-B", weight: Decimal(string: "0.5")!, method: "人工多触点", confidence: "已核原凭据"))
        XCTAssertEqual(db.attributions.count, 1)
        try db.recordOrderAttribution(workspaceID: entry.workspaceID, orderID: entry.id, touchReference: "touch-B", weight: Decimal(string: "0.4")!, method: "人工多触点", confidence: "已核原凭据")
        XCTAssertEqual(db.attributions.map(\.weight).reduce(0,+), 1)
        XCTAssertEqual(db.expenses.count, 0, "触达不能自动再记获客成本")
        try db.validate()
    }
    func testAttributionAndCostCannotUseAnotherWorkspaceOrUnknownBuyer() throws {
        var (db, entry, _) = try book()
        XCTAssertThrowsError(try db.recordOrderAttribution(workspaceID: "other", orderID: entry.id, touchReference: "A", weight: 1, method: "人工", confidence: "凭据"))
        XCTAssertThrowsError(try db.recordCustomerAcquisitionCost(workspaceID: "other", orderID: entry.id, label: "成本", amount: Money(10)))
        db.orders[0].buyer = ""
        XCTAssertThrowsError(try db.recordCustomerAcquisitionCost(workspaceID: entry.workspaceID, orderID: db.orders[0].id, label: "成本", amount: Money(10)))
        XCTAssertTrue(db.attributions.isEmpty); XCTAssertTrue(db.expenses.isEmpty)
    }
}
