import Foundation

public struct AcquisitionReport: Sendable {
    public var paymentCount: Int
    public var paid: Money
    public var acquiredCustomers: Int
    public var acquisitionCost: Money
    public var missingCostCustomers: Int
}

public enum AttributionAccounting {
    // One ordinary Expense is shared by every payment from this pseudonymous
    // buyer. The stable key supplies the relation without a parallel cost book.
    public static func acquisitionExpenseID(workspaceID: String, buyer: String) -> String {
        Codec.hash(Data(("customer-acquisition|" + workspaceID + "|" + buyer).utf8))
    }

    public static func report(database: Database, workspaceID: String, currency: String = "CNY") throws -> AcquisitionReport {
        _ = try database.workspace(workspaceID)
        let orders = database.orders.filter { $0.workspaceID == workspaceID && $0.paid.currency == currency && $0.paid.amount > 0 }
        let customers = Set(orders.filter { $0.kind == .new && !$0.buyer.isEmpty }.map(\.buyer))
        var cost: Decimal = 0
        var missing = 0
        for buyer in customers {
            let id = acquisitionExpenseID(workspaceID: workspaceID, buyer: buyer)
            guard let expense = database.expenses.first(where: { $0.id == id && $0.workspaceID == workspaceID }),
                  let money = expense.money, money.currency == currency else { missing += 1; continue }
            cost += money.amount
        }
        return AcquisitionReport(paymentCount: orders.count, paid: Money(orders.map { $0.paid.amount }.reduce(0,+), currency), acquiredCustomers: customers.count, acquisitionCost: Money(cost, currency), missingCostCustomers: missing)
    }
}

extension Database {
    public mutating func recordOrderAttribution(workspaceID: String, orderID: String, touchReference: String, weight: Decimal, method: String, confidence: String) throws {
        guard orders.contains(where: { $0.id == orderID && $0.workspaceID == workspaceID }) else { throw VideoError.notFound("归因订单不在当前工作区") }
        let reference = touchReference.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = method.trimmingCharacters(in: .whitespacesAndNewlines)
        let confidence = confidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty, reference.count <= 240, !method.isEmpty, method.count <= 240, !confidence.isEmpty, confidence.count <= 1000 else { throw VideoError.invalid("请填写明确的触达引用、归因方法和证据说明") }
        guard !attributions.contains(where: { $0.orderID == orderID && $0.publicationID == reference }) else { throw VideoError.conflict("同订单的同一触达引用不可重复登记") }
        let candidate = Attribution(orderID: orderID, publicationID: reference, weight: weight, method: method, confidence: confidence)
        let revised = attributions + [candidate]
        try Finance.validateAttribution(revised)
        attributions = revised
    }

    public func customerAcquisitionCost(workspaceID: String, orderID: String) throws -> Expense? {
        guard let order = orders.first(where: { $0.id == orderID && $0.workspaceID == workspaceID }), !order.buyer.isEmpty else { throw VideoError.invalid("该订单缺少可去重的买家标识") }
        let id = AttributionAccounting.acquisitionExpenseID(workspaceID: workspaceID, buyer: order.buyer)
        return expenses.first { $0.id == id && $0.workspaceID == workspaceID }
    }

    public mutating func recordCustomerAcquisitionCost(workspaceID: String, orderID: String, label: String, amount: Money) throws {
        guard let order = orders.first(where: { $0.id == orderID && $0.workspaceID == workspaceID }), order.paid.amount > 0, !order.buyer.isEmpty else { throw VideoError.invalid("获客成本需要当前工作区的实际付款及去标识买家") }
        guard order.paid.currency == amount.currency, amount.amount >= 0,
              orders.contains(where: { $0.workspaceID == workspaceID && $0.buyer == order.buyer && $0.kind == .new && $0.paid.amount > 0 && $0.paid.currency == amount.currency }) else { throw VideoError.invalid("须先核对同币种的新客付款，不把升单另计一次获客") }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw VideoError.invalid("请填写获客成本事项") }
        let id = AttributionAccounting.acquisitionExpenseID(workspaceID: workspaceID, buyer: order.buyer)
        if let prior = expenses.first(where: { $0.id == id }) {
            guard prior.workspaceID == workspaceID, prior.money == amount, prior.label == label, !prior.development, prior.hours == 0 else { throw VideoError.conflict("该买家已有获客成本；金额或事项不一致，请核对原记录，不能重复扣除") }
            return
        }
        expenses.append(Expense(id: id, workspaceID: workspaceID, label: label, money: amount))
    }
}
