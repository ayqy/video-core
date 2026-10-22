import Foundation

/// A trusted caller must bind principal to an authenticated identity before using this context remotely.
/// The iOS owner can inspect these scopes locally; entering a name is not authentication.
public struct WorkspaceAccessContext: Codable, Sendable {
    public var workspaceID: String
    public var principal: String
    public init(workspaceID: String, principal: String) { self.workspaceID=workspaceID;self.principal=principal }
}
public enum WorkspaceSearchKind: String, Codable, CaseIterable, Sendable { case product="产品", project="项目", asset="素材", evidence="证据", order="订单", batch="批次" }
public struct WorkspaceSearchQuery: Sendable {
    public var text=""
    public var tags:Set<String>=[]
    public var statuses:Set<String>=[]
    public var kinds:Set<WorkspaceSearchKind>=[]
    public var from:Date?
    public var through:Date?
    public var projectID:String?
    public var revisionID:String?
    public init() {}
}
public struct WorkspaceSearchHit: Codable, Identifiable, Sendable {
    public var id:String
    public var kind:WorkspaceSearchKind
    public var objectID:String
    public var projectID:String?
    public var revisionID:String?
    public var title:String
    public var detail:String
    public var tags:[String]
    public var status:String
    public var at:Date?
    public var dateBasis:String?
}
public struct ScopedArtifact: Codable, Identifiable, Sendable {
    public var id:String
    public var jobID:String
    public var mime:String
    public var sha256:String
    public var bytes:Int
}
/// Deliberately has no workspace salt, grants, providers, jobs, finance or other revision history.
public struct ScopedRevision: Codable, Sendable {
    public var projectID:String
    public var projectName:String
    public var revision:Revision
    public var comments:[Comment]
    public var assets:[Asset]
    public var evidence:[Evidence]
    public var artifacts:[ScopedArtifact]
    public var legacyMaterialsUnfrozen:Bool
}

public enum WorkspaceAccessRules {
    public static func validate(_ access:WorkspaceAccessContext,in database:Database,now:Date=Date()) throws -> Workspace {
        let workspace=try database.workspace(access.workspaceID)
        guard !access.principal.isEmpty,access.principal==workspace.owner || workspace.grants.contains(where:{!$0.revoked && $0.expiresAt>now && $0.principal==access.principal && $0.role != .owner && !$0.projectIDs.isEmpty && !$0.revisionIDs.isEmpty}) else {throw VideoError.permission("当前身份没有有效工作区授权，或授权已撤销/到期")}
        return workspace
    }
    public static func revision(projectID:String,revisionID:String,access:WorkspaceAccessContext,in database:Database,write:Bool=false,now:Date=Date()) throws -> (Project,Revision) {
        let workspace=try validate(access,in:database,now:now)
        // Check scope before returning any project data, including its name or existence.
        try workspace.authorize(principal:access.principal,project:projectID,revision:revisionID,write:write,now:now)
        guard let project=database.projects.first(where:{$0.id==projectID && $0.workspaceID==workspace.id}),let revision=project.revisions.first(where:{$0.id==revisionID}) else {throw VideoError.notFound("授权项目或版本不存在")}
        return(project,revision)
    }
    /// Authorization is separate from applying edits so an idempotent response also
    /// requires current permission for every historical source it depended on.
    public static func editingProject(projectID:String,baseRevision:String,operations:[Edit],access:WorkspaceAccessContext,in database:Database,now:Date=Date()) throws -> Project {
        let(project,_)=try revision(projectID:projectID,revisionID:baseRevision,access:access,in:database,write:true,now:now)
        for operation in operations {
            if case .restore(let revisionID)=operation {
                _=try revision(projectID:projectID,revisionID:revisionID,access:access,in:database,now:now)
            }
        }
        return project
    }
    public static func search(query:WorkspaceSearchQuery,access:WorkspaceAccessContext,in database:Database,now:Date=Date()) throws -> [WorkspaceSearchHit] {
        guard query.text.count<=1000,query.from == nil || query.through == nil || query.from!<=query.through!,query.revisionID == nil || query.projectID != nil else {throw VideoError.invalid("关键词过长、日期范围倒置，或指定版本时未指定项目")}
        let workspace=try validate(access,in:database,now:now),owner=workspace.owner==access.principal
        if !owner && query.kinds.contains(.order) {throw VideoError.permission("协作者及品牌审核视角不能查询订单或其他财务数据")}
        var permitted:[(Project,Revision)]=[]
        for project in database.projects where project.workspaceID==workspace.id && (query.projectID == nil || project.id==query.projectID) {
            let candidates=project.revisions.filter{query.revisionID == nil || $0.id==query.revisionID}
            for revision in candidates where (owner || (try? workspace.authorize(principal:access.principal,project:project.id,revision:revision.id,now:now)) != nil) {permitted.append((project,revision))}
        }
        if let project=query.projectID {
            if let revision=query.revisionID { _=try self.revision(projectID:project,revisionID:revision,access:access,in:database,now:now) }
            else if !owner {guard !permitted.isEmpty else{throw VideoError.permission("该项目不在有效授权范围内")}}
        }
        var rows:[WorkspaceSearchHit]=[]
        func add(_ kind:WorkspaceSearchKind,_ objectID:String,_ title:String,_ detail:String,_ tags:[String],_ status:String,_ date:Date?=nil,_ basis:String?=nil,projectID:String?=nil,revisionID:String?=nil) {
            guard query.kinds.isEmpty || query.kinds.contains(kind),query.tags.isSubset(of:Set(tags)),query.statuses.isEmpty || query.statuses.contains(status) else{return}
            if let start=query.from {guard let date,date>=start else{return}}
            if let end=query.through {guard let date,date<=end else{return}}
            let words=query.text.split(whereSeparator:{$0.isWhitespace}).map(String.init)
            let haystack=title+" "+detail+" "+tags.joined(separator:" ")+" "+status
            guard words.allSatisfy({haystack.localizedCaseInsensitiveContains($0)}) else{return}
            rows.append(WorkspaceSearchHit(id:kind.rawValue+":"+objectID+(revisionID.map{":"+$0} ?? ""),kind:kind,objectID:objectID,projectID:projectID,revisionID:revisionID,title:title,detail:detail,tags:tags,status:status,at:date,dateBasis:basis))
        }
        // Owners see current projects by default. Scoped reviewers may inspect only their explicitly allowed versions.
        for (project,revision) in permitted where !owner || query.revisionID != nil || revision.id==project.current.id {
            let sourceChanged = !DependencyRules.diff(revision:revision,assets:database.assets,evidence:database.evidence,now:now).isEmpty
            let approved=revision.review.complete && revision.review.digest == (try? revision.contentDigest())
            let status=project.archived ? "archived":sourceChanged ? "sources_changed":approved ? "approved":"needs_review"
            add(.project,project.id,project.name,"v\(revision.number) · "+project.series+" · "+revision.change+" · "+revision.scenes.map{$0.title+" "+$0.body+" "+$0.narration}.joined(separator:" "),project.tags,status,revision.createdAt,"版本创建时间",projectID:project.id,revisionID:revision.id)
        }
        let scoped=(!owner || query.projectID != nil)
        var products:[Product],assets:[Asset],evidence:[Evidence]
        if scoped {
            products=[];assets=[];evidence=[]
            for (_,revision) in permitted {
                if !products.contains(where:{$0.id==revision.product.id}) {products.append(revision.product)}
                let snapshot=try scopedSnapshot(revision,in:database,workspaceID:workspace.id)
                for record in snapshot?.records ?? [] {
                    if let value=record.asset,!assets.contains(where:{$0.id==value.id}) {assets.append(value)}
                    if let value=record.evidence,!evidence.contains(where:{$0.id==value.id}) {evidence.append(value)}
                }
            }
        } else {products=database.products.filter{$0.workspaceID==workspace.id};assets=database.assets.filter{$0.workspaceID==workspace.id};evidence=database.evidence.filter{$0.workspaceID==workspace.id}}
        for value in products {add(.product,value.id,value.name,value.sku+" · "+value.audience+" · "+value.task+" · "+value.outcome,value.tags,value.archived ? "archived":"active",(try? value.price(at:now))?.from,"现价生效时间")}
        for value in assets {let rights=evidence.first{$0.id==value.evidenceID};let status=value.pages.contains{!$0.confirmed} || !value.warnings.isEmpty || rights?.usable(commercial:true,now:now) != true ? "needs_review":"ready";add(.asset,value.id,value.name,value.mediaType+" · "+value.pages.map{$0.text+" "+$0.notes}.joined(separator:" "),value.tags,status,value.importedAt,value.importedAt == nil ? "导入时间未知（旧记录）":"素材导入时间")}
        for value in evidence {let status=(value.expiresAt.map{$0<=now} ?? false) ? "expired":value.usable(commercial:true,now:now) ? "verified":"needs_review";add(.evidence,value.id,value.title,value.claim+" · "+value.source,value.tags ?? [],status,value.checkedAt,"证据核实时间")}
        if owner && query.projectID == nil {
            for value in database.orders where value.workspaceID==workspace.id {let status=value.refunded==value.paid.amount ? "refunded":value.refunded>0 ? "partial_refund":value.mature(at:now) ? "mature":"provisional";add(.order,value.id,value.sku,value.platform+" · "+value.paid.display+" · "+(value.sourceCode ?? "未知来源"),value.tags ?? [],status,value.paidAt,"订单付款时间")}
            for value in database.imports where TagRules.importBelongs(value,to:workspace.id,in:database) {add(.batch,value.id,value.kind=="orders" ? "订单导入批次":"指标导入批次",value.kind+" · \(value.orderIDs.count+value.metricIDs.count)条记录",value.tags ?? [],value.rolledBack ? "rolled_back":"imported",value.at,"批次导入时间")}
            for value in database.topicBatches ?? [] where value.workspaceID==workspace.id {let refreshed=BatchRules.refreshed(value,database:database,now:now);add(.batch,value.id,value.title,refreshed.items.map{$0.topic.hook+" · "+$0.state.rawValue}.joined(separator:" · "),value.tags ?? [],"creative_batch",value.createdAt,"批次创建时间")}
        }
        let grouped=Dictionary(grouping:permitted,by:{$0.0.batchID ?? ""})
        for (id,values) in grouped where !id.isEmpty && !rows.contains(where:{$0.kind == .batch && $0.objectID==id}) {
            let uniqueProjects=Dictionary(grouping:values,by:{$0.0.id}).compactMap{$0.value.first}
            add(.batch,id,uniqueProjects.first?.0.series.isEmpty == false ? uniqueProjects.first!.0.series:"创作批次",uniqueProjects.map{$0.0.name}.joined(separator:" · "),Array(Set(uniqueProjects.flatMap{$0.0.tags})).sorted(),"creative_batch",values.map{$0.1.createdAt}.max(),"最近授权版本创建时间")
        }
        return rows.sorted {a,b in if a.at != b.at {return (a.at ?? .distantPast)>(b.at ?? .distantPast)};return a.id<b.id}
    }
    public static func readModel(projectID:String,revisionID:String,access:WorkspaceAccessContext,in database:Database,now:Date=Date()) throws -> ScopedRevision {
        let(project,original)=try revision(projectID:projectID,revisionID:revisionID,access:access,in:database,now:now)
        let snapshot=try scopedSnapshot(original,in:database,workspaceID:access.workspaceID)
        var revision=original
        revision.dependencies=snapshot
        let mappingIDs=Set(revision.scenes.flatMap{$0.courseMappingIDs ?? []})
        revision.product.courseMappings=revision.product.courseMappings?.filter{mappingIDs.contains($0.id)}
        let assets=(snapshot?.records ?? []).compactMap(\.asset),evidence=(snapshot?.records ?? []).compactMap(\.evidence)
        revision.product.assetIDs=assets.map(\.id)
        let artifacts=database.jobs.filter{$0.workspaceID==access.workspaceID && $0.projectID==projectID && $0.revisionID==revisionID}.flatMap{job in job.artifacts.map{ScopedArtifact(id:job.id+":"+$0.sha256,jobID:job.id,mime:$0.mime,sha256:$0.sha256,bytes:$0.bytes)}}
        return ScopedRevision(projectID:project.id,projectName:project.name,revision:revision,comments:project.comments.filter{$0.revisionID==revisionID},assets:assets,evidence:evidence,artifacts:artifacts,legacyMaterialsUnfrozen:original.dependencies == nil)
    }
    private static func scopedSnapshot(_ revision:Revision,in database:Database,workspaceID:String) throws -> DependencySnapshot? {
        guard let stored=revision.dependencies else{return try? DependencyRules.freeze(revision:revision,assets:database.assets,evidence:database.evidence)}
        guard stored.version==1,stored.workspaceID==workspaceID,stored.productID==revision.product.id else{throw VideoError.permission("版本来源快照的工作区或产品归属不符")}
        let assets=stored.records.compactMap(\.asset),evidence=stored.records.compactMap(\.evidence)
        guard assets.allSatisfy({$0.workspaceID==workspaceID}),evidence.allSatisfy({$0.workspaceID==workspaceID}) else{throw VideoError.permission("版本来源快照包含其他工作区材料，已拒绝共享")}
        // Rebuild the reachable graph from frozen values, excluding injected/unreferenced records.
        return try DependencyRules.freeze(revision:revision,assets:assets,evidence:evidence,now:stored.capturedAt)
    }
}

public enum TagRules {
    public static func normalized(_ values:[String]) throws -> [String] {
        let tags=Array(Set(values.map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty})).sorted()
        guard tags.count<=30,tags.allSatisfy({$0.count<=40 && !$0.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)})}) else{throw VideoError.invalid("最多30个标签，每个不超过40字且不含控制字符")}
        return tags
    }
    static func importBelongs(_ receipt:ImportReceipt,to workspaceID:String,in database:Database)->Bool {
        let orders=database.orders.filter{receipt.orderIDs.contains($0.id)}+receipt.previousOrders
        let metrics=database.metrics.filter{receipt.metricIDs.contains($0.id)}+receipt.previousMetrics
        let scopes=Set(orders.map(\.workspaceID)+metrics.map(\.workspaceID))
        if let scope=receipt.workspaceID {return scope==workspaceID && scopes.isSubset(of:[workspaceID])}
        return !scopes.isEmpty && scopes==[workspaceID]
    }
    /// Owner metadata only; it never changes a frozen revision or grants collaboration access.
    public static func apply(kind:WorkspaceSearchKind,objectID:String,tags:[String],access:WorkspaceAccessContext,in database:inout Database) throws {
        let workspace=try database.workspace(access.workspaceID)
        guard workspace.owner==access.principal else{throw VideoError.permission("只有工作区作者可修改资料标签")}
        let values=try normalized(tags)
        switch kind {
        case .product:guard let i=database.products.firstIndex(where:{$0.id==objectID && $0.workspaceID==workspace.id}) else{throw VideoError.notFound("产品不存在")};database.products[i].tags=values
        case .project:guard let i=database.projects.firstIndex(where:{$0.id==objectID && $0.workspaceID==workspace.id}) else{throw VideoError.notFound("项目不存在")};database.projects[i].tags=values
        case .asset:guard let i=database.assets.firstIndex(where:{$0.id==objectID && $0.workspaceID==workspace.id}) else{throw VideoError.notFound("素材不存在")};database.assets[i].tags=values
        case .evidence:guard let i=database.evidence.firstIndex(where:{$0.id==objectID && $0.workspaceID==workspace.id}) else{throw VideoError.notFound("证据不存在")};database.evidence[i].tags=values
        case .order:guard let i=database.orders.firstIndex(where:{$0.id==objectID && $0.workspaceID==workspace.id}) else{throw VideoError.notFound("订单不存在")};database.orders[i].tags=values
        case .batch:
            if let i=database.topicBatches?.firstIndex(where:{$0.id==objectID && $0.workspaceID==workspace.id}) {database.topicBatches?[i].tags=values}
            else if let i=database.imports.firstIndex(where:{$0.id==objectID && importBelongs($0,to:workspace.id,in:database)}) {database.imports[i].tags=values}
            else {let indices=database.projects.indices.filter{database.projects[$0].batchID==objectID && database.projects[$0].workspaceID==workspace.id};guard !indices.isEmpty else{throw VideoError.notFound("批次不存在")};for i in indices {database.projects[i].tags=values}}
        }
    }
}

public extension Repository {
    func search(query:WorkspaceSearchQuery,access:WorkspaceAccessContext,now:Date=Date()) throws -> [WorkspaceSearchHit] {try WorkspaceAccessRules.search(query:query,access:access,in:read(),now:now)}
    func revisionReadModel(projectID:String,revisionID:String,access:WorkspaceAccessContext,now:Date=Date()) throws -> ScopedRevision {try WorkspaceAccessRules.readModel(projectID:projectID,revisionID:revisionID,access:access,in:read(),now:now)}
    @discardableResult func appendScopedComment(projectID:String,revisionID:String,sceneID:String?,frame:Int,element:String,text:String,access:WorkspaceAccessContext,now:Date=Date()) throws -> Comment {
        try transaction {database in
            let(project,_)=try WorkspaceAccessRules.revision(projectID:projectID,revisionID:revisionID,access:access,in:database,now:now)
            let comment=Comment(revisionID:revisionID,sceneID:sceneID,frame:frame,element:element,text:text,author:access.principal)
            try CommentRules.validate(comment,project:project)
            guard let index=database.projects.firstIndex(where:{$0.id==project.id}) else{throw VideoError.notFound("项目不存在")}
            database.projects[index].comments.append(comment);return comment
        }
    }
    @discardableResult func applyScopedEdits(projectID:String,baseRevision:String,operations:[Edit],message:String,access:WorkspaceAccessContext,now:Date=Date()) throws -> Revision {
        try transaction {database in
            let project=try WorkspaceAccessRules.editingProject(projectID:projectID,baseRevision:baseRevision,operations:operations,access:access,in:database,now:now)
            var updated=try Editor.apply(operations,to:project,baseRevision:baseRevision,assets:database.assets.filter{$0.workspaceID==access.workspaceID},message:message)
            updated.revisions[updated.revisions.count-1].dependencies=try DependencyRules.freeze(revision:updated.current,assets:database.assets,evidence:database.evidence)
            guard let index=database.projects.firstIndex(where:{$0.id==project.id}) else{throw VideoError.notFound("项目不存在")}
            database.projects[index]=updated;for i in database.publications.indices where database.publications[i].projectID==project.id {database.publications[i].stale=true};return updated.current
        }
    }
    func scopedArtifactURL(projectID:String,revisionID:String,jobID:String,sha256:String,access:WorkspaceAccessContext,now:Date=Date()) throws -> URL {
        let database=try read();let (_,revision)=try WorkspaceAccessRules.revision(projectID:projectID,revisionID:revisionID,access:access,in:database,now:now)
        guard let job=database.jobs.first(where:{$0.id==jobID && $0.workspaceID==access.workspaceID && $0.projectID==projectID && $0.revisionID==revisionID}),let artifact=job.artifacts.first(where:{$0.sha256==sha256}) else{throw VideoError.permission("产物不属于指定授权版本")}
        let url=try verifiedArtifactURL(artifact,job:job,revision:revision)
        let relative=String(url.path.dropFirst(root.path.count+1))
        let allowedNames:Set<String>=["video.mp4","cover.png","captions.srt","publication.txt"]
        let isExport=url.deletingLastPathComponent().lastPathComponent==job.id && relative.hasPrefix("exports/"+job.id+"/") && allowedNames.contains(url.lastPathComponent)
        let isDraft=relative=="drafts/"+job.id+".txt" && artifact.mime=="text/plain"
        guard isExport || isDraft,artifact.revision==revisionID else{throw VideoError.permission("共享产物路径或版本不属于此任务，拒绝读取工程数据库和其他文件")}
        return url
    }
}
