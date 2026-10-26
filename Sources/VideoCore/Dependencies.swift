import Foundation

/// One learning outcome points to a bounded part of an existing course, never a generated course.
public struct CourseMapping: Codable, Identifiable, Equatable, Sendable {
    public enum RangeKind: String, Codable, CaseIterable, Sendable { case pages = "页范围", time = "时间片段", whole = "完整素材" }
    public var id = Codec.id()
    public var title: String
    public var knowledge: String
    public var audience: String
    public var task: String
    public var outcome: String
    public var prerequisite: String
    public var assetID: String
    public var rangeKind: RangeKind
    public var start: Int
    public var end: Int
    public var evidenceIDs: [String]
    public var confirmed: Bool
    public init(title: String, knowledge: String, audience: String, task: String, outcome: String, prerequisite: String, assetID: String, rangeKind: RangeKind, start: Int = 0, end: Int = 0, evidenceIDs: [String] = [], confirmed: Bool = false) {
        self.title = title; self.knowledge = knowledge; self.audience = audience; self.task = task; self.outcome = outcome; self.prerequisite = prerequisite; self.assetID = assetID; self.rangeKind = rangeKind; self.start = start; self.end = end; self.evidenceIDs = evidenceIDs; self.confirmed = confirmed
    }
    public var rangeDescription: String {
        switch rangeKind { case .pages: return "第\(start)–\(end)页"; case .time: return String(format: "%.2f–%.2f秒", Double(start)/30, Double(end)/30); case .whole: return "完整素材" }
    }
    public func validate(workspaceID: String, assets: [Asset], evidence: [Evidence]) throws {
        guard [title, knowledge, audience, task, outcome, prerequisite].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw VideoError.invalid("课程片段须填写知识点、受众、任务、成果及前置条件（没有也请明确）") }
        guard let asset = assets.first(where: { $0.id == assetID && $0.workspaceID == workspaceID }) else { throw VideoError.permission("课程片段素材不属于当前工作区或已缺失") }
        switch rangeKind {
        case .pages:
            guard start >= 1, end >= start, end-start < 200, (start...end).allSatisfy({ n in asset.pages.contains(where: { $0.number == n }) }) else { throw VideoError.invalid("课程页范围超出已导入页面") }
            if confirmed { guard asset.pages.filter({ (start...end).contains($0.number) }).allSatisfy({ $0.confirmed && !$0.requiresOCR && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw VideoError.review("请先对照原件校对所选页面，再确认课程映射") } }
        case .time:
            guard let frames = asset.durationFrames, start >= 0, end > start, end <= frames else { throw VideoError.invalid("课程时间片段超出源媒体实际时长") }
        case .whole:
            guard start == 0, end == 0 else { throw VideoError.invalid("完整素材不应携带隐藏的裁切范围") }
            if confirmed && !asset.pages.isEmpty { guard asset.pages.allSatisfy({ $0.confirmed && !$0.requiresOCR && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw VideoError.review("完整文档仍有未校对页，请缩小页范围或先完成校对") } }
        }
        guard Set(evidenceIDs).count == evidenceIDs.count else { throw VideoError.invalid("课程映射证据重复") }
        for id in evidenceIDs { guard evidence.contains(where: { $0.id == id && $0.workspaceID == workspaceID }) else { throw VideoError.permission("课程映射证据不属于当前工作区或已缺失") } }
    }
    /// Applies only this selected source. Other scenes and locked sources remain untouched.
    public func applying(to scene: Scene, product: Product, assets: [Asset], evidence: [Evidence]) throws -> Scene {
        return try applying(to:scene,workspaceID:product.workspaceID,assets:assets,evidence:evidence)
    }
    public func applying(to scene:Scene,workspaceID:String,assets:[Asset],evidence:[Evidence])throws->Scene {
        guard !scene.locked else { throw VideoError.conflict("请先解锁该场景，再替换课程来源") }
        try validate(workspaceID: workspaceID, assets: assets, evidence: evidence)
        guard confirmed else { throw VideoError.review("课程片段尚未人工确认") }
        let asset = assets.first(where: { $0.id == assetID && $0.workspaceID == workspaceID })!
        var result = scene; result.courseMappingIDs = [id]; result.evidenceIDs = Array(Set(scene.evidenceIDs + evidenceIDs)).sorted()
        if asset.mediaType.hasPrefix("video") { result.kind = .video; result.assetID = asset.id; result.sourceStartFrame = rangeKind == .time ? start : 0; result.sourceEndFrame = rangeKind == .time ? end : asset.durationFrames; result.durationFrames = min(result.durationFrames, (rangeKind == .time ? end-start : asset.durationFrames) ?? result.durationFrames) }
        else if asset.mediaType.hasPrefix("image") { result.kind = .image; result.assetID = asset.id }
        else { result.assetID = nil; result.kind = .explanation; if rangeKind == .pages { result.body = asset.pages.filter { (start...end).contains($0.number) }.sorted { $0.number < $1.number }.map(\.text).joined(separator: "\n");result.narration=result.body } }
        return result
    }
}

public extension Database {
    /// The caller authorizes access before this transaction-local mutation. CLI imports
    /// replace the current record; editor windows additionally compare their saved digest.
    mutating func saveProductFacts(_ product: Product, workspaceID: String) throws {
        try storeProductFacts(product, workspaceID: workspaceID, checkPrevious: false, previousDigest: nil)
    }

    mutating func saveProductFacts(_ product: Product, workspaceID: String, previousDigest: String?) throws {
        try storeProductFacts(product, workspaceID: workspaceID, checkPrevious: true, previousDigest: previousDigest)
    }

    private mutating func storeProductFacts(_ product: Product, workspaceID: String, checkPrevious: Bool, previousDigest: String?) throws {
        _ = try workspace(workspaceID)
        guard product.workspaceID == workspaceID,
              !products.contains(where: { $0.id == product.id && $0.workspaceID != workspaceID }) else {
            throw VideoError.permission("既有事实ID不属于当前工作区")
        }
        try product.validate()
        try DependencyRules.validateMappings(product: product, assets: assets, evidence: evidence)
        guard !products.contains(where: { $0.workspaceID == workspaceID && $0.sku == product.sku && $0.id != product.id }) else {
            throw VideoError.conflict("已有同标识资料，请更新原事实ID")
        }
        guard let index = products.firstIndex(where: { $0.id == product.id && $0.workspaceID == workspaceID }) else {
            guard !checkPrevious || previousDigest == nil else { throw VideoError.conflict("原事实已移除") }
            products.append(product)
            return
        }
        let original = products[index]
        if checkPrevious {
            guard previousDigest == (try Codec.digest(original)) else { throw VideoError.conflict("既有事实已在其他窗口变化，请重新打开") }
        }
        guard original != product else { return }
        let factsChanged = !original.hasSameFacts(as: product)
        products[index] = product
        guard factsChanged else { return }
        for index in projects.indices where projects[index].workspaceID == workspaceID && projects[index].current.product?.id == product.id {
            projects[index] = Editor.updateFacts(product, project: projects[index])
            for publication in publications.indices where publications[publication].workspaceID == workspaceID && publications[publication].projectID == projects[index].id {
                publications[publication].stale = true
            }
        }
    }
}

public struct FrozenDependency: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case asset, evidence, mapping }
    public var id: String
    public var kind: Kind
    public var label: String
    public var digest: String
    public var sceneIDs: [String]
    public var asset: Asset?
    public var evidence: Evidence?
    public var mapping: CourseMapping?
    /// Nil means only file content is used; selected numbers bind corrected text exactly.
    public var pageNumbers: [Int]?
}
public struct DependencySnapshot: Codable, Sendable {
    public var version: Int = 1
    public var workspaceID: String
    public var productID: String?
    public var contentContextID: String?
    public var records: [FrozenDependency]
    public var capturedAt: Date
}
public struct DependencyChange: Codable, Identifiable, Sendable {
    public enum Reason: String, Codable, Sendable { case missing, changed, expired, unverified, permission, unfrozen }
    public var id: String
    public var reason: Reason
    public var summary: String
    public var sceneIDs: [String]
    public init(id: String, reason: Reason, summary: String, sceneIDs: [String] = []) { self.id = id; self.reason = reason; self.summary = summary; self.sceneIDs = sceneIDs }
}

public enum DependencyRules {
    public static func validateMappings(product: Product, assets: [Asset], evidence: [Evidence], requireCurrentConfirmation:Bool = true) throws {
        let mappings = product.courseMappings ?? []
        guard Set(mappings.map(\.id)).count == mappings.count else { throw VideoError.invalid("课程映射ID重复") }
        for mapping in mappings { var selected=mapping;if !requireCurrentConfirmation{selected.confirmed=false};try selected.validate(workspaceID: product.workspaceID, assets: assets, evidence: evidence) }
    }
    public static func validateMappings(context: ContentContext, assets: [Asset], evidence: [Evidence], requireCurrentConfirmation:Bool = true) throws {
        try context.validate()
        let mappings=context.courseMappings ?? []
        guard Set(mappings.map(\.id)).count==mappings.count else{throw VideoError.invalid("课程映射ID重复")}
        for mapping in mappings{var selected=mapping;if !requireCurrentConfirmation{selected.confirmed=false};try selected.validate(workspaceID:context.workspaceID,assets:assets,evidence:evidence)}
    }
    public static func freeze(revision: Revision, assets: [Asset], evidence: [Evidence], now: Date = Date()) throws -> DependencySnapshot {
        try revision.validateContext()
        let workspaceID = revision.workspaceID
        var assetScenes: [String: Set<String>] = [:], evidenceScenes: [String: Set<String>] = [:], mappingScenes: [String: Set<String>] = [:]
        var selectedPages: [String: Set<Int>] = [:]
        let mappings = revision.courseMappings
        func addAsset(_ id: String?, _ scenes: Set<String>) throws {
            guard let id else { return }
            guard let a = assets.first(where: { $0.id == id && $0.workspaceID == workspaceID }) else { throw VideoError.permission("引用的素材缺失或不属于当前工作区") }
            assetScenes[id, default: []].formUnion(scenes)
            if let eid = a.evidenceID { evidenceScenes[eid, default: []].formUnion(scenes) }
        }
        for scene in revision.scenes {
            let ids: Set<String> = [scene.id]
            for source in scene.narrativeSources ?? [] { try source.validate(workspaceID:workspaceID,assets:assets);try addAsset(source.assetID,ids);selectedPages[source.assetID,default:[]].formUnion(source.pages) }
            try addAsset(scene.assetID, ids); try addAsset(scene.voice?.assetID, ids)
            for layer in scene.layers ?? [] { try addAsset(layer.assetID, ids) }
            if let artwork=scene.classicArtwork {
                try ClassicArtworkRules.validate(scene:scene,assets:assets.filter{$0.workspaceID==workspaceID})
                for id in artwork.assetIDs { try addAsset(id,ids) }
                for id in artwork.evidenceIDs { evidenceScenes[id,default:[]].formUnion(ids) }
            }
            if let character=scene.characterProfile { try addAsset(character.voiceAssetID,ids);for id in character.evidenceIDs { evidenceScenes[id,default:[]].formUnion(ids) } }
            for id in scene.evidenceIDs { evidenceScenes[id, default: []].formUnion(ids) }
            for id in scene.courseMappingIDs ?? [] {
                guard let mapping = mappings.first(where: { $0.id == id }) else { throw VideoError.notFound("场景引用的课程映射已缺失") }
                // Unconfirmed/changed source text can still be saved as a draft revision.
                // The quality gate below blocks delivery until the cited pages are checked.
                var structuralMapping = mapping; structuralMapping.confirmed = false
                try structuralMapping.validate(workspaceID: workspaceID, assets: assets, evidence: evidence)
                mappingScenes[id, default: []].formUnion(ids); try addAsset(mapping.assetID, ids)
                if mapping.rangeKind == .pages { selectedPages[mapping.assetID, default: []].formUnion(mapping.start...mapping.end) }
                else if mapping.rangeKind == .whole, let a = assets.first(where: { $0.id == mapping.assetID }), !a.pages.isEmpty { selectedPages[mapping.assetID, default: []].formUnion(a.pages.map(\.number)) }
                for eid in mapping.evidenceIDs { evidenceScenes[eid, default: []].formUnion(ids) }
            }
        }
        for id in revision.productionBrief?.evidenceIDs ?? [] {
            evidenceScenes[id,default:[]].formUnion(Set(revision.scenes.map(\.id)))
        }
        try addAsset(revision.musicAssetID, Set(revision.scenes.map(\.id)))
        // Evidence may itself cite a document with its own rights; walk that graph once per edge.
        var visited: [String:Set<String>] = [:]
        while let id = evidenceScenes.keys.sorted().first(where: { visited[$0] != evidenceScenes[$0] }) {
            visited[id]=evidenceScenes[id]
            guard let e = evidence.first(where: { $0.id == id && $0.workspaceID == workspaceID }) else { throw VideoError.permission("引用的证据缺失或不属于当前工作区") }
            try addAsset(e.assetID, evidenceScenes[id] ?? [])
        }
        var records: [FrozenDependency] = []
        for id in assetScenes.keys.sorted() {
            var asset = assets.first(where: { $0.id == id && $0.workspaceID == workspaceID })!
            let pages = selectedPages[id]?.sorted(); asset.pages = asset.pages.filter { pages?.contains($0.number) == true }
            records.append(FrozenDependency(id: "asset:"+id, kind: .asset, label: asset.name, digest: try assetDigest(asset, pageNumbers: pages), sceneIDs: assetScenes[id]!.sorted(), asset: asset, pageNumbers: pages))
        }
        for id in evidenceScenes.keys.sorted() {
            let item = evidence.first(where: { $0.id == id && $0.workspaceID == workspaceID })!
            records.append(FrozenDependency(id: "evidence:"+id, kind: .evidence, label: item.title, digest: try item.contentDigest(), sceneIDs: evidenceScenes[id]!.sorted(), evidence: item))
        }
        for id in mappingScenes.keys.sorted() {
            let item = mappings.first(where: { $0.id == id })!
            records.append(FrozenDependency(id: "mapping:"+id, kind: .mapping, label: item.title, digest: try Codec.digest(item), sceneIDs: mappingScenes[id]!.sorted(), mapping: item))
        }
        return DependencySnapshot(version:revision.schemaVersion,workspaceID: workspaceID, productID: revision.product?.id, contentContextID:revision.contentContext?.id, records: records, capturedAt: now)
    }
    public static func diff(revision: Revision, assets: [Asset], evidence: [Evidence], currentProduct: Product? = nil, now: Date = Date()) -> [DependencyChange] {
        if let product=currentProduct,(product.id != revision.product?.id || product.workspaceID != revision.workspaceID) {return [DependencyChange(id:"product",reason:.permission,summary:"当前产品事实不属于该工程上下文")]}
        guard let snapshot = revision.dependencies else { return [DependencyChange(id: "snapshot", reason: .unfrozen, summary: "此版本尚未冻结素材与证据依赖，请创建新版本并重新审核")] }
        guard snapshot.version == revision.schemaVersion, snapshot.workspaceID == revision.workspaceID, snapshot.productID == revision.product?.id, snapshot.contentContextID == revision.contentContext?.id else { return [DependencyChange(id: "snapshot", reason: .permission, summary: "依赖快照不属于当前工程或版本不支持")] }
        var changes: [DependencyChange] = []
        let commercial = revision.purpose != .education
        for record in snapshot.records {
            func add(_ reason: DependencyChange.Reason, _ description: String) { changes.append(DependencyChange(id: record.id+":"+reason.rawValue, reason: reason, summary: record.label+"："+description, sceneIDs: record.sceneIDs)) }
            switch record.kind {
            case .asset:
                guard let old = record.asset, let item = assets.first(where: { $0.id == old.id && $0.workspaceID == snapshot.workspaceID }) else { add(.missing, "源素材已缺失或跨工作区"); continue }
                if (try? assetDigest(item, pageNumbers: record.pageNumbers)) != record.digest { add(.changed, "文件、裁切基准、授权关联或所引用校对页已变化") }
                if let pages=record.pageNumbers, item.pages.filter({pages.contains($0.number)}).contains(where:{!$0.confirmed || $0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) { add(.unverified, "所引用页面尚未对照原件校对完整") }
                if commercial && item.evidenceID == nil { add(.permission, "源素材缺少商业授权凭据") }
            case .evidence:
                guard let old = record.evidence, let item = evidence.first(where: { $0.id == old.id && $0.workspaceID == snapshot.workspaceID }) else { add(.missing, "证据已缺失或跨工作区"); continue }
                if (try? item.contentDigest()) != record.digest { add(.changed, "主张、来源或权利记录已变化") }
                if let expiry = item.expiresAt, expiry <= now { add(.expired, "证据或授权已到期") }
                if !item.verified || item.source.isEmpty || item.owner.isEmpty { add(.unverified, "来源、权利人或核实状态不完整") }
                if commercial && !item.commercialAllowed { add(.permission, "未获得商业用途许可") }
            case .mapping:
                guard let old = record.mapping, let item = (currentProduct?.courseMappings ?? revision.courseMappings).first(where: { $0.id == old.id }) else { add(.missing, "课程映射已缺失"); continue }
                if (try? Codec.digest(item)) != record.digest { add(.changed, "课程范围、知识点、受众、成果或证据关联已变化") }
                if !item.confirmed { add(.unverified, "课程片段映射尚未人工核实") }
            }
        }
        // Compare graph membership too: adding a source cannot reuse an earlier empty snapshot.
        if let latest = try? freeze(revision: revision, assets: assets, evidence: evidence, now: now) {
            let old = Set(snapshot.records.map(\.id)), new = Set(latest.records.map(\.id))
            if old != new { changes.append(DependencyChange(id: "graph", reason: .changed, summary: "场景引用的素材或证据集合已变化，需重新冻结并审核", sceneIDs: revision.scenes.map(\.id))) }
        } else { changes.append(DependencyChange(id: "graph", reason: .missing, summary: "场景依赖存在缺失、越权或无效范围")) }
        return changes
    }
    public static func reviewIssues(revision: Revision, assets: [Asset], evidence: [Evidence], currentProduct: Product? = nil, now: Date = Date()) -> [String] { diff(revision: revision, assets: assets, evidence: evidence, currentProduct: currentProduct, now: now).map(\.summary) }
    /// Source changes append a new draft; historical source snapshots and review records remain immutable.
    /// Call inside the same Repository transaction that updates the source metadata.
    public static func refreshDependents(in database: inout Database, workspaceID: String, changedEvidenceIDs: Set<String> = [], changedAssetIDs: Set<String> = [], reason: String) throws {
        for index in database.projects.indices where database.projects[index].workspaceID == workspaceID {
            let old = database.projects[index].current
            let snapshot = old.dependencies ?? (try? freeze(revision:old,assets:database.assets,evidence:database.evidence))
            let latest = try? freeze(revision:old,assets:database.assets,evidence:database.evidence)
            let affected = snapshot?.records.contains { record in
                let selected = (record.kind == .evidence && record.evidence.map {changedEvidenceIDs.contains($0.id)} == true) ||
                (record.kind == .asset && record.asset.map {changedAssetIDs.contains($0.id)} == true)
                guard selected else { return false }
                return old.dependencies == nil || latest?.records.first(where:{$0.id==record.id})?.digest != record.digest
            } == true
            guard affected else { continue }
            var revision=old;revision.id=Codec.id();revision.parentID=old.id;revision.number=old.number+1;revision.createdAt=Date();revision.review=Review();revision.change=reason;revision.invalidated=Array(Set(old.invalidated+["sources","rights","review","exports"])).sorted()
            // Keep the earlier frozen values visible until a deliberate edit/refresh and review.
            revision.dependencies=old.dependencies
            database.projects[index].revisions.append(revision)
            for p in database.publications.indices where database.publications[p].projectID == database.projects[index].id { database.publications[p].stale=true }
        }
    }
    private struct AssetFingerprint: Encodable { var id: String; var workspaceID: String; var hash: String; var ext: String; var bytes: Int; var mediaType: String; var durationFrames: Int?; var evidenceID: String?; var generatedSource: GeneratedAssetSource?; var pages: [CoursePage] }
    private static func assetDigest(_ asset: Asset, pageNumbers: [Int]?) throws -> String { try Codec.digest(AssetFingerprint(id: asset.id, workspaceID: asset.workspaceID, hash: asset.hash, ext: asset.ext, bytes: asset.bytes, mediaType: asset.mediaType, durationFrames: asset.durationFrames, evidenceID: asset.evidenceID, generatedSource: asset.generatedSource, pages: asset.pages.filter { pageNumbers?.contains($0.number) == true }.sorted { $0.number < $1.number })) }
}
