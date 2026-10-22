import Foundation

public enum AgentMutationOrigin:Equatable,Sendable {case cli,nativeIntent}
public enum AgentMutationExecutor {
    public static let commands:Set<String>=["workspaces create","products import","evidence add","script create","edit apply","review record","orders import","metrics import","imports rollback","publications record","sales record","brands record","expenses record","cash record"]
    public static func canonicalInput(command:String,data:Data,principal:String,requestID:String)throws->Data {
        var values=try AgentContract.validate(command:command,data:data)
        guard !principal.isEmpty else{throw VideoError.permission("缺少执行身份")}
        values["principal"] = .string(principal);values["request_id"] = .string(requestID)
        return try Codec.data(AgentValue.object(values))
    }
    public static func authorize(command:String,values:[String:AgentValue],database:Database,principal:String,now:Date=Date())throws {
        if command=="workspaces create" {guard !principal.isEmpty else{throw VideoError.permission("创建空间需要执行身份")};return}
        let workspace=try database.workspace(values["workspace_id"]?.string ?? "")
        let projectID=values["project_id"]?.string
        let revision=values["base_revision"]?.string ?? database.projects.first{$0.id==projectID && $0.workspaceID==workspace.id}?.current.id
        try AgentContract.authorize(command:command,workspace:workspace,principal:principal,projectID:projectID,revisionID:revision,now:now)
        if command=="edit apply" {
            guard let projectID,let revision,let edits=values["edits"] else{throw VideoError.invalid("编辑缺少项目、基准版本或操作")}
            let operations=try Codec.decoder().decode([Edit].self,from:Codec.data(edits))
            _=try WorkspaceAccessRules.editingProject(projectID:projectID,baseRevision:revision,operations:operations,access:WorkspaceAccessContext(workspaceID:workspace.id,principal:principal),in:database,now:now)
        }
    }
    public static func envelope(requestID:String,state:String="succeeded",projectID:String?=nil,revisionID:String?=nil,result:AgentValue = .null)->AgentValue {
        .object(["schema_version":.string(AgentContract.version),"request_id":.string(requestID),"ok":.boolean(true),"state":.string(state),"project_id":projectID.map(AgentValue.string) ?? .null,"revision":revisionID.map(AgentValue.string) ?? .null,"job_id":.null,"artifacts":.array([]),"result":result,"error":.null,"cost":.object(["currency":.string("CNY"),"estimated":.null,"reserved":.null,"actual":.null,"unknown":.string("此操作不提交付费任务；经营费用另记")])])
    }
    public static func preview(command:String,data:Data,database:Database,principal:String)throws->AgentValue {
        let request=(try AgentContract.validate(command:command,data:data))["request_id"]?.string ?? Codec.id()
        let canonical=try canonicalInput(command:command,data:data,principal:principal,requestID:request)
        let values=try AgentContract.validate(command:command,data:canonical)
        try authorize(command:command,values:values,database:database,principal:principal)
        if case .replay(let result)=try AgentContract.replay(command:command,data:canonical,records:database.agentReplayRecords ?? []) {try replayAccess(command:command,response:result,database:database,principal:principal);return result}
        var copy=database;let result=try apply(command:command,values:values,database:&copy,principal:principal,requestID:request,repository:nil)
        try copy.validate();return result
    }
    fileprivate static func replayAccess(command:String,response:AgentValue,database:Database,principal:String)throws {
        if command=="workspaces create" {guard let id=response.object?["result"]?.object?["id"]?.string,database.workspaces.contains(where:{$0.id==id && $0.owner==principal}) else{throw VideoError.permission("原回执空间已不存在或不再属于当前本机身份")}}
    }
    fileprivate static func apply(command:String,values:[String:AgentValue],database:inout Database,principal:String,requestID:String,repository:Repository?)throws->AgentValue {
        func text(_ field:String)->String {values[field]?.string ?? ""}
        func decode<T:Decodable>(_ field:String,_ type:T.Type)throws->T {guard let value=values[field] else{throw VideoError.invalid("缺少"+field)};return try Codec.decoder().decode(type,from:Codec.data(value))}
        func encoded<T:Encodable>(_ value:T)throws->AgentValue {try Codec.decoder().decode(AgentValue.self,from:Codec.data(value))}
        let workspaceID=text("workspace_id")
        func scope<T>(_ items:[T],id:KeyPath<T,String>,workspace:KeyPath<T,String>,requested:String)throws {if items.contains(where:{$0[keyPath:id]==requested && $0[keyPath:workspace] != workspaceID}){throw VideoError.permission("实体ID属于另一工作区，拒绝跨客户覆盖")}}
        var result:AgentValue = .null,projectID:String?,revisionID:String?,state="succeeded"
        switch command {
        case "workspaces create":let workspace=Workspace(name:text("name"),owner:principal);database.workspaces.append(workspace);result=try encoded(workspace)
        case "products import":
            let product=try decode("product",Product.self);guard product.workspaceID==workspaceID else{throw VideoError.permission("产品工作区不符")};try scope(database.products,id:\.id,workspace:\.workspaceID,requested:product.id);try product.validate();try DependencyRules.validateMappings(product:product,assets:database.assets,evidence:database.evidence)
            if let index=database.products.firstIndex(where:{$0.id==product.id}) {if database.products[index] != product {let factsChanged = !database.products[index].hasSameFacts(as:product);database.products[index]=product;if factsChanged{for p in database.projects.indices where database.projects[p].workspaceID==workspaceID && database.projects[p].current.product.id==product.id {database.projects[p]=Editor.updateFacts(product,project:database.projects[p]);for i in database.publications.indices where database.publications[i].projectID==database.projects[p].id {database.publications[i].stale=true}}}}}
            else {guard !database.products.contains(where:{$0.workspaceID==workspaceID && $0.sku==product.sku}) else{throw VideoError.conflict("已有同SKU产品，请更新原产品ID")};database.products.append(product)};result = .string(product.id)
        case "evidence add":
            let evidence=try decode("evidence",Evidence.self);guard evidence.workspaceID==workspaceID,!evidence.title.isEmpty,!evidence.source.isEmpty,!evidence.owner.isEmpty else{throw VideoError.invalid("证据工作区、标题、来源或权利人不完整")};try scope(database.evidence,id:\.id,workspace:\.workspaceID,requested:evidence.id)
            if let id=evidence.assetID {guard database.assets.contains(where:{$0.id==id && $0.workspaceID==workspaceID}) else{throw VideoError.permission("证据所附素材不属于此工作区")}}
            let linked=Set(database.assets.filter{$0.workspaceID==workspaceID && ($0.evidenceID==evidence.id || $0.id==evidence.assetID)}.map(\.id))
            database.evidence.removeAll{$0.id==evidence.id};database.evidence.append(evidence)
            if evidence.assetID != nil {for i in database.assets.indices where database.assets[i].workspaceID==workspaceID && (database.assets[i].evidenceID==evidence.id || database.assets[i].id==evidence.assetID) {database.assets[i].evidenceID=database.assets[i].id==evidence.assetID ? evidence.id:nil}}
            try DependencyRules.refreshDependents(in:&database,workspaceID:workspaceID,changedEvidenceIDs:[evidence.id],changedAssetIDs:linked,reason:"Agent更新证据或权利，需重新复核")
            result = .string(evidence.id)
        case "script create":
            guard let product=database.products.first(where:{$0.id==text("product_id") && $0.workspaceID==workspaceID && !$0.archived}) else{throw VideoError.notFound("已有产品不属于此工作区或已归档")}
            let purpose=values["purpose"]?.string.flatMap(Purpose.init(rawValue:)) ?? .course,aspect=values["aspect"]?.string.flatMap(Aspect.init(rawValue:)) ?? .portrait,kind=values["kind"]?.string.flatMap(SceneKind.init(rawValue:)) ?? .explanation
            let ids=try values["evidence_ids"].map{try Codec.decoder().decode([String].self,from:Codec.data($0))} ?? []
            var revision=try Planner.create(product:product,knowledge:text("knowledge"),demonstration:text("demonstration"),hook:text("hook"),purpose:purpose,aspect:aspect,kind:kind,evidenceIDs:ids)
            revision.dependencies=try DependencyRules.freeze(revision:revision,assets:database.assets,evidence:database.evidence)
            let project=Project(workspaceID:workspaceID,name:values["name"]?.string ?? product.name,revision:revision);database.projects.append(project);projectID=project.id;revisionID=revision.id;state="needs_review";result = .object(["review_required":.boolean(true)])
        case "edit apply":
            let id=text("project_id"),project=try database.project(id);guard project.workspaceID==workspaceID else{throw VideoError.permission("项目工作区不符")}
            var updated=try Editor.apply(decode("edits",[Edit].self),to:project,baseRevision:text("base_revision"),assets:database.assets.filter{$0.workspaceID==workspaceID},message:values["text"]?.string ?? "Agent编辑")
            updated.revisions[updated.revisions.count-1].dependencies=try DependencyRules.freeze(revision:updated.current,assets:database.assets,evidence:database.evidence)
            database.projects[database.projects.firstIndex{$0.id==id}!]=updated;for i in database.publications.indices where database.publications[i].projectID==id {database.publications[i].stale=true};projectID=id;revisionID=updated.current.id;state="needs_review"
        case "review record":
            let id=text("project_id"),project=try database.project(id);guard project.workspaceID==workspaceID,project.current.id==text("base_revision") else{throw VideoError.conflict("审核目标版本已变化")}
            var review=try decode("review",Review.self);review.digest=try project.current.contentDigest();review.reviewer=principal;review.at=Date();var candidate=project.current;candidate.review=review
            if review.complete {let issues=try Quality.inspect(candidate,database:database,requireReview:true,enforceBrandDelivery:false);guard issues.isEmpty else{throw VideoError.review(issues.map(\.message).joined(separator:"；"))};let jobs=database.jobs.indices.filter{database.jobs[$0].workspaceID==workspaceID && database.jobs[$0].projectID==id && database.jobs[$0].revisionID==candidate.id && !database.jobs[$0].artifacts.isEmpty};guard !jobs.isEmpty else{throw VideoError.review("此版本没有可核对的完整预览")};for i in jobs {if let repository {try repository.verifyDelivery(database.jobs[i],revision:candidate)};database.jobs[i].state = .succeeded}}
            database.projects[database.projects.firstIndex{$0.id==id}!].revisions[project.revisions.count-1].review=review;projectID=id;revisionID=candidate.id;result = .string("记录调用者声明的看听审核；不代替品牌审批或发布许可")
        case "orders import":
            let rows=try decode("orders",[Order].self);guard rows.allSatisfy({$0.workspaceID==workspaceID}) else{throw VideoError.permission("订单工作区不符")};for row in rows {try scope(database.orders,id:\.id,workspace:\.workspaceID,requested:row.id)};try importScope(database,batchID:text("batch_id"),workspaceID:workspaceID);try database.importOrders(rows,batchID:text("batch_id"));result = .object(["count":.number(Decimal(rows.count)),"batch_id":.string(text("batch_id"))])
        case "metrics import":
            let rows=try decode("metrics",[Metric].self);guard rows.allSatisfy({$0.workspaceID==workspaceID}) else{throw VideoError.permission("指标工作区不符")};try importScope(database,batchID:text("batch_id"),workspaceID:workspaceID);try database.importMetrics(rows,batchID:text("batch_id"));result = .object(["count":.number(Decimal(rows.count)),"batch_id":.string(text("batch_id"))])
        case "imports rollback":try importScope(database,batchID:text("batch_id"),workspaceID:workspaceID);if !database.imports.contains(where:{$0.id==text("batch_id") && !$0.rolledBack}) && database.imports.contains(where:{$0.id==text("batch_id") && $0.rolledBack}) {result = .string("此批次已回滚，未重复修改记录") } else {try database.rollbackImport(text("batch_id"));result = .string("已恢复本批次导入前记录")}
        case "publications record":
            let publication=try decode("publication",Publication.self);guard publication.workspaceID==workspaceID,let project=database.projects.first(where:{$0.id==publication.projectID && $0.workspaceID==workspaceID}),let revision=project.revisions.first(where:{$0.id==publication.revisionID}) else{throw VideoError.permission("发布目标不属于此工作区")};try scope(database.publications,id:\.id,workspace:\.workspaceID,requested:publication.id);try publication.validate(commercial:revision.purpose != .education);let issues=try Quality.inspect(revision,database:database,requireReview:true);guard issues.isEmpty else{throw VideoError.review(issues.map(\.message).joined(separator:"；"))};guard let job=database.jobs.last(where:{$0.workspaceID==workspaceID && $0.projectID==project.id && $0.revisionID==revision.id && $0.state == .succeeded}) else{throw VideoError.review("此发布版本没有已审核完整成片")};if let repository {try repository.verifyDelivery(job,revision:revision)};try database.recordPublication(publication,jobID:job.id,reviewer:principal);result = .string(database.publications.last{$0.projectID==project.id && $0.revisionID==revision.id}?.state ?? "待核对")
        case "sales record":let value=try decode("sale",ToolSale.self);guard value.workspaceID==workspaceID else{throw VideoError.permission("工具订单工作区不符")};try scope(database.toolSales,id:\.id,workspace:\.workspaceID,requested:value.id);try value.validate();try database.recordToolSale(value);result = .string(value.id)
        case "brands record":let value=try decode("deal",BrandDeal.self);guard value.workspaceID==workspaceID else{throw VideoError.permission("品牌合作工作区不符")};try scope(database.brandDeals,id:\.id,workspace:\.workspaceID,requested:value.id);try value.validate();try database.recordBrandDeal(value);result = .string(value.id)
        case "expenses record":let value=try decode("expense",Expense.self);guard value.workspaceID==workspaceID else{throw VideoError.permission("费用工作区不符")};try scope(database.expenses,id:\.id,workspace:\.workspaceID,requested:value.id);database.expenses.removeAll{$0.id==value.id};database.expenses.append(value);result = .string(value.id)
        case "cash record":let value=try decode("cash",CashEntry.self);guard value.workspaceID==workspaceID else{throw VideoError.permission("回款工作区不符")};try scope(database.cash,id:\.id,workspace:\.workspaceID,requested:value.id);guard !value.receipt.isEmpty || value.assumption else{throw VideoError.invalid("实收必须有凭据，推演须明确标记")};database.cash.removeAll{$0.id==value.id};database.cash.append(value);result = .string(value.id)
        default:throw VideoError.invalid("此操作不是原子数据库写命令")
        }
        return envelope(requestID:requestID,state:state,projectID:projectID,revisionID:revisionID,result:result)
    }
    private static func importScope(_ database:Database,batchID:String,workspaceID:String)throws {
        guard let receipt=database.imports.first(where:{$0.id==batchID}) else{return}
        if let scope=receipt.workspaceID {guard scope==workspaceID else{throw VideoError.permission("导入批次属于另一工作区")};return}
        let scopes=Set((database.orders.filter{receipt.orderIDs.contains($0.id)}+receipt.previousOrders).map(\.workspaceID)+(database.metrics.filter{receipt.metricIDs.contains($0.id)}+receipt.previousMetrics).map(\.workspaceID))
        guard scopes==[workspaceID] else{throw VideoError.permission("旧批次无法唯一确认工作区，拒绝越界回滚")}
    }
}

public extension Repository {
    func performAgentMutation(command:String,data:Data,principal:String,requestID:String,origin:AgentMutationOrigin = .cli)throws->AgentValue {
        guard AgentMutationExecutor.commands.contains(command) else{throw VideoError.invalid("此命令不支持数据库原子回执")}
        let canonical=try AgentMutationExecutor.canonicalInput(command:command,data:data,principal:principal,requestID:requestID)
        let values=try AgentContract.validate(command:command,data:canonical),fingerprint=try AgentContract.fingerprint(command:command,data:canonical)
        return try transaction {database in
            try AgentMutationExecutor.authorize(command:command,values:values,database:database,principal:principal)
            if case .replay(let response)=try AgentContract.replay(command:command,data:canonical,records:database.agentReplayRecords ?? []) {try AgentMutationExecutor.replayAccess(command:command,response:response,database:database,principal:principal);return response}
            if command=="script create",let legacy=database.intentReceipts?.first(where:{$0.workspaceID==values["workspace_id"]?.string && $0.requestID==requestID}) {
                guard legacy.inputDigest==(try AgentContract.fingerprint(command:command,data:data)),database.projects.contains(where:{$0.id==legacy.projectID && $0.workspaceID==legacy.workspaceID && $0.revisions.contains(where:{$0.id==legacy.revisionID})}) else{throw VideoError.conflict("旧原生草稿回执与此次输入或项目不符，未重复创建")}
                let response=AgentMutationExecutor.envelope(requestID:requestID,state:"needs_review",projectID:legacy.projectID,revisionID:legacy.revisionID,result:.object(["review_required":.boolean(true)]));database.agentReplayRecords=(database.agentReplayRecords ?? [])+[AgentReplayRecord(requestID:requestID,command:command,fingerprint:fingerprint,response:response)];return response
            }
            let response=try AgentMutationExecutor.apply(command:command,values:values,database:&database,principal:principal,requestID:requestID,repository:self)
            database.agentReplayRecords=(database.agentReplayRecords ?? [])+[AgentReplayRecord(requestID:requestID,command:command,fingerprint:fingerprint,response:response)]
            if origin == .nativeIntent,command=="script create",let result=response.object,let id=result["project_id"]?.string,let revision=result["revision"]?.string {database.intentReceipts=(database.intentReceipts ?? [])+[IntentReceipt(workspaceID:values["workspace_id"]?.string ?? "",requestID:requestID,inputDigest:try AgentContract.fingerprint(command:command,data:data),projectID:id,revisionID:revision,createdAt:Date())]}
            return response
        }
    }
}
