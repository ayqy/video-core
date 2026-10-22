import Foundation

public struct CourseCohortFact: Codable, Equatable, Sendable {
    public var orderID: String
    public var paidAt: Date
    public var paid: Money
    public var fee: Decimal?
    public var refunds: [Refund]
}
public struct CourseCohortTotals: Codable, Equatable, Sendable {
    public var month: String
    public var currency: String
    public var orderCount: Int
    public var paid: Decimal
    public var knownFees: Decimal
    public var unknownFeeOrders: Int
    public var refunded: Decimal
    public var contribution: Decimal?
}
public struct CourseMonthCash: Codable, Equatable, Sendable {
    public var month: String
    public var currency: String
    public var paymentCount: Int
    public var received: Decimal
    public var knownFees: Decimal
    public var unknownFeeOrders: Int
    public var refundCount: Int
    public var refunded: Decimal
    public var netChange: Decimal? { unknownFeeOrders == 0 ? received - knownFees - refunded : nil }
}
public struct CourseRefundRevision: Codable, Equatable, Sendable {
    public var orderID: String
    public var refundID: String
    public var amount: Decimal
    public var refundAt: Date
    public var importID: String
    public var importedAt: Date
    public var beforeContribution: Decimal?
    public var afterContribution: Decimal?
}
public struct CourseCohortStatement: Codable, Identifiable, Sendable {
    public var id: String
    public var workspaceID: String
    public var month: String
    public var currency: String
    public var version: Int
    public var generatedAt: Date
    public var inputDigest: String
    public var sourceFacts: [CourseCohortFact]
    public var sourceImportIDs: [String]
    public var report: CourseCohortTotals
    public var previousID: String?
    public var triggerImportID: String?
    public var reason: String
    public var refundChanges: [CourseRefundRevision]
}

/// Calendar-month course accounting. Other income routes and shared expenses retain
/// their existing reports; these totals are never appended as duplicate cash entries.
public enum CohortFinance {
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    public static func month(containing date: Date = Date(), offset: Int = 0) -> String {
        let target = calendar.date(byAdding: .month, value: offset, to: date) ?? date
        let components = calendar.dateComponents([.year, .month], from: target)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }
    public static func interval(_ month: String) throws -> DateInterval {
        guard month.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil else {
            throw VideoError.invalid("月份须为北京时间YYYY-MM")
        }
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...9998).contains(parts[0]),
              let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start), self.month(containing: start) == month else {
            throw VideoError.invalid("月份超出可核对范围")
        }
        return DateInterval(start: start, end: end)
    }
    private static func currency(_ value: String) throws -> String {
        let code = value.uppercased()
        guard code.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { throw VideoError.invalid("请按三位币种分别核对月报") }
        return code
    }
    private static func contains(_ date: Date, in interval: DateInterval) -> Bool {
        date >= interval.start && date < interval.end
    }
    private static func orders(_ database: Database, workspaceID: String) throws -> [Order] {
        _ = try database.workspace(workspaceID)
        let rows = database.orders.filter { $0.workspaceID == workspaceID }
        guard Set(rows.map(\.id)).count == rows.count else { throw VideoError.invalid("同一工作区的月报订单标识重复") }
        for row in rows {
            try row.validate()
            guard row.paidAt.timeIntervalSince1970.isFinite, !row.paid.amount.isNaN,
                  row.fee.map({ !$0.isNaN }) ?? true,
                  row.refunds.allSatisfy({ !$0.amount.isNaN && $0.at.timeIntervalSince1970.isFinite && $0.at >= row.paidAt }) else {
                throw VideoError.invalid("月报的付款、费用或退款时间无效；退款不能早于原付款")
            }
        }
        return rows
    }
    private static func facts(_ rows: [Order], month: String, currency: String, now: Date) throws -> [CourseCohortFact] {
        let period = try interval(month)
        return rows.filter { $0.paid.currency == currency && contains($0.paidAt, in: period) && $0.paidAt <= now }.map {
            CourseCohortFact(orderID: $0.id, paidAt: $0.paidAt, paid: $0.paid, fee: $0.fee,
                             refunds: $0.refunds.filter { $0.at <= now }.sorted { $0.id < $1.id })
        }.sorted { $0.orderID < $1.orderID }
    }
    private static func totals(_ facts: [CourseCohortFact], month: String, currency: String) -> CourseCohortTotals {
        let paid = facts.reduce(Decimal(0)) { $0 + $1.paid.amount }, fees = facts.compactMap(\.fee).reduce(0, +)
        let unknown = facts.filter { $0.fee == nil }.count, refunded = facts.flatMap(\.refunds).reduce(Decimal(0)) { $0 + $1.amount }
        return CourseCohortTotals(month: month, currency: currency, orderCount: facts.count,
                                  paid: paid, knownFees: fees, unknownFeeOrders: unknown, refunded: refunded,
                                  contribution: unknown == 0 ? paid - fees - refunded : nil)
    }
    private static func contribution(paid: Money, fee: Decimal?, refunds: [Refund], through date: Date) -> Decimal? {
        guard let fee else { return nil }
        let refunded = refunds.filter { $0.at <= date }.reduce(Decimal(0)) { $0 + $1.amount }
        return paid.amount - fee - refunded
    }
    public static func cohort(database: Database, workspaceID: String, month: String, currency requested: String = "CNY", now: Date = Date()) throws -> CourseCohortTotals {
        let code = try currency(requested)
        return totals(try facts(orders(database, workspaceID: workspaceID), month: month, currency: code, now: now), month: month, currency: code)
    }
    public static func cash(database: Database, workspaceID: String, month: String, currency requested: String = "CNY", now: Date = Date()) throws -> CourseMonthCash {
        let code = try currency(requested), period = try interval(month)
        let rows = try orders(database, workspaceID: workspaceID).filter { $0.paid.currency == code && $0.paidAt <= now }
        let payments = rows.filter { contains($0.paidAt, in: period) }
        let refunds = rows.flatMap(\.refunds).filter { contains($0.at, in: period) && $0.at <= now }
        return CourseMonthCash(month: month, currency: code, paymentCount: payments.count,
                               received: payments.reduce(0) { $0 + $1.paid.amount }, knownFees: payments.compactMap(\.fee).reduce(0, +),
                               unknownFeeOrders: payments.filter { $0.fee == nil }.count, refundCount: refunds.count,
                               refunded: refunds.reduce(0) { $0 + $1.amount })
    }
    static func capture(database: inout Database, workspaceID: String, month: String, currency requested: String, now: Date,
                        trigger: ImportReceipt? = nil, rollback: Bool = false) throws -> CourseCohortStatement {
        let code = try currency(requested), rows = try orders(database, workspaceID: workspaceID)
        let input = try facts(rows, month: month, currency: code, now: now)
        let digest = try Codec.digest(input)
        let old = (database.courseCohortStatements ?? []).filter { $0.workspaceID == workspaceID && $0.month == month && $0.currency == code }.max { $0.version < $1.version }
        guard !input.isEmpty || (old != nil && trigger != nil) else { throw VideoError.invalid("此月份与币种没有已发生的课程付款，未生成空白月报") }
        if let old, old.inputDigest == digest { return old }
        let ids = Set(input.map(\.orderID))
        let importIDs = database.imports.filter { !$0.rolledBack && $0.kind == "orders" && !ids.isDisjoint(with: $0.orderIDs) && ($0.workspaceID == nil || $0.workspaceID == workspaceID) }.map(\.id).sorted()
        var changes: [CourseRefundRevision] = []
        if let trigger, !rollback {
            for row in rows where ids.contains(row.id) && trigger.orderIDs.contains(row.id) {
                let prior = trigger.previousOrders.first { $0.id == row.id && $0.workspaceID == workspaceID }
                let previousIDs = Set((prior?.refunds ?? []).map(\.id))
                for refund in row.refunds where !previousIDs.contains(refund.id) && refund.at <= now {
                    changes.append(CourseRefundRevision(orderID: row.id, refundID: refund.id, amount: refund.amount, refundAt: refund.at,
                                                        importID: trigger.id, importedAt: trigger.at,
                                                        beforeContribution: prior.flatMap { contribution(paid: $0.paid, fee: $0.fee, refunds: $0.refunds, through: now) },
                                                        afterContribution: contribution(paid: row.paid, fee: row.fee, refunds: row.refunds, through: now)))
                }
            }
        }
        let value = CourseCohortStatement(id: Codec.id(), workspaceID: workspaceID, month: month, currency: code,
                                          version: (old?.version ?? 0) + 1, generatedAt: now, inputDigest: digest,
                                          sourceFacts: input, sourceImportIDs: importIDs, report: totals(input, month: month, currency: code),
                                          previousID: old?.id, triggerImportID: trigger?.id,
                                          reason: trigger == nil ? "用户记录当前月报" : rollback ? "订单导入回滚修订" : "订单或退款导入修订",
                                          refundChanges: changes.sorted { $0.refundID < $1.refundID })
        database.courseCohortStatements = (database.courseCohortStatements ?? []) + [value]
        return value
    }
    /// Only previously recorded reports receive automatic revisions. No historical
    /// statement is invented from a previous-order receipt after a refund arrives.
    static func refreshRecorded(database: inout Database, affected: [Order], receipt: ImportReceipt, rollback: Bool = false) throws {
        let existing = database.courseCohortStatements ?? []
        let keys = Set(affected.map { $0.workspaceID + "|" + month(containing: $0.paidAt) + "|" + $0.paid.currency })
        let latest = Dictionary(grouping: existing, by: { $0.workspaceID + "|" + $0.month + "|" + $0.currency }).compactMapValues { $0.max { $0.version < $1.version } }
        for key in keys.sorted() {
            guard let report = latest[key] else { continue }
            _ = try capture(database: &database, workspaceID: report.workspaceID, month: report.month, currency: report.currency,
                            now: Date(), trigger: receipt, rollback: rollback)
        }
    }
    private static func validateSources(_ record: CourseCohortStatement, in database: Database) throws {
        let factIDs = Set(record.sourceFacts.map(\.orderID))
        func receipt(_ id: String, importedAt: Date? = nil) throws -> ImportReceipt {
            let candidates = database.imports.filter {
                $0.id == id && $0.kind == "orders" && ($0.workspaceID == nil || $0.workspaceID == record.workspaceID) &&
                $0.at.timeIntervalSince1970.isFinite && $0.at <= record.generatedAt && (importedAt == nil || $0.at == importedAt)
            }
            guard let value = candidates.max(by: { $0.at < $1.at }) else {
                throw VideoError.invalid("课程月报来源批次不存在、时间无效或属于其他工作区")
            }
            return value
        }
        guard record.sourceImportIDs == record.sourceImportIDs.sorted(), Set(record.sourceImportIDs).count == record.sourceImportIDs.count else {
            throw VideoError.invalid("课程月报来源批次重复或顺序不稳定")
        }
        for id in record.sourceImportIDs {
            let value = try receipt(id)
            guard !factIDs.isDisjoint(with: value.orderIDs) else { throw VideoError.invalid("课程月报来源批次没有对应订单") }
        }
        guard let triggerID = record.triggerImportID else {
            guard record.refundChanges.isEmpty else { throw VideoError.invalid("退款修订缺少实际导入批次") }
            return
        }
        // A rolled-back CSV can be imported again with the same content-derived batch ID.
        // Refund changes pin the actual receipt occurrence rather than an earlier use of that ID.
        let trigger = try receipt(triggerID, importedAt: record.refundChanges.first?.importedAt)
        guard Set(record.refundChanges.map { $0.orderID + "|" + $0.refundID }).count == record.refundChanges.count else {
            throw VideoError.invalid("课程月报退款修订事件重复")
        }
        for change in record.refundChanges {
            guard let fact = record.sourceFacts.first(where: { $0.orderID == change.orderID }),
                  let refund = fact.refunds.first(where: { $0.id == change.refundID }),
                  trigger.orderIDs.contains(change.orderID), change.importID == trigger.id, change.importedAt == trigger.at,
                  refund.amount == change.amount, refund.at == change.refundAt else {
                throw VideoError.invalid("课程月报退款事件与来源事实或实际导入回执不一致")
            }
            let prior = trigger.previousOrders.first { $0.id == change.orderID && $0.workspaceID == record.workspaceID }
            let before = prior.flatMap { contribution(paid: $0.paid, fee: $0.fee, refunds: $0.refunds, through: record.generatedAt) }
            let after = contribution(paid: fact.paid, fee: fact.fee, refunds: fact.refunds, through: record.generatedAt)
            guard prior?.refunds.contains(where: { $0.id == change.refundID }) != true,
                  change.beforeContribution == before, change.afterContribution == after else {
                throw VideoError.invalid("课程月报退款前值与原导入回执不一致")
            }
        }
    }
    static func validateStatements(_ database: Database) throws {
        let records = database.courseCohortStatements ?? []
        guard Set(records.map(\.id)).count == records.count else { throw VideoError.invalid("课程月报修订ID重复") }
        for groups in Dictionary(grouping: records, by: { $0.workspaceID + "|" + $0.month + "|" + $0.currency }).values {
            let sorted = groups.sorted { $0.version < $1.version }
            for (index, record) in sorted.enumerated() {
                _ = try database.workspace(record.workspaceID)
                let period = try interval(record.month); _ = try currency(record.currency)
                try validateSources(record, in: database)
                let validFacts = record.sourceFacts.allSatisfy { fact in
                    let refunds = fact.refunds.reduce(Decimal(0)) { $0 + $1.amount }
                    return !fact.orderID.isEmpty && fact.paidAt.timeIntervalSince1970.isFinite && fact.paidAt <= record.generatedAt &&
                        !fact.paid.amount.isNaN && fact.paid.amount >= 0 &&
                        (fact.fee.map { !$0.isNaN && $0 >= 0 } ?? true) &&
                        Set(fact.refunds.map(\.id)).count == fact.refunds.count && refunds <= fact.paid.amount &&
                        fact.refunds.allSatisfy { !$0.id.isEmpty && !$0.amount.isNaN && $0.amount >= 0 && $0.at >= fact.paidAt && $0.at <= record.generatedAt }
                }
                guard !record.id.isEmpty, record.generatedAt.timeIntervalSince1970.isFinite,
                      record.currency == record.currency.uppercased(),
                      record.version == index + 1, record.previousID == (index == 0 ? nil : sorted[index - 1].id),
                      index == 0 || record.generatedAt >= sorted[index - 1].generatedAt,
                      validFacts,
                      record.sourceFacts == record.sourceFacts.sorted(by: { $0.orderID < $1.orderID }),
                      Set(record.sourceFacts.map(\.orderID)).count == record.sourceFacts.count,
                      record.sourceFacts.allSatisfy({ $0.paid.currency == record.currency && contains($0.paidAt, in: period) }),
                      record.inputDigest == (try Codec.digest(record.sourceFacts)),
                      record.report == totals(record.sourceFacts, month: record.month, currency: record.currency) else {
                    throw VideoError.invalid("课程月报原值、来源摘要或修订链不一致，未覆盖原报表")
                }
            }
        }
    }
}

public extension Database {
    @discardableResult mutating func recordCourseCohort(workspaceID: String, month: String, currency: String = "CNY", now: Date = Date()) throws -> CourseCohortStatement {
        try CohortFinance.capture(database: &self, workspaceID: workspaceID, month: month, currency: currency, now: now)
    }
}
