import Foundation

public enum SupportAudience: String, Codable, CaseIterable, Sendable { case community = "社区", free = "免费用户", paid = "付费客户" }
public struct SupportRecord: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var workspaceID: String; public var subject: String; public var audience: SupportAudience; public var topic: String; public var hours: Decimal; public var cost: Money?; public var at: Date; public var reference: String
    public init(workspaceID: String, subject: String, audience: SupportAudience, topic: String, hours: Decimal, cost: Money?, at: Date = Date(), reference: String) { self.workspaceID = workspaceID; self.subject = subject; self.audience = audience; self.topic = topic; self.hours = hours; self.cost = cost; self.at = at; self.reference = reference }
    public func validate() throws { guard !topic.isEmpty, !reference.isEmpty, hours >= 0, cost == nil || cost!.amount >= 0 else { throw VideoError.invalid("支持记录须保留事项、工单来源、非负工时与成本；未知成本留空") } }
}
public struct ChecklistRequirement: Codable, Equatable, Identifiable, Sendable {
    public var id = Codec.id(); public var label: String; public var evidenceRequired: Bool; public var maximumAgeDays: Int?
    public init(label: String, evidenceRequired: Bool = true, maximumAgeDays: Int? = nil) { self.label = label; self.evidenceRequired = evidenceRequired; self.maximumAgeDays = maximumAgeDays }
}
public struct VerticalChecklistTemplate: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var name: String; public var version = 1; public var requirements: [ChecklistRequirement]
    public init(name: String, requirements: [ChecklistRequirement]) { self.name = name; self.requirements = requirements }
    public func validate() throws { guard !name.isEmpty, version > 0, !requirements.isEmpty, Set(requirements.map(\.id)).count == requirements.count, requirements.allSatisfy({ !$0.label.isEmpty && ($0.maximumAgeDays == nil || $0.maximumAgeDays! > 0) }) else { throw VideoError.invalid("垂类清单名称、版本、核验项或事实有效期无效") } }
    public static func standard(for vertical: String) -> VerticalChecklistTemplate { VerticalChecklistTemplate(name: vertical, requirements: BrandDeal.checklist(for: vertical).map { ChecklistRequirement(label: $0, maximumAgeDays: vertical == "留学" ? 365 : nil) }) }
}
public enum AuthorizationScope: String, Codable, CaseIterable, Sendable { case material = "素材", voice = "声音", likeness = "肖像", distribution = "平台分发", advertising = "付费投广" }
public struct CommercialAuthorization: Codable, Identifiable, Sendable {
    public var id = Codec.id(); public var scope: AuthorizationScope; public var evidenceID: String; public var usage: String; public var from: Date; public var until: Date
    public init(scope: AuthorizationScope, evidenceID: String, usage: String, from: Date = Date(), until: Date) { self.scope = scope; self.evidenceID = evidenceID; self.usage = usage; self.from = from; self.until = until }
}
public struct BrandApproval: Codable, Sendable { public var revisionID: String; public var digest: String; public var reviewer: String; public var at: Date; public var note: String; public var termsDigest: String?; public var revisionsUsed: Int? }
public struct BrandSettlement: Codable, Identifiable, Sendable {
    public var id: String; public var kind: Settlement; public var received: Money; public var refunded: Decimal; public var at: Date; public var receipt: String; public var note: String
    public init(id: String = Codec.id(), kind: Settlement, received: Money, refunded: Decimal = 0, at: Date = Date(), receipt: String, note: String = "") { self.id = id; self.kind = kind; self.received = received; self.refunded = refunded; self.at = at; self.receipt = receipt; self.note = note }
    public func validate() throws { guard !id.isEmpty, !receipt.isEmpty, received.amount >= 0, refunded >= 0, refunded <= received.amount else { throw VideoError.invalid("商单实收/退款须有结算凭证且退款不超过实收") } }
}
public enum FunnelStage: String, Codable, CaseIterable, Sendable {
    case free = "免费触达", installed = "实际安装", firstOutput = "首次有效成片", repeatOutput = "重复成片", premiumTrial = "高级试用", paid = "实际付款", refund = "实际退款", renewal = "实际续费"
}
public struct FunnelCount: Codable, Identifiable, Sendable { public var id: String { stage }; public var stage: String; public var subjects: Int; public var events: Int }
public struct CommercialReport: Codable, Sendable {
    public var currency: String; public var actualToolNet: Decimal; public var actualBrandBySettlement: [String: Decimal]; public var paidCustomers: Int; public var activePaidCustomers: Int; public var activeSubscriptions: Int; public var expiredSubscriptions: Int; public var terminatedSubscriptions: Int; public var refundedSales: Int; public var renewedCustomers: Int; public var openingSubscriptionCustomers: Int; public var churnedSubscriptionCustomers: Int; public var observedChurnRate: Decimal?; public var funnel: [FunnelCount]; public var supportHoursByAudience: [String: Decimal]; public var supportCostByAudience: [String: Decimal]; public var unknownSupportCosts: Int; public var warnings: [String]
}

/// Brand approval is independent of the author's picture/sound review. These checks do not call
/// Quality, so a draft can be rendered and reviewed before a brand reviewer grants final delivery.
public enum BrandDeliveryRules {
    private struct TermsSnapshot: Encodable { var deal: BrandDeal; var evidence: [Evidence]; var assets: [Asset] }
    public static func termsDigest(deal: BrandDeal, database: Database) throws -> String {
        var contract = deal
        contract.approvedRevisionID = nil; contract.approvals = nil; contract.received = nil; contract.receipt = ""; contract.noncash = ""; contract.settlementRecords = nil; contract.legacyCash = nil; contract.validGMV = 0; contract.actualAdSpend = 0; contract.revisionNotes = nil
        if let authorizations = contract.authorizations { contract.authorizations = authorizations.sorted { $0.id < $1.id } }
        let ids = Set((deal.checklistEvidence ?? [:]).values.flatMap { $0 } + (deal.authorizations ?? []).map(\.evidenceID))
        let evidence = database.evidence.filter { ids.contains($0.id) && $0.workspaceID == deal.workspaceID }.sorted { $0.id < $1.id }.map { value -> Evidence in var copy = value; copy.tags = nil; return copy }
        guard evidence.count == ids.count else { throw VideoError.review("品牌核验或授权的来源证据缺失，不能沿用原审批") }
        let assetIDs = Set(evidence.compactMap(\.assetID)); let assets = database.assets.filter { assetIDs.contains($0.id) && $0.workspaceID == deal.workspaceID }.sorted { $0.id < $1.id }.map { value -> Asset in var copy = value; copy.tags = []; copy.importedAt = nil; return copy }
        guard assets.count == assetIDs.count else { throw VideoError.review("品牌审批引用的原始凭证素材已缺失") }
        return try Codec.digest(TermsSnapshot(deal: contract, evidence: evidence, assets: assets))
    }
    public static func validateTerms(deal: BrandDeal, revision: Revision, database: Database, now: Date = Date()) throws {
        try deal.validate()
        guard revision.purpose == .brand, revision.workspaceID == deal.workspaceID, !deal.usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !deal.exclusivity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !deal.vertical.isEmpty, deal.expiresAt > now else { throw VideoError.review("品牌用途、排他条款、垂类或授权期未明确/已到期，须重新核对后商业交付") }
        guard let template = deal.checklistTemplate else { throw VideoError.review("请先保存本商单的明确垂类清单与逐项证据") }; try template.validate()
        func source(_ id: String, maximumAgeDays: Int? = nil) -> Bool {
            database.evidence.contains { value in value.id == id && value.workspaceID == deal.workspaceID && value.usable(commercial: true, now: now) && value.checkedAt <= now && (maximumAgeDays == nil || value.checkedAt.addingTimeInterval(Double(maximumAgeDays!) * 86400) > now) }
        }
        for item in template.requirements {
            guard deal.checklist[item.label] == true else { throw VideoError.review("品牌垂类核验未完成：\(item.label)") }
            if item.evidenceRequired { let ids = deal.checklistEvidence?[item.id] ?? []; guard !ids.isEmpty, ids.allSatisfy({ source($0, maximumAgeDays: item.maximumAgeDays) }) else { throw VideoError.review("品牌垂类事实缺少当前有效证据：\(item.label)") } }
        }
        let authorizations = deal.authorizations ?? []
        for authorization in authorizations {
            guard !authorization.usage.isEmpty, authorization.from <= now, authorization.until >= deal.expiresAt, source(authorization.evidenceID) else { throw VideoError.review("素材/声音/投广授权未覆盖约定用途或完整使用期，请补授权或缩短商单期限") }
        }
        var required: Set<AuthorizationScope> = []
        if revision.scenes.contains(where: { $0.assetID != nil || $0.characterProfile?.original == false || ($0.layers ?? []).contains(where: { $0.assetID != nil }) }) { required.insert(.material) }
        if revision.musicAssetID != nil || revision.scenes.contains(where: { $0.voice != nil || ($0.kind == .video && $0.sourceGain > 0) }) { required.insert(.voice) }
        if deal.settlements.contains(.distribution) { required.insert(.distribution) }
        if deal.settlements.contains(.adShare) || deal.usage.contains("投广") { required.insert(.advertising) }
        guard required.isSubset(of: Set(authorizations.map(\.scope))) else { throw VideoError.review("品牌素材、声音、分发或投广的专门授权尚未完整关联") }
        _ = try termsDigest(deal: deal, database: database)
    }
    public static func inspect(revision: Revision, database: Database, now: Date = Date()) -> [QualityIssue] {
        guard revision.purpose == .brand else { return [] }
        let projects = database.projects.filter { $0.workspaceID == revision.workspaceID && $0.revisions.contains(where: { $0.id == revision.id }) }
        guard projects.count == 1, let project = projects.first else { return [QualityIssue("brand_project", "品牌成片尚未绑定唯一的本工作区工程，不能标商业交付")] }
        let deals = database.brandDeals.filter { $0.workspaceID == project.workspaceID && $0.projectID == project.id }
        guard deals.count == 1, let deal = deals.first else { return [QualityIssue("brand_deal", "请在商单交付页明确绑定唯一Brief和品牌审稿版；作者看听不代替品牌审批")] }
        do {
            try validateTerms(deal: deal, revision: revision, database: database, now: now)
            let digest = try revision.contentDigest(); let terms = try termsDigest(deal: deal, database: database)
            guard deal.approvedRevisionID == revision.id, let approval = (deal.approvals ?? []).last(where: { $0.revisionID == revision.id && $0.digest == digest && $0.termsDigest == terms }), !approval.reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, approval.at <= now else { return [QualityIssue("brand_approval", "本版本或商单用途/排他/证据/授权/修改范围未获匹配的品牌审批；可先制作待审预览，重新送审后再交付")] }
            return []
        } catch { return [QualityIssue("brand_terms", (error as? VideoError)?.localizedDescription ?? "品牌交付核验失败，保留原工程和历史备份")] }
    }
}

public enum CommercialAccounting {
    private static func receiptKey(_ entry: CashEntry) -> String { entry.workspaceID + "|" + entry.kind.rawValue + "|" + entry.receipt.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Canonical records are authoritative. Legacy/manual rows with the same receipt are evidence copies,
    /// not additional income; mismatching amounts are explicitly rejected rather than guessed.
    public static func reconciledCash(database: Database, workspaceID: String) throws -> [CashEntry] {
        let sales = database.toolSales.filter { $0.workspaceID == workspaceID }; let deals = database.brandDeals.filter { $0.workspaceID == workspaceID }
        guard Set(sales.map(\.id)).count == sales.count, Set(deals.map(\.id)).count == deals.count else { throw VideoError.invalid("工具订单或商单ID重复，不能汇总现金") }
        var canonical: [CashEntry] = []; var owners: [String: String] = [:]
        func append(_ entry: CashEntry, owner: String) throws {
            let key = receiptKey(entry); if let prior = owners[key], prior != owner { throw VideoError.conflict("同一实际结算凭证关联了多个工具订单或商单，请先核对") }; owners[key] = owner; canonical.append(entry)
        }
        for sale in database.toolSales where sale.workspaceID == workspaceID {
            try sale.validate(); guard let paid = sale.paid, let paidAt = sale.paidAt, !sale.receipt.isEmpty else { continue }
            try append(CashEntry(id: "tool-" + sale.id, workspaceID: workspaceID, kind: .tool, label: sale.plan, received: paid, refunded: sale.refunded, at: paidAt, receipt: sale.receipt), owner: "tool-" + sale.id)
        }
        for deal in database.brandDeals where deal.workspaceID == workspaceID {
            try deal.validate()
            if let records = deal.settlementRecords, !records.isEmpty {
                for record in records { try append(CashEntry(id: "brand-" + deal.id + "-" + record.id, workspaceID: workspaceID, kind: .brand, label: deal.client + " · " + record.kind.rawValue, received: record.received, refunded: record.refunded, at: record.at, receipt: record.receipt), owner: "brand-" + deal.id) }
                if let legacy = deal.legacyCash {
                    let allocated = records.filter { $0.receipt == legacy.receipt }; let amount = allocated.reduce(Decimal(0)) { $0 + $1.received.amount }; let refunded = allocated.reduce(Decimal(0)) { $0 + $1.refunded }
                    guard amount <= legacy.received.amount, amount < legacy.received.amount || refunded >= legacy.refunded else { throw VideoError.conflict("历史商单分账超过原凭证或漏掉已知退款，请先核对") }
                    if amount < legacy.received.amount { try append(CashEntry(id: "brand-" + deal.id + "-unallocated", workspaceID: workspaceID, kind: .brand, label: deal.client + " · 历史待分账", received: Money(legacy.received.amount - amount, legacy.received.currency), refunded: max(0, legacy.refunded - refunded), at: legacy.at, receipt: legacy.receipt), owner: "brand-" + deal.id) }
                }
            } else if let received = deal.received, !deal.receipt.isEmpty {
                // Older records have no paid-at field. Keep the original cash date; never invent today's receipt.
                if let legacy = database.cash.first(where: { $0.workspaceID == workspaceID && $0.id == "brand-" + deal.id }) { try append(legacy, owner: "brand-" + deal.id) }
                else { throw VideoError.review("旧商单有回款金额但无实际到账日期，请补录分账结算凭证") }
                _ = received
            }
        }
        let groups = Dictionary(grouping: canonical, by: receiptKey)
        let raw = database.cash.filter { $0.workspaceID == workspaceID }; var output: [CashEntry] = []
        for entry in raw {
            guard !entry.assumption, !entry.noncash, let linked = groups[receiptKey(entry)] else { output.append(entry); continue }
            if canonical.contains(where: { $0.id == entry.id && $0.received == entry.received && $0.refunded == entry.refunded }) { continue }
            let sum = linked.reduce(Decimal(0)) { $0 + $1.received.amount }; let refund = linked.reduce(Decimal(0)) { $0 + $1.refunded }
            guard linked.allSatisfy({ $0.received.currency == entry.received.currency }), sum == entry.received.amount, refund == entry.refunded else { throw VideoError.conflict("工具/商单凭证与手工现金记录金额冲突，请核对后再出净收结论") }
        }
        output += canonical
        let actual = output.filter { !$0.assumption && !$0.noncash && !$0.receipt.isEmpty && $0.kind != .course }
        for group in Dictionary(grouping: actual, by: receiptKey).values where group.count > 1 {
            // Multiple explicitly split payments of the same brand deal are allowed. Unlinked duplicate manual rows are not.
            guard group.allSatisfy({ entry in canonical.contains(where: { $0.id == entry.id }) }) else { throw VideoError.conflict("手工现金记录存在重复凭证，不能重复计收入") }
        }
        return output
    }
    public static func report(database db: Database, workspaceID: String, currency: String = "CNY", start: Date, now: Date = Date()) throws -> CommercialReport {
        guard start <= now else { throw VideoError.invalid("商业观察窗口起点不能晚于终点") }
        _ = try reconciledCash(database: db, workspaceID: workspaceID)
        let sales = db.toolSales.filter { $0.workspaceID == workspaceID }; let inWindow = sales.filter { $0.paid?.currency == currency && $0.paidAt != nil && $0.paidAt! >= start && $0.paidAt! <= now && !$0.receipt.isEmpty }
        let paid = sales.filter { $0.paid != nil && $0.paid!.amount > 0 && $0.paidAt != nil && $0.paidAt! <= now && !$0.receipt.isEmpty }
        let active = paid.filter { $0.active(at: now) }; let activeSubscriptions = active.filter(\.subscription)
        let opening = Set(paid.filter { $0.subscription && $0.active(at: start) }.map(\.buyerReference)); let closing = Set(activeSubscriptions.map(\.buyerReference)); let churned = opening.subtracting(closing)
        var brandTotals: [String: Decimal] = [:]; var warnings: [String] = []
        for deal in db.brandDeals where deal.workspaceID == workspaceID {
            if let records = deal.settlementRecords { for record in records where record.received.currency == currency && record.at >= start && record.at <= now { brandTotals[record.kind.rawValue, default: 0] += record.received.amount - record.refunded }; if let legacy = deal.legacyCash, records.filter({ $0.receipt == legacy.receipt }).reduce(Decimal(0), { $0 + $1.received.amount }) < legacy.received.amount { warnings.append("\(deal.client)：历史回款仍有未拆分余额，现金保留但不假定结算类型") } }
            else if deal.received != nil { warnings.append("\(deal.client)：历史汇总回款尚未拆分结算类型，不能冒充已分账") }
        }
        var funnel: [FunnelCount] = []
        let events = db.funnel.filter { $0.workspaceID == workspaceID && $0.at >= start && $0.at <= now }
        for stage in FunnelStage.allCases { let matched = events.filter { $0.stage == stage.rawValue }; funnel.append(FunnelCount(stage: stage.rawValue, subjects: Set(matched.map(\.subject)).count, events: matched.count)) }
        var hours: [String: Decimal] = [:]; var costs: [String: Decimal] = [:]; var unknown = 0
        for support in (db.supportRecords ?? []).filter({ $0.workspaceID == workspaceID && $0.at >= start && $0.at <= now }) { try support.validate(); hours[support.audience.rawValue, default: 0] += support.hours; if let cost = support.cost { if cost.currency == currency { costs[support.audience.rawValue, default: 0] += cost.amount } } else { unknown += 1 } }
        if events.contains(where: { FunnelStage(rawValue: $0.stage) == nil }) { warnings.append("存在旧版未映射漏斗事件，保留原记录但不计入新口径") }
        if sales.contains(where: { $0.subscription && $0.paid != nil && $0.expiresAt == nil }) { warnings.append("有订阅缺少权益截止时间，不计付费活跃") }
        return CommercialReport(currency: currency, actualToolNet: inWindow.reduce(0) { $0 + $1.paid!.amount - $1.refunded }, actualBrandBySettlement: brandTotals, paidCustomers: Set(paid.map(\.buyerReference)).count, activePaidCustomers: Set(active.map(\.buyerReference)).count, activeSubscriptions: Set(activeSubscriptions.map(\.buyerReference)).count, expiredSubscriptions: paid.filter { $0.subscription && $0.expiresAt != nil && $0.expiresAt! <= now && !closing.contains($0.buyerReference) }.count, terminatedSubscriptions: paid.filter { $0.subscription && $0.cancelled }.count, refundedSales: paid.filter { $0.refunded > 0 }.count, renewedCustomers: Set(paid.filter { $0.renewalOf != nil }.map(\.buyerReference)).count, openingSubscriptionCustomers: opening.count, churnedSubscriptionCustomers: churned.count, observedChurnRate: opening.isEmpty ? nil : Decimal(churned.count) / Decimal(opening.count), funnel: funnel, supportHoursByAudience: hours, supportCostByAudience: costs, unknownSupportCosts: unknown, warnings: warnings)
    }
}

public extension Database {
    mutating func recordToolSale(_ requested: ToolSale) throws {
        var sale = requested; try sale.validate(); guard !sale.buyerReference.isEmpty, !sale.plan.isEmpty else { throw VideoError.invalid("请填写去标识客户引用和工具方案") }
        _ = try workspace(sale.workspaceID)
        if let old = toolSales.first(where: { $0.workspaceID == sale.workspaceID && ($0.id == sale.id || (!sale.receipt.isEmpty && $0.receipt == sale.receipt) || (sale.orderReference != nil && $0.orderReference == sale.orderReference)) }) { guard old.paid == nil || sale.paid != nil else { throw VideoError.conflict("真实付款历史不能改回询盘，请登记退款或终止权益") }; sale.id = old.id }
        if sale.subscription && sale.paid != nil { guard sale.expiresAt != nil else { throw VideoError.invalid("实际订阅须明确本次已付款权益截止，不能无限有效") } }
        if let priorID = sale.renewalOf { guard let prior = toolSales.first(where: { $0.id == priorID && $0.workspaceID == sale.workspaceID && $0.buyerReference == sale.buyerReference }), prior.paid != nil, prior.id != sale.id else { throw VideoError.invalid("续费须引用同工作区同客户的真实原订单") } }
        toolSales.removeAll { $0.id == sale.id }; toolSales.append(sale)
        if let paid = sale.paid, let at = sale.paidAt { cash.removeAll { $0.id == "tool-" + sale.id }; cash.append(CashEntry(id: "tool-" + sale.id, workspaceID: sale.workspaceID, kind: .tool, label: sale.plan, received: paid, refunded: sale.refunded, at: at, receipt: sale.receipt)) }
        _ = try CommercialAccounting.reconciledCash(database: self, workspaceID: sale.workspaceID)
    }
    mutating func recordBrandDeal(_ requested: BrandDeal) throws {
        var deal = requested; try deal.validate(); _ = try workspace(deal.workspaceID)
        if let old = brandDeals.first(where: { $0.id == deal.id }) {
            guard old.workspaceID == deal.workspaceID else { throw VideoError.permission("商单不能移入其他工作区") }
            let before = try? BrandDeliveryRules.termsDigest(deal: old, database: self); let after = try? BrandDeliveryRules.termsDigest(deal: deal, database: self)
            if before == nil || after == nil || before != after { deal.approvedRevisionID = nil }
        }
        if let projectID = deal.projectID { guard projects.contains(where: { $0.id == projectID && $0.workspaceID == deal.workspaceID && $0.current.purpose == .brand }), !brandDeals.contains(where: { $0.id != deal.id && $0.workspaceID == deal.workspaceID && $0.projectID == projectID }) else { throw VideoError.conflict("商单关联品牌项目缺失、跨工作区或已绑定其他客户Brief") } }
        brandDeals.removeAll { $0.id == deal.id }; brandDeals.append(deal)
    }
    mutating func bindBrandProject(dealID: String, projectID: String, reason: String) throws {
        guard let index = brandDeals.firstIndex(where: { $0.id == dealID }), !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VideoError.invalid("请选择商单并记录此次绑定的原因") }
        let project = try self.project(projectID); var deal = brandDeals[index]
        guard project.workspaceID == deal.workspaceID, project.current.purpose == .brand else { throw VideoError.permission("只能关联同工作区、商业目的为品牌合作的工程") }
        guard !brandDeals.contains(where: { $0.id != dealID && $0.workspaceID == deal.workspaceID && $0.projectID == projectID }) else { throw VideoError.conflict("该品牌工程已绑定其他Brief，须先明确交付客户边界") }
        deal.projectID = project.id; deal.approvedRevisionID = nil; var notes = deal.revisionNotes ?? []; notes.append("明确关联工程：\(project.name)；\(reason)"); deal.revisionNotes = notes; brandDeals[index] = deal
    }
    mutating func recordBrandSettlement(dealID: String, settlement: BrandSettlement) throws {
        guard let index = brandDeals.firstIndex(where: { $0.id == dealID }) else { throw VideoError.notFound("商单不存在") }; try settlement.validate(); var deal = brandDeals[index]; var stored = settlement
        if deal.settlementRecords == nil, deal.received != nil { deal.legacyCash = cash.first(where: { $0.id == "brand-" + dealID && $0.workspaceID == deal.workspaceID }); guard deal.legacyCash != nil else { throw VideoError.review("历史商单缺原到账日期，请先核对原结算凭证") } }
        var records = deal.settlementRecords ?? []; if let old = records.first(where: { $0.receipt == stored.receipt && $0.kind == stored.kind }) { stored.id = old.id }; records.removeAll { $0.id == stored.id }; records.append(stored); deal.settlementRecords = records; var gross = records.reduce(Decimal(0)) { $0 + $1.received.amount }; if let legacy = deal.legacyCash { gross += max(0, legacy.received.amount - records.filter({ $0.receipt == legacy.receipt }).reduce(Decimal(0), { $0 + $1.received.amount })) }; deal.received = Money(gross, deal.quote.currency); deal.receipt = records.map(\.receipt).joined(separator: "；"); try deal.validate(); brandDeals[index] = deal
        cash.removeAll { $0.id == "brand-" + dealID || $0.id.hasPrefix("brand-" + dealID + "-") }
        for record in records { cash.append(CashEntry(id: "brand-" + dealID + "-" + record.id, workspaceID: deal.workspaceID, kind: .brand, label: deal.client + " · " + record.kind.rawValue, received: record.received, refunded: record.refunded, at: record.at, receipt: record.receipt)) }
        _ = try CommercialAccounting.reconciledCash(database: self, workspaceID: deal.workspaceID)
    }
    mutating func approveBrand(dealID: String, projectID: String, revisionID: String? = nil, reviewer: String, note: String, now: Date = Date()) throws {
        guard let index = brandDeals.firstIndex(where: { $0.id == dealID }) else { throw VideoError.notFound("商单不存在") }; var deal = brandDeals[index]; let project = try self.project(projectID)
        guard let revisionID, project.current.id == revisionID else { throw VideoError.conflict("请从商单交付页明确选择实际审稿版；版本变化后须重新查看再审批") }
        guard project.workspaceID == deal.workspaceID, deal.projectID == projectID, !reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, deal.expiresAt > now else { throw VideoError.permission("品牌审稿须先明确关联同工作区工程、当前授权和品牌审核者") }
        let issues = try Quality.inspect(project.current, database: self, requireReview: true, now: now, enforceBrandDelivery: false); guard issues.isEmpty else { throw VideoError.review(issues.map(\.message).joined(separator: "\n")) }
        guard jobs.contains(where: { $0.workspaceID == project.workspaceID && $0.projectID == project.id && $0.revisionID == revisionID && $0.state == .succeeded && $0.digest == (try? project.current.contentDigest()) && $0.artifacts.count == 4 }) else { throw VideoError.review("指定审稿版尚无完整看听确认后的实际制作产物") }
        if let previous = (deal.approvals ?? []).last(where: { $0.termsDigest != nil }), previous.revisionID != revisionID, deal.revisionsUsed <= (previous.revisionsUsed ?? deal.revisionsUsed) {
            guard deal.revisionsUsed < deal.revisionsAllowed else { throw VideoError.budget("新品牌审稿版本已超过约定修改次数，请先明确新增范围") }; deal.revisionsUsed += 1
        }
        try BrandDeliveryRules.validateTerms(deal: deal, revision: project.current, database: self, now: now)
        deal.approvedRevisionID = revisionID; var approvals = deal.approvals ?? []; approvals.append(BrandApproval(revisionID: revisionID, digest: try project.current.contentDigest(), reviewer: reviewer, at: now, note: note, termsDigest: try BrandDeliveryRules.termsDigest(deal: deal, database: self), revisionsUsed: deal.revisionsUsed)); deal.approvals = approvals; brandDeals[index] = deal
    }
    mutating func recordBrandRevision(dealID: String, reason: String) throws {
        guard let index = brandDeals.firstIndex(where: { $0.id == dealID }), !reason.isEmpty else { throw VideoError.invalid("请填写商单修改原因") }; guard brandDeals[index].revisionsUsed < brandDeals[index].revisionsAllowed else { throw VideoError.budget("已达到约定修改次数，须先与客户明确新增范围") }; brandDeals[index].revisionsUsed += 1; brandDeals[index].approvedRevisionID = nil; var notes = brandDeals[index].revisionNotes ?? []; notes.append(reason); brandDeals[index].revisionNotes = notes
    }
    mutating func recordSupport(_ requested: SupportRecord) throws {
        var record = requested; try record.validate(); _ = try workspace(record.workspaceID); var records = supportRecords ?? []
        if let old = records.first(where: { $0.workspaceID == record.workspaceID && $0.reference == record.reference }) { record.id = old.id }
        records.removeAll { $0.id == record.id }; records.append(record); supportRecords = records
        let id = "support-" + record.id; expenses.removeAll { $0.id == id }; expenses.append(Expense(id: id, workspaceID: record.workspaceID, label: record.audience.rawValue + "支持：" + record.topic, money: record.cost, hours: record.hours, at: record.at))
    }
    mutating func recordFunnel(_ event: FunnelEvent) throws {
        _ = try workspace(event.workspaceID); guard let stage = FunnelStage(rawValue: event.stage), !event.subject.isEmpty, let reference = event.evidenceReference, !reference.isEmpty else { throw VideoError.invalid("漏斗事件须填写去标识主体、标准阶段与实际来源凭据") }
        switch stage {
        case .firstOutput, .repeatOutput:
            guard let job = jobs.first(where: { $0.id == reference && $0.workspaceID == event.workspaceID && [.succeeded, .needsReview].contains($0.state) && $0.artifacts.count >= 4 }), let project = projects.first(where: { $0.id == job.projectID && $0.workspaceID == event.workspaceID }), let revision = project.revisions.first(where: { $0.id == job.revisionID }), revision.review.complete, revision.review.digest == (try revision.contentDigest()), job.digest == (try revision.contentDigest()) else { throw VideoError.review("有效成片事件须引用已通过当前版本人工审核、摘要一致并有完整产物的真实任务") }
            if stage == .firstOutput, funnel.contains(where: { $0.workspaceID == event.workspaceID && $0.subject == event.subject && $0.stage == stage.rawValue && $0.evidenceReference != reference }) { throw VideoError.conflict("该主体已记录首次成片，后续产物请使用重复成片阶段") }
            if stage == .repeatOutput { guard funnel.contains(where: { $0.workspaceID == event.workspaceID && $0.subject == event.subject && $0.stage == FunnelStage.firstOutput.rawValue && $0.evidenceReference != reference }) else { throw VideoError.review("请先记录同主体的首次有效成片，重复成片须引用另一个真实任务") } }
        case .paid, .refund, .renewal:
            guard let sale = toolSales.first(where: { $0.id == reference && $0.workspaceID == event.workspaceID && $0.buyerReference == event.subject }), sale.paid != nil, sale.paidAt != nil, sale.paidAt! <= event.at, !sale.receipt.isEmpty, stage != .refund || sale.refunded > 0, stage != .renewal || sale.renewalOf != nil else { throw VideoError.review("付款/退款/续费事件须引用同主体对应的真实工具订单") }
        case .free, .installed, .premiumTrial: break
        }
        let key = try Codec.digest([event.workspaceID, event.subject, event.stage, reference]); var stored = event; stored.id = key
        if let existing = funnel.first(where: { $0.id == key }) { guard existing.at == event.at || existing.evidenceReference == event.evidenceReference else { throw VideoError.conflict("漏斗事件已存在") }; return }; funnel.append(stored)
    }
}
