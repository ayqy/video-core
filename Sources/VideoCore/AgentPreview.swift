import Foundation

/// Validate an agent operation against a value snapshot. No task, network call or file is created.
public enum AgentPreview {
    public static func evaluate(command:String,data:Data,database:Database,principal:String="local-owner") throws -> AgentValue {
        let object=try AgentContract.validate(command:command,data:data)
        if AgentMutationExecutor.commands.contains(command) {return try AgentMutationExecutor.preview(command:command,data:data,database:database,principal:principal)}
        func text(_ key:String)->String { object[key]?.string ?? "" }
        func decode<T:Decodable>(_ key:String,_ type:T.Type)throws->T { guard let value=object[key] else {throw VideoError.invalid("缺少"+key)};return try Codec.decoder().decode(type,from:Codec.data(value)) }
        if command=="workspaces create" { guard !text("name").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw VideoError.invalid("工作区名称为空")};return .string("仅校验新工作区名称，不创建目录或工程") }
        let w=try database.workspace(text("workspace_id"))
        let originalJob=database.jobs.first{$0.id==text("job_id") && $0.workspaceID==w.id}
        let projectID=object["project_id"]?.string ?? originalJob?.projectID
        // Match the normal CLI's exact target without adding a caller-supplied
        // schema field. A historical job keeps its frozen revision; permission
        // for the current project must never authorize a different old job.
        let revisionID=object["base_revision"]?.string ?? originalJob?.revisionID ?? database.projects.first{$0.id==projectID && $0.workspaceID==w.id}?.current.id
        try AgentContract.authorize(command:command,workspace:w,principal:principal,projectID:projectID,revisionID:revisionID)
        func project()throws->Project { let p=try database.project(projectID ?? "");guard p.workspaceID==w.id else {throw VideoError.permission("项目不属于所选工作区")};return p }
        func job()throws->Job { guard let j=database.jobs.first(where:{$0.id==text("job_id") && $0.workspaceID==w.id})else{throw VideoError.notFound("任务不属于所选工作区")};return j }
        switch command {
        case "projects facts-impact":
            let impact = try database.projectFactImpact(projectID: text("project_id"), workspaceID: w.id)
            return try Codec.decoder().decode(AgentValue.self, from: Codec.data(impact))
        case "knowledge compare":
            let p = try project()
            guard p.current.id == text("base_revision") else { throw VideoError.conflict("知识对照目标版本已变化，请重新读取当前工程") }
            guard let baseline = p.current.scenes.first(where: { $0.id == text("scene_id") }),
                  let alternative = p.current.scenes.first(where: { $0.id == text("comparison_scene_id") }) else {
                throw VideoError.notFound("知识对照的两个镜头须属于同一当前版本")
            }
            guard baseline.kind == .simulation, alternative.kind == .simulation,
                  let first = baseline.simulation.knowledge, let second = alternative.simulation.knowledge else {
                throw VideoError.invalid("知识对照需要两个实际知识仿真镜头")
            }
            guard baseline.simulation.seed == alternative.simulation.seed else { throw VideoError.invalid("反事实对照须显式使用相同种子，不能忽略对照镜头种子") }
            let explanation = try KnowledgeCounterfactualExplanation.build(baseline: first, alternative: second, seed: baseline.simulation.seed)
            return try Codec.decoder().decode(AgentValue.self, from: Codec.data(explanation))
        case "speech synthesize","speech attach":
            let request=try Codec.decoder().decode(SpeechProjectRequest.self,from:data)
            _=try SpeechProjectRules.prepare(request,database:database,principal:principal)
            if let id=request.assetID {guard let a=database.assets.first(where:{$0.id==id && $0.workspaceID==w.id}),let e=database.evidence.first(where:{$0.id==a.evidenceID && $0.workspaceID==w.id && $0.assetID==a.id}),e.usable(commercial:try project().current.purpose != .education),a.mediaType=="audio",(a.durationFrames ?? 0)>0 else {throw VideoError.permission("已导入的真实音轨或适用权利未就绪")}}
            return .string("确认稿、精确版本、镜头锁定及写权限检查通过；未生成音频、写CAS或改工程。声音库存由本机入口另行核对，听审和声音权利仍待人工核对")
        case "baidu submit":
            guard let profile=database.providers.first(where:{$0.id==text("profile_id")}) else{throw VideoError.notFound("已有百度配置不存在")};var copy=database;_ = try BaiduVideoRules.prepare(database:&copy,workspaceID:w.id,projectID:text("project_id"),profile:profile,input:decode("baidu_input",BaiduVideoInput.self),quote:decode("quote",Quote.self),requestID:text("request_id"),principal:principal);try copy.validate();return .string("已核固定合同、上传同意、输入摘要、原任务回执与预算；未读取凭据或发起收费请求")
        case "baidu query","baidu collect":
            let original=try job();guard original.videoGeneration != nil,let id=original.remoteID,let profile=database.providers.first(where:{$0.id==original.quote.provider}) else{throw VideoError.unavailable("缺少可查询的原百度ID或合同配置")};try BaiduVideoRules.validate(profile:profile);try BaiduVideoRules.validateID(id);return .string("原ID、合同与本机所有者检查通过；未查询网络、下载或证明成片可用")
        case "worker run","worker launch":
            func integer(_ field:String,_ fallback:Int)->Int {if case .number(let n)=object[field]{return NSDecimalNumber(decimal:n).intValue};return fallback}
            let ids:[String];if case .array(let values)=object["job_ids"] {ids=values.compactMap(\.string)}else{ids=[]}
            let plan=try AgentWorkerPlan(workspaceID:w.id,jobIDs:ids,maximumJobs:integer("max_jobs",5),timeoutSeconds:integer("timeout_seconds",300),resumeInterrupted:object["resume_interrupted"] == .boolean(true),queryRemote:object["query_remote"] == .boolean(true))
            return .object(["selected_original_job_ids":.array(try plan.select(database:database,principal:principal).map(AgentValue.string)),"timeout_seconds":.number(Decimal(plan.timeoutSeconds)),"side_effects":.string("仅计划；未创建worker控制记录、进程、任务或远端请求")])
        case "worker status","worker stop":guard text("worker_id").range(of:"^[a-f0-9]{32}$",options:.regularExpression) != nil else{throw VideoError.invalid("worker_id格式不符")};return .string("仅校验本机所有者与worker标识；真实控制记录在执行时核对")
        case "assets import":let url=URL(fileURLWithPath:text("path"));let attrs=try FileManager.default.attributesOfItem(atPath:url.path);guard let size=attrs[.size] as? NSNumber,size.intValue>0,size.intValue<=256*1024*1024 else{throw VideoError.invalid("素材为空或超过256MiB")};if !text("evidence_id").isEmpty {guard database.evidence.contains(where:{$0.id==text("evidence_id") && $0.workspaceID==w.id})else{throw VideoError.permission("许可凭据不属于工作区")}};return .string("路径、大小、工作区与许可引用检查通过；完整媒体解析在实际导入执行，未写CAS或工程")
        case "products import":let p=try decode("product",Product.self);guard p.workspaceID==w.id else{throw VideoError.permission("产品工作区不符")};try p.validate();try DependencyRules.validateMappings(product:p,assets:database.assets,evidence:database.evidence)
        case "evidence add":let e=try decode("evidence",Evidence.self);guard e.workspaceID==w.id else{throw VideoError.permission("证据工作区不符")}
        case "script create":guard let p=database.products.first(where:{$0.id==text("product_id") && $0.workspaceID==w.id})else{throw VideoError.notFound("产品不存在")};let purpose=object["purpose"] == nil ? Purpose.course:try decode("purpose",Purpose.self);let aspect=object["aspect"] == nil ? Aspect.portrait:try decode("aspect",Aspect.self);let kind=object["kind"] == nil ? SceneKind.explanation:try decode("kind",SceneKind.self);var r=try Planner.create(product:p,knowledge:text("knowledge"),demonstration:text("demonstration"),hook:text("hook"),purpose:purpose,aspect:aspect,kind:kind,evidenceIDs:object["evidence_ids"] == nil ? []:try decode("evidence_ids",[String].self));r.dependencies=try DependencyRules.freeze(revision:r,assets:database.assets,evidence:database.evidence)
        case "edit apply":_ = try Editor.apply(decode("edits",[Edit].self),to:project(),baseRevision:text("base_revision"),assets:database.assets,message:text("text"))
        case "review record":let p=try project();guard p.current.id==text("base_revision")else{throw VideoError.conflict("审核目标不是当前版本")};_ = try decode("review",Review.self)
        case "render estimate":_ = try project();if object["estimate"] != nil {try decode("estimate",EstimateBreakdown.self).validate()}
        case "render submit":let p=try project();let issues=try Quality.inspect(p.current,database:database,requireReview:false);guard issues.isEmpty else{throw VideoError.review(issues.map(\.message).joined(separator:"；"))};_ = try JobRules.submit(workspaceID:w.id,project:p,quote:decode("quote",Quote.self),requestKey:text("request_id"),existing:database.jobs,budget:object["budget"] == nil ? database.budget:try decode("budget",BudgetPolicy.self))
        case "jobs run":_ = try JobOperations.claim(job(),owner:"dry-run")
        case "jobs cancel", "jobs status", "jobs query", "jobs remote-cancel":_ = try job()
        case "jobs resume":_ = try JobRules.recover(job())
        case "jobs reconcile":_ = try JobOperations.reconcile(job(),record:decode("billing_record",BillingRecord.self))
        case "orders import":let rows=try decode("orders",[Order].self);guard rows.allSatisfy({$0.workspaceID==w.id})else{throw VideoError.permission("订单工作区不符")};var copy=database;try copy.importOrders(rows,batchID:text("batch_id"))
        case "metrics import":let rows=try decode("metrics",[Metric].self);guard rows.allSatisfy({$0.workspaceID==w.id})else{throw VideoError.permission("指标工作区不符")};var copy=database;try copy.importMetrics(rows,batchID:text("batch_id"));for m in rows{try m.validate()}
        case "imports rollback":var copy=database;try copy.rollbackImport(text("batch_id"))
        case "publications record":let pub=try decode("publication",Publication.self);guard pub.workspaceID==w.id,let p=database.projects.first(where:{$0.id==pub.projectID && $0.workspaceID==w.id}),let r=p.revisions.first(where:{$0.id==pub.revisionID})else{throw VideoError.permission("发布目标不属于工作区")};try pub.validate(commercial:r.purpose != .education);guard try Quality.inspect(r,database:database,requireReview:true).isEmpty else{throw VideoError.review("发布版本未通过质量门")}
        case "sales record":let sale=try decode("sale",ToolSale.self);guard sale.workspaceID==w.id else{throw VideoError.permission("销售工作区不符")};try sale.validate()
        case "brands record":let deal=try decode("deal",BrandDeal.self);guard deal.workspaceID==w.id else{throw VideoError.permission("商单工作区不符")};try deal.validate()
        case "expenses record":var copy=database;let expense=try decode("expense",Expense.self);guard expense.workspaceID==w.id else{throw VideoError.permission("费用工作区不符")};copy.expenses.append(expense);try copy.validate()
        case "cash record":var copy=database;let cash=try decode("cash",CashEntry.self);guard cash.workspaceID==w.id,!cash.receipt.isEmpty || cash.assumption else{throw VideoError.invalid("实收需凭据，工作区须一致")};copy.cash.append(cash);try copy.validate()
        case "products list","assets list","projects list","reports contribution":break
        default:throw VideoError.invalid("此命令需使用专用只读检查路径")
        }
        return .string("输入、权限和当前业务规则检查通过；未写工程、未生成媒体、未调用远端或扣费")
    }
}
