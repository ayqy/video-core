import Foundation

public enum TopicBatchState: String, Codable, Sendable {
    case planned = "待编排", ready = "待制作", running = "制作中", needsReview = "待看听", approved = "已审核", failed = "单项失败", invalidated = "本项待复核", waiting = "远端/费用待核", cancelled = "已取消·费用另核"
}
public struct TopicBatchItem: Codable, Identifiable, Sendable {
    public var id: String { topic.id }; public var topic: Topic; public var productSnapshot: Product?; public var budget: Money; public var projectID: String?; public var revisionID: String?; public var state: TopicBatchState; public var error: String?; public var quote: Quote?; public var createdAt: Date; public var updatedAt: Date; public var history: [TopicBatchHistory]?
}
public struct TopicBatchHistory: Codable, Sendable { public var product: Product?; public var revisionID: String?; public var quote: Quote?; public var at: Date; public var reason: String }
public struct TopicBatch: Codable, Identifiable, Sendable {
    public var tags: [String]?
    public var id = Codec.id(); public var workspaceID: String; public var title: String; public var items: [TopicBatchItem]; public var createdAt: Date
    public var maximumByCurrency: [String: Decimal] { items.reduce(into: [:]) { $0[$1.budget.currency, default: 0] += $1.budget.amount } }
}
public enum BatchRules {
    public static func create(workspaceID: String, title: String, topics: [Topic], products: [Product], now: Date = Date()) throws -> TopicBatch {
        guard !workspaceID.isEmpty, !title.isEmpty, !topics.isEmpty, topics.count <= 25, Set(topics.map(\.id)).count == topics.count else { throw VideoError.invalid("批次须有名称和1至25个不同选题，不能无限批量生成") }
        var batch = TopicBatch(workspaceID: workspaceID, title: title, items: [], createdAt: now)
        for topic in topics {
            var frozen = topic; frozen.batchID = batch.id; frozen.workspaceID = workspaceID; let product = products.first { $0.id == topic.productID && $0.workspaceID == workspaceID }
            var error: String?
            if topic.workspaceID != workspaceID || product == nil { error = "本项产品缺失或不属于当前工作区" }
            else if [frozen.hook, frozen.knowledge, frozen.proof, frozen.audience, frozen.task, frozen.outcome, frozen.cta, frozen.channel].contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { error = "本项知识、演示、受众任务、成果、CTA或渠道未完整填写" }
            else if frozen.budget.amount < 0 { error = "本项现金上界必须非负" }
            else { do { try product!.validate() } catch let failure { error = failure.localizedDescription } }
            batch.items.append(TopicBatchItem(topic: frozen, productSnapshot: product, budget: topic.budget, state: error == nil ? .planned : .failed, error: error, createdAt: now, updatedAt: now))
        }
        return batch
    }
    public static func refreshed(_ batch: TopicBatch, database: Database, now: Date = Date()) -> TopicBatch {
        var result = batch
        for index in result.items.indices {
            var item = result.items[index]
            guard item.state != .failed || item.projectID != nil else { continue }
            guard let snapshot = item.productSnapshot, let product = database.products.first(where: { $0.id == snapshot.id && $0.workspaceID == batch.workspaceID && !$0.archived }), product.hasSameFacts(as:snapshot) else { item.state = .invalidated; item.error = "本项产品、价格或课程映射已变化；其他SKU的项目和预算保持独立"; result.items[index] = item; continue }
            if let projectID = item.projectID {
                guard let project = database.projects.first(where: { $0.id == projectID && $0.workspaceID == batch.workspaceID }), let revision = project.revisions.first(where: { $0.id == item.revisionID }), project.current.id == revision.id else { item.state = .invalidated; item.error = "本项项目版本已变化，请在批次中明确接收新版本"; result.items[index] = item; continue }
                let changes = DependencyRules.diff(revision: revision, assets: database.assets, evidence: database.evidence, currentProduct: product, now: now)
                if !changes.isEmpty { item.state = .invalidated; item.error = changes.map(\.summary).joined(separator: "；") }
                else if let job = database.jobs.last(where: { $0.projectID == projectID && $0.revisionID == revision.id }) {
                    switch job.state {
                    case .queued, .running: item.state = .running; item.error = nil
                    case .failed, .interrupted: item.state = .failed; item.error = job.message.isEmpty ? job.state.label : job.message
                    case .unknownRemote, .billingPending, .cancelRequested: item.state = .waiting; item.error = job.message.isEmpty ? job.state.label : job.message
                    case .cancelled: item.state = .cancelled; item.error = job.message.isEmpty ? job.state.label : job.message
                    case .needsReview: item.state = .needsReview; item.error = nil
                    case .succeeded: item.state = revision.review.complete && revision.review.digest == (try? revision.contentDigest()) ? .approved : .needsReview; item.error = nil
                    }
                } else { item.state = .ready; item.error = nil }
            }
            result.items[index] = item
        }
        return result
    }
    public static func validateSubmission(project: Project, quote: Quote, batches: [TopicBatch], existingJobs: [Job] = [], requestKey: String? = nil) throws {
        guard let batchID = project.batchID else { return }
        guard let batch = batches.first(where: { $0.id == batchID && $0.workspaceID == project.workspaceID }), let item = batch.items.first(where: { $0.projectID == project.id }), let product = item.productSnapshot, product.hasSameFacts(as:project.current.product), item.revisionID == project.current.id, item.topic.audience == project.current.product.audience || item.topic.audience == product.audience else { throw VideoError.review("批次产品/受众或绑定版本已变，需在本项重新确认，不能沿用旧预算提交") }
        guard quote.projectID == project.id, quote.revisionID == project.current.id, quote.digest == (try project.current.contentDigest()), quote.upper.currency == item.budget.currency else { throw VideoError.review("报价与本项冻结版本或币种不一致") }
        if let requestKey, existingJobs.contains(where: { $0.projectID == project.id && $0.requestKey == requestKey && $0.quote.id == quote.id && $0.digest == quote.digest }) { return }
        let exposure = existingJobs.filter { $0.projectID == project.id && $0.quote.upper.currency == item.budget.currency }.reduce(Decimal(0)) { $0 + $1.exposure.amount }
        guard quote.upper.amount >= 0, exposure + quote.upper.amount <= item.budget.amount else { throw VideoError.budget("本项累计已花费/占用加本次上界超过冻结预算；失败/取消不抹掉已花费") }
    }
}
public extension Database {
    mutating func recordTopicBatch(_ requested: TopicBatch) throws {
        _ = try workspace(requested.workspaceID); guard !requested.items.isEmpty, requested.items.allSatisfy({ $0.topic.batchID == requested.id && $0.topic.workspaceID == requested.workspaceID }) else { throw VideoError.invalid("批次条目归属不一致") }
        var batches = topicBatches ?? []; guard !batches.contains(where: { $0.id == requested.id }) else { throw VideoError.conflict("批次已存在，不能覆写已冻结条目") }; batches.append(requested); topicBatches = batches
        for item in requested.items { topics.removeAll { $0.id == item.topic.id }; topics.append(item.topic) }
    }
    mutating func storeBatchNarrative(_ input: NarrativeDocument, batchID: String, itemID: String, now: Date = Date()) throws {
        var batches = topicBatches ?? []; guard let batchIndex = batches.firstIndex(where: { $0.id == batchID && $0.workspaceID == input.workspaceID }), let itemIndex = batches[batchIndex].items.firstIndex(where: { $0.id == itemID }) else { throw VideoError.notFound("选题批次或条目已缺失") }
        var item = batches[batchIndex].items[itemIndex]; var document = input
        guard item.productSnapshot?.hasSameFacts(as:document.revision.product) == true, document.input.topic.productID == item.topic.productID, document.input.topic.audience == item.topic.audience, document.input.topic.budget.currency == item.budget.currency, document.input.topic.budget.amount <= item.budget.amount else { throw VideoError.review("本项产品、受众或预算已改变，请新建对照条件，不能混进旧批次") }
        guard item.projectID == nil else { throw VideoError.conflict("该条目已生成项目，请在原项目局部编辑或明确接收其新版本，避免重复制作") }
        let issues = DependencyRules.diff(revision: document.revision, assets: assets, evidence: evidence, currentProduct: products.first { $0.id == item.topic.productID }, now: now)
        guard issues.isEmpty else { throw VideoError.review(issues.map(\.summary).joined(separator: "\n")) }
        document.input.topic.id = item.id; document.input.topic.batchID = batchID
        var project = Project(workspaceID: document.workspaceID, name: document.input.topic.hook, revision: document.revision); project.series = document.series?.name ?? document.input.topic.series; project.batchID = batchID
        item.topic = document.input.topic; item.budget = document.input.topic.budget; item.projectID = project.id; item.revisionID = project.current.id; item.state = .ready; item.error = nil; item.updatedAt = now; batches[batchIndex].items[itemIndex] = item; topicBatches = batches
        projects.append(project); narrativeDocuments = (narrativeDocuments ?? []) + [document]
        var styles = styleKits ?? []; styles.removeAll { $0.id == document.style.id }; styles.append(document.style); styleKits = styles
        var templates = narrativeTemplates ?? []; templates.removeAll { $0.id == document.template.id }; templates.append(document.template); narrativeTemplates = templates
        if let series = document.series { var saved = seriesProfiles ?? []; saved.removeAll { $0.id == series.id }; saved.append(series); seriesProfiles = saved }
        if let topic = topics.firstIndex(where: { $0.id == itemID }) { topics[topic] = document.input.topic }
    }
    mutating func acceptBatchRevision(batchID: String, itemID: String, now: Date = Date()) throws {
        var batches = topicBatches ?? []; guard let batch = batches.firstIndex(where: { $0.id == batchID }), let index = batches[batch].items.firstIndex(where: { $0.id == itemID }), let projectID = batches[batch].items[index].projectID else { throw VideoError.notFound("批次项目缺失") }
        let project = try self.project(projectID); guard project.workspaceID == batches[batch].workspaceID else { throw VideoError.permission("项目不属于当前批次工作区") }; let changes = DependencyRules.diff(revision: project.current, assets: assets, evidence: evidence, currentProduct: products.first { $0.id == project.current.product.id }, now: now); guard changes.isEmpty else { throw VideoError.review(changes.map(\.summary).joined(separator: "\n")) }
        guard batches[batch].items[index].topic.audience == project.current.product.audience else { throw VideoError.review("受众变化须建立新的对照条件，不能混进原批次") }
        let old = batches[batch].items[index]; var history = old.history ?? []; history.append(TopicBatchHistory(product: old.productSnapshot, revisionID: old.revisionID, quote: old.quote, at: now, reason: "用户明确接收当前项目版本；原预算保持")); batches[batch].items[index].history = history
        batches[batch].items[index].productSnapshot = project.current.product; batches[batch].items[index].revisionID = project.current.id; batches[batch].items[index].quote = nil; batches[batch].items[index].state = .ready; batches[batch].items[index].updatedAt = now; batches[batch].items[index].error = "已接收新版本，原预算不增加，须重新报价和看听审核"; topicBatches = batches
    }
}
