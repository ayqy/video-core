import Foundation

public struct IntentReceipt: Codable, Identifiable, Sendable {
    public var id:String {workspaceID+":"+requestID}
    public var workspaceID:String
    public var requestID:String
    public var inputDigest:String
    public var projectID:String
    public var revisionID:String
    public var createdAt:Date
}

/// Native iOS intents are a narrow, non-network adapter over the same domain rules as CLI/SDK.
/// Principal is supplied by the authenticated local-device host, never by an intent parameter.
public enum NativeAgent {
    public static let principal="local-owner"
    public static let commands=["capabilities","projects list","script create","jobs status"]
    public static func execute(command:String,input:[String:AgentValue],repository:Repository,principal:String=NativeAgent.principal) -> AgentValue {
        let request=input["request_id"]?.string ?? Codec.id()
        do {
            guard commands.contains(command),input["principal"] == nil else{throw VideoError.permission("此原生入口只支持能力发现、列项目、待审草稿与查询原任务；不能指定其他身份")}
            let data=try Codec.data(AgentValue.object(input)),values=try AgentContract.validate(command:command,data:data)
            func text(_ key:String)->String {values[key]?.string ?? ""}
            if command=="capabilities" {
                let database=try repository.read()
                let spaces=database.workspaces.filter{$0.owner==principal}.map{workspace in AgentValue.object(["workspace_id":.string(workspace.id),"name":.string(workspace.name),"products":.array(database.products.filter{$0.workspaceID==workspace.id && !$0.archived}.map{.object(["product_id":.string($0.id),"sku":.string($0.sku),"name":.string($0.name)])})])}
                let schemas:[AgentValue]=try commands.map{.object(["command":AgentValue.string($0),"input_schema":try nativeSchema($0)])}
                return envelope(request:request,state:"ready",result:.object(["native_commands":.array(schemas),"workspaces":.array(spaces),"execution":.string("iOS AppIntents；本机设备认证与本地所有者范围；不调用付费服务、购买或发布"),"core_schema_version":.string(AgentContract.version)]))
            }
            let workspaceID=text("workspace_id")
            if command=="script create" {
                guard values["request_id"]?.string != nil else{throw VideoError.invalid("原生创建草稿必须提供request_id，重试沿用原值")}
                if let kind=values["kind"]?.string,kind != SceneKind.explanation.rawValue {throw VideoError.permission("原生草稿入口仅使用免费图文讲解；高级模板请在App中按权益创建")}
                return try repository.performAgentMutation(command:command,data:data,principal:principal,requestID:request,origin:.nativeIntent)
            }
            let database=try repository.read(),workspace=try database.workspace(workspaceID)
            guard workspace.owner==principal else{throw VideoError.permission("原生入口只能读取本机使用者拥有的工作区")}
            if command=="projects list" {
                try AgentContract.authorize(command:command,workspace:workspace,principal:principal)
                return envelope(request:request,state:"ready",result:.array(database.projects.filter{$0.workspaceID==workspaceID}.map{project in .object(["project_id":.string(project.id),"name":.string(project.name),"revision":.string(project.current.id),"version":.number(Decimal(project.current.number)),"archived":.boolean(project.archived),"review_required":.boolean(!project.current.review.complete)])}))
            }
            guard let job=database.jobs.first(where:{$0.id==text("job_id") && $0.workspaceID==workspaceID}) else{throw VideoError.notFound("原job_id不属于指定工作区或不存在；没有创建新任务")}
            try AgentContract.authorize(command:command,workspace:workspace,principal:principal,projectID:job.projectID,revisionID:job.revisionID)
            return envelope(request:request,state:job.state.rawValue,projectID:job.projectID,revisionID:job.revisionID,jobID:job.id,result:.object(["progress":job.progress.isFinite ? .number(Decimal(job.progress)):.null,"remote_task_id":job.remoteID.map(AgentValue.string) ?? .null,"updated_at":.string(ISO8601DateFormatter().string(from:job.updatedAt)),"message":.string("查询本地原任务记录；远端状态未知时需在App中查询原ID，未重复提交")]))
        } catch {
            let failure=(error as? VideoError) ?? .unavailable("原生入口未完成；请打开App核对本地工作区，原数据保留")
            return envelope(request:request,state:"failed",error:failure)
        }
    }
    private static func nativeSchema(_ command:String) throws -> AgentValue {
        guard var schema=try AgentContract.inputSchema(command).object,var properties=schema["properties"]?.object else{throw VideoError.invalid("核心能力schema不完整")}
        properties.removeValue(forKey:"principal")
        if command=="script create" {properties["kind"] = .object(["type":.string("string"),"enum":.array([.string(SceneKind.explanation.rawValue)])]);schema["required"] = .array((try AgentContract.describe(command).required+["request_id"]).map(AgentValue.string))}
        schema["properties"] = .object(properties);return .object(schema)
    }
    private static func envelope(request:String,state:String,projectID:String?=nil,revisionID:String?=nil,jobID:String?=nil,result:AgentValue = .null,error:VideoError?=nil) -> AgentValue {
        let failure:AgentValue=error.map{.object(["code":.string($0.code),"message":.string($0.localizedDescription),"retryable":.boolean(false),"next_action":.string($0.code=="revision_conflict" ? "读取原结果；不同内容使用新request_id":"核对schema、ID与工作区权限后重试")])} ?? .null
        return .object(["schema_version":.string(AgentContract.version),"request_id":.string(request),"ok":.boolean(error == nil),"state":.string(state),"project_id":projectID.map(AgentValue.string) ?? .null,"revision":revisionID.map(AgentValue.string) ?? .null,"job_id":jobID.map(AgentValue.string) ?? .null,"artifacts":.array([]),"result":result,"error":failure,"cost":.object(["currency":.string("CNY"),"estimated":.null,"reserved":.null,"actual":.null,"unknown":.string("此原生操作不生成付费请求；任务实耗请在App对账")])])
    }
}
