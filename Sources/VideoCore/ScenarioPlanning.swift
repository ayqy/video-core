import Foundation

/// Passive hypothetical inputs. This module has no repository, ledger or network API.
public struct ScenarioUnitPlan: Codable, Equatable, Sendable {
    public var quantity: Int? = 0
    public var price: Decimal? = 200
    public var refundRate: Decimal? = Decimal(string: "0.05")
    public var platformRate: Decimal? = Decimal(string: "0.02")
    public var settlementRate: Decimal? = 0
    public var taxReserveRate: Decimal? = Decimal(string: "0.10")
    public var serviceCash: Decimal? = 3
    public var acquisitionCash: Decimal? = 0
    public var serviceHours: Decimal? = Decimal(string: "0.15")
    public init() {}
}
public enum ScenarioIncentiveMode: String, Codable, CaseIterable, Sendable {
    case excluded, unknown, settlement, rpm
    public var label: String {
        switch self {
        case .excluded: return "不纳入（预算0，非实收）"
        case .unknown: return "未知，不当作0"
        case .settlement: return "已核实收输入，仅供情景"
        case .rpm: return "假设RPM与播放"
        }
    }
}
public struct ScenarioPlan: Codable, Equatable, Sendable {
    public var currency = "CNY"
    public var courses: [ScenarioUnitPlan]
    public var toolEnabled = false
    public var tool: ScenarioUnitPlan
    public var toolSubscription = false
    public var toolChurnRate: Decimal? = Decimal(string: "0.05")
    public var toolMonthlyCash: Decimal? = 1000
    public var toolMonthlyHours: Decimal? = 20
    public var brandEnabled = false
    public var brandQuantity: Int? = 2
    public var brandQuote: Decimal? = 3000
    public var brandBadDebtRate: Decimal? = Decimal(string: "0.10")
    public var brandTaxRate: Decimal? = Decimal(string: "0.10")
    public var brandCash: Decimal? = 300
    public var brandAcquisitionCash: Decimal? = 0
    public var brandHours: Decimal? = 8
    public var contentQuantity: Int? = 24
    public var contentUnitCash: Decimal? = 20
    public var runningCash: Decimal? = 520
    public var maintenanceCash: Decimal? = 500
    public var otherIncrementalCash: Decimal? = 0
    public var baseHours: Decimal? = 80
    public var capacityHours: Decimal? = 160
    public var existingSurplus: Decimal? = 0
    public var cannibalizedContribution: Decimal? = 0
    public var target: Decimal? = 10000
    public var incentiveMode: ScenarioIncentiveMode = .excluded
    public var incentiveSettlement: Decimal?
    public var incentiveReceipt = ""
    public var incentiveViews: Decimal?
    public var incentiveRPM: Decimal?
    public var incentiveTaxRate: Decimal? = Decimal(string: "0.10")
    public var developmentCash: Decimal? = 1000
    public var developmentHours: Decimal? = 40
    public var hourlyOpportunityCost: Decimal? = 100
    public var amortizeDevelopment = false
    public var developmentRecoveryMonths: Int? = 6
    public init() {
        let prices = ["1", "30", "99", "200"], cash = ["0.2", "1", "2", "3"], hours = ["0.02", "0.05", "0.10", "0.15"]
        courses = prices.indices.map { index in
            var value = ScenarioUnitPlan(); value.price = Decimal(string: prices[index]); value.serviceCash = Decimal(string: cash[index])
            value.serviceHours = Decimal(string: hours[index]); value.quantity = index == 3 ? 70 : 0
            return value
        }
        var value = ScenarioUnitPlan(); value.quantity = 10; value.price = 199; value.refundRate = Decimal(string: "0.08")
        value.serviceCash = 5; value.serviceHours = Decimal(string: "0.8"); tool = value
    }
}
public struct ScenarioReport: Codable, Equatable, Sendable {
    public var currency: String
    public var courseContribution: Decimal?
    public var toolContribution: Decimal?
    public var brandContribution: Decimal?
    public var incentiveContribution: Decimal?
    public var sharedCashCost: Decimal?
    public var additionalToolCash: Decimal?
    public var operatingSurplus: Decimal?
    public var operatingHours: Decimal?
    public var economicProfit: Decimal?
    public var requiredReplacementSubscribers: Decimal?
    public var developmentCash: Decimal?
    public var developmentHours: Decimal?
    public var developmentEconomicCost: Decimal?
    public var developmentMonthlyRecovery: Decimal?
    public var afterDevelopmentRecovery: Decimal?
    public var targetReached: Bool?
    public var capacityExceeded: Bool?
    public var unknownInputs: [String]
}

public enum ScenarioPlanning {
    public static let notice = "仅假设，不计实收；销量、费率和工时不代表真实经营，不保证稳定万元。"
    public static func evaluate(_ plan: ScenarioPlan) throws -> ScenarioReport {
        let currency = plan.currency.uppercased()
        guard currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil, !plan.courses.isEmpty, plan.courses.count <= 16 else {
            throw VideoError.invalid("情景须使用单一三位币种和1至16个价格槽位；不自动换汇")
        }
        var unknown: [String] = []
        func amount(_ value: Decimal?, _ label: String, signed: Bool = false) throws -> Decimal? {
            guard let value else { unknown.append(label); return nil }
            guard !value.isNaN, signed || value >= 0 else { throw VideoError.invalid(label + "须为有效非负数字，未知请留空") }
            return value
        }
        func rate(_ value: Decimal?, _ label: String) throws -> Decimal? {
            let result = try amount(value, label)
            guard result == nil || result! <= 1 else { throw VideoError.invalid(label + "须在0至1之间") }
            return result
        }
        func quantity(_ value: Int?, _ label: String) throws -> Decimal? {
            guard let value else { unknown.append(label); return nil }
            guard value >= 0 else { throw VideoError.invalid(label + "须为非负整数") }
            return Decimal(value)
        }
        func sum(_ values: [Decimal?]) -> Decimal? {
            guard values.allSatisfy({ $0 != nil }) else { return nil }
            return values.compactMap { $0 }.reduce(0, +)
        }
        func product(_ left: Decimal?, _ right: Decimal?) -> Decimal? {
            guard let left, let right else { return nil }; return left * right
        }
        func subtract(_ left: Decimal?, _ right: Decimal?) -> Decimal? {
            guard let left, let right else { return nil }; return left - right
        }
        func unit(_ input: ScenarioUnitPlan, _ label: String) throws -> (cash: Decimal?, hours: Decimal?) {
            let count = try quantity(input.quantity, label + "单量")
            if count == 0 { return (0, 0) }
            let price = try amount(input.price, label + "单价")
            let refund = try rate(input.refundRate, label + "退款比例"), platform = try rate(input.platformRate, label + "平台费比例")
            let settlement = try rate(input.settlementRate, label + "结算费比例"), tax = try rate(input.taxReserveRate, label + "税费预留比例")
            let service = try amount(input.serviceCash, label + "每单服务现金"), cac = try amount(input.acquisitionCash, label + "每单获客现金")
            let hours = try amount(input.serviceHours, label + "每单服务工时")
            var value: Decimal?
            if let price, let refund, let platform, let settlement, let tax, let service, let cac {
                // Platform fees are based on original gross, even for refunded orders.
                value = price * (1 - refund - platform) * (1 - settlement) * (1 - tax) - service - cac
            }
            return (product(count, value), product(count, hours))
        }
        let courses = try plan.courses.enumerated().map { try unit($0.element, "课程槽位\($0.offset + 1)") }
        let tool = plan.toolEnabled ? try unit(plan.tool, "工具") : (cash: Decimal?.some(0), hours: Decimal?.some(0))
        let toolCash = plan.toolEnabled ? try amount(plan.toolMonthlyCash, "工具额外月现金") : 0
        let toolHours = plan.toolEnabled ? try amount(plan.toolMonthlyHours, "工具额外月工时") : 0
        var replacements: Decimal?
        if plan.toolEnabled && plan.toolSubscription {
            let active = try quantity(plan.tool.quantity, "订阅付费活跃"), churn = try rate(plan.toolChurnRate, "工具月流失比例")
            if let needed = product(active, churn) {
                var source = needed, rounded = Decimal(); NSDecimalRound(&rounded, &source, 0, .up); replacements = rounded
            }
        }
        var brand: Decimal? = 0, brandHours: Decimal? = 0
        if plan.brandEnabled {
            let count = try quantity(plan.brandQuantity, "商单数量")
            if count != 0 {
                let quote = try amount(plan.brandQuote, "商单单价"), loss = try rate(plan.brandBadDebtRate, "商单渠道坏账预留比例")
                let tax = try rate(plan.brandTaxRate, "商单税费预留比例"), cash = try amount(plan.brandCash, "商单每单现金")
                let cac = try amount(plan.brandAcquisitionCash, "商单每单获客现金"), hours = try amount(plan.brandHours, "商单每单工时")
                if let count, let quote, let loss, let tax, let cash, let cac { brand = count * (quote * (1 - loss) * (1 - tax) - cash - cac) }
                else { brand = nil }
                brandHours = product(count, hours)
            }
        }
        let contentCount = try quantity(plan.contentQuantity, "共用内容数量")
        let contentUnit = try amount(plan.contentUnitCash, "每条内容现金")
        let shared = try sum([product(contentCount, contentUnit), amount(plan.runningCash, "共用运行现金"), amount(plan.maintenanceCash, "共用维护现金"), amount(plan.otherIncrementalCash, "其他新增现金")])
        let baseHours = try amount(plan.baseHours, "基础运营工时"), capacity = try amount(plan.capacityHours, "工时容量")
        let existing = try amount(plan.existingSurplus, "已有稳定盈余输入", signed: true), cannibalized = try amount(plan.cannibalizedContribution, "被蚕食贡献")
        let target = try amount(plan.target, "情景月目标")
        var incentive: Decimal?
        switch plan.incentiveMode {
        case .excluded: incentive = 0
        case .unknown: unknown.append("激励输入")
        case .settlement:
            incentive = try amount(plan.incentiveSettlement, "已核激励实收输入")
            guard incentive == nil || !plan.incentiveReceipt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VideoError.invalid("已核激励输入需保留凭证引用；未核请选择未知") }
        case .rpm:
            let views = try amount(plan.incentiveViews, "假设合格播放"), rpm = try amount(plan.incentiveRPM, "假设每千次激励")
            let tax = try rate(plan.incentiveTaxRate, "激励税费预留比例")
            if let views, let rpm, let tax { incentive = views / 1000 * rpm * (1 - tax) }
        }
        let course = sum(courses.map(\.cash))
        let surplus = subtract(sum([course, tool.cash, brand, incentive, existing]), sum([shared, toolCash, cannibalized]))
        let hours = sum([baseHours, sum(courses.map(\.hours)), tool.hours, brandHours, toolHours])
        let developmentCash = try amount(plan.developmentCash, "一次开发现金"), developmentHours = try amount(plan.developmentHours, "一次开发工时")
        let hourly = try amount(plan.hourlyOpportunityCost, "每小时机会成本")
        let development = sum([developmentCash, product(developmentHours, hourly)])
        var monthly: Decimal?
        if plan.amortizeDevelopment {
            let months = try quantity(plan.developmentRecoveryMonths, "开发回收月数")
            guard months == nil || months! > 0 else { throw VideoError.invalid("开发回收月数须为正整数") }
            if let months, let development { monthly = development / months }
        }
        let economicProfit = subtract(surplus, product(hours, hourly))
        let afterRecovery = plan.amortizeDevelopment ? subtract(surplus, monthly) : nil
        let moneyValues = [course, tool.cash, brand, incentive, shared, toolCash, surplus, hours, development, monthly, economicProfit, afterRecovery, replacements]
        guard moneyValues.compactMap({ $0 }).allSatisfy({ !$0.isNaN }) else { throw VideoError.invalid("情景计算超出十进制可用范围") }
        return ScenarioReport(currency: currency, courseContribution: course, toolContribution: tool.cash, brandContribution: brand,
                              incentiveContribution: incentive, sharedCashCost: shared, additionalToolCash: toolCash,
                              operatingSurplus: surplus, operatingHours: hours, economicProfit: economicProfit,
                              requiredReplacementSubscribers: replacements, developmentCash: developmentCash, developmentHours: developmentHours,
                              developmentEconomicCost: development, developmentMonthlyRecovery: monthly,
                              afterDevelopmentRecovery: afterRecovery,
                              targetReached: surplus.flatMap { value in target.map { value >= $0 } },
                              capacityExceeded: hours.flatMap { value in capacity.map { value > $0 } }, unknownInputs: Array(Set(unknown)).sorted())
    }
}
