import Foundation

/// Foundation-only JSON values keep the public SDK independent of any particular agent or App.
public indirect enum AgentValue: Codable, Equatable, Sendable {
    case string(String), number(Decimal), boolean(Bool), array([AgentValue]), object([String: AgentValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .boolean(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([AgentValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: AgentValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .boolean(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var object: [String: AgentValue]? { if case .object(let v) = self { return v }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
}

public enum AgentPermission: String, Codable, Sendable {
    case discovery, workspaceOwner, projectRead, projectWrite, projectReview
}
public struct AgentCommand: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String; public var required: [String]; public var optional: [String]
    public var permission: AgentPermission; public var writes: Bool; public var network: Bool
    /// Precise existing behavior; filesystem/process operations are not SQL transactions.
    public var idempotency: String
    public init(_ name: String, required: [String] = [], optional: [String] = [], permission: AgentPermission = .workspaceOwner, writes: Bool = false, network: Bool = false, idempotency: String = "read_only") {
        self.name = name; self.required = required; self.optional = optional; self.permission = permission
        self.writes = writes; self.network = network; self.idempotency = idempotency
    }
}
public struct AgentReplayRecord: Codable, Equatable, Sendable {
    public var requestID: String; public var command: String; public var fingerprint: String
    public var response: AgentValue; public var createdAt: Date
    public init(requestID: String, command: String, fingerprint: String, response: AgentValue, createdAt: Date = Date()) { self.requestID = requestID; self.command = command; self.fingerprint = fingerprint; self.response = response; self.createdAt = createdAt }
}
public enum AgentReplayDecision: Equatable, Sendable { case execute, replay(AgentValue) }

public enum AgentContract {
    public static let version = "1.0"
    public static let commands: [AgentCommand] = [
        AgentCommand("doctor", permission: .discovery), AgentCommand("schema", permission: .discovery), AgentCommand("capabilities", permission: .discovery),
        AgentCommand("workspaces create", required: ["name"], writes: true, idempotency: "atomic_database_request_receipt"),
        AgentCommand("products import", required: ["workspace_id", "product"], writes: true, idempotency: "atomic_database_request_receipt"),
        AgentCommand("products list", required: ["workspace_id"]),
        AgentCommand("assets import",required:["workspace_id","path"],optional:["evidence_id"],writes:true,idempotency:"workspace_content_hash"),
        AgentCommand("assets list",required:["workspace_id"]),
        AgentCommand("evidence add", required: ["workspace_id", "evidence"], writes: true, idempotency: "atomic_database_request_receipt"),
        AgentCommand("projects list", required: ["workspace_id"]),
        AgentCommand("projects facts-impact", required: ["workspace_id", "project_id"]),
        AgentCommand("knowledge compare", required: ["workspace_id", "project_id", "base_revision", "scene_id", "comparison_scene_id"], permission: .projectRead),
        AgentCommand("projects create",required:["workspace_id","name"],optional:["aspect","scenes"],writes:true,idempotency:"atomic_database_request_receipt"),
        AgentCommand("script create", required: ["workspace_id", "knowledge", "demonstration", "hook"], optional: ["product_id", "name", "purpose", "aspect", "kind", "evidence_ids"], writes: true, idempotency: "atomic_database_request_receipt"),
        AgentCommand("speech voices", permission: .discovery),
        AgentCommand("speech normalize", required:["text"],optional:["dictionary"],permission:.discovery),
        AgentCommand("speech attach",required:["workspace_id","project_id","scene_id","base_revision","asset_id","speech_plan","request_id"],optional:["extend_scene","timeout_seconds"],permission:.projectWrite,writes:true,idempotency:"confirmed_imported_audio_atomic_revision_receipt"),
        AgentCommand("speech synthesize",required:["workspace_id","project_id","scene_id","base_revision","speech_plan","request_id"],optional:["extend_scene","timeout_seconds"],permission:.projectWrite,writes:true,idempotency:"confirmed_input_atomic_revision_receipt_local_speech"),
        AgentCommand("edit apply", required: ["workspace_id", "project_id", "base_revision", "edits"], optional: ["text"], permission: .projectWrite, writes: true, idempotency: "atomic_database_request_receipt"),
        AgentCommand("review record", required: ["workspace_id", "project_id", "base_revision", "review"], permission: .projectReview, writes: true, idempotency: "atomic_database_request_receipt"),
        AgentCommand("production export", required: ["workspace_id", "project_id", "base_revision", "job_id", "path", "request_id"], writes: true, idempotency: "exclusive_named_directory_no_overwrite_no_request_replay"),
        AgentCommand("render estimate", required: ["workspace_id", "project_id"], optional: ["estimate", "text"], permission: .projectRead),
        AgentCommand("render submit", required: ["workspace_id", "project_id", "quote", "request_id"], optional: ["budget"], permission: .projectWrite, writes: true, idempotency: "frozen_job_request_key"),
        AgentCommand("jobs status", required: ["workspace_id", "job_id"], permission: .projectRead),
        AgentCommand("jobs run", required: ["workspace_id", "job_id"], permission: .projectWrite, writes: true, idempotency: "claim_original_job_lease"),
        AgentCommand("jobs cancel", required: ["workspace_id", "job_id"], permission: .projectWrite, writes: true, idempotency: "original_job_state_transition"),
        AgentCommand("jobs resume", required: ["workspace_id", "job_id"], permission: .projectWrite, writes: true, idempotency: "original_job_state_transition"),
        AgentCommand("jobs query", required: ["workspace_id", "job_id"], permission: .projectWrite, writes: true, network: true, idempotency: "query_original_remote_id_never_resubmit"),
        AgentCommand("jobs remote-cancel", required: ["workspace_id", "job_id"], permission: .projectWrite, writes: true, network: true, idempotency: "cancel_original_remote_id_no_refund_promise"),
        AgentCommand("baidu submit",required:["workspace_id","project_id","profile_id","baidu_input","quote","request_id"],writes:true,network:true,idempotency:"frozen_original_request_never_resubmit_unknown"),
        AgentCommand("baidu query",required:["workspace_id","job_id"],writes:true,network:true,idempotency:"query_original_baidu_string_id"),
        AgentCommand("baidu collect",required:["workspace_id","job_id"],writes:true,network:true,idempotency:"original_id_to_cas_asset_no_regeneration"),
        AgentCommand("worker run", required:["workspace_id"],optional:["job_ids","max_jobs","timeout_seconds","resume_interrupted","query_remote","worker_id"],writes:true,network:true,idempotency:"finite_batch_original_job_leases_no_remote_submission"),
        AgentCommand("worker launch", required:["workspace_id","request_id"],optional:["job_ids","max_jobs","timeout_seconds","resume_interrupted","query_remote"],writes:true,network:true,idempotency:"local_ticket_receipt_process_launch_non_atomic"),
        AgentCommand("worker status", required:["workspace_id","worker_id"]),
        AgentCommand("worker stop", required:["workspace_id","worker_id"],writes:true,idempotency:"stop_marker_invalidates_only_owned_leases"),
        AgentCommand("jobs reconcile", required: ["workspace_id", "job_id", "billing_record"], writes: true, idempotency: "billing_record_id"),
        AgentCommand("orders import", required: ["workspace_id", "batch_id", "orders"], writes: true, idempotency: "atomic_database_request_receipt"),
        AgentCommand("metrics import", required: ["workspace_id", "batch_id", "metrics"], writes: true, idempotency: "atomic_database_request_receipt"),
        AgentCommand("imports rollback", required: ["workspace_id", "batch_id"], writes: true, idempotency: "atomic_database_request_receipt"),
        AgentCommand("reports contribution", required: ["workspace_id"], optional: ["baseline"]),
        AgentCommand("backup create", writes: true, idempotency: "filesystem_export_non_atomic_no_request_replay"),
        AgentCommand("backup restore", required: ["path"], writes: true, idempotency: "new_directory_only_no_overwrite"),
        AgentCommand("publications record", required: ["workspace_id", "publication"], writes: true, idempotency: "atomic_database_request_receipt"),
        AgentCommand("sales record", required: ["workspace_id", "sale"], writes: true, idempotency: "atomic_database_request_receipt"),
        AgentCommand("brands record", required: ["workspace_id", "deal"], writes: true, idempotency: "atomic_database_request_receipt"),
        AgentCommand("expenses record", required: ["workspace_id", "expense"], writes: true, idempotency: "atomic_database_request_receipt"),
        AgentCommand("cash record", required: ["workspace_id", "cash"], writes: true, idempotency: "atomic_database_request_receipt")
    ]
    private static let common = ["principal", "request_id"]
    private static let objectFields: Set<String> = ["speech_plan", "product", "evidence", "review", "quote", "budget", "publication", "sale", "deal", "expense", "cash", "baseline", "estimate", "billing_record", "baidu_input"]
    private static let arrayFields: Set<String> = ["evidence_ids", "edits", "orders", "metrics", "job_ids", "scenes", "dictionary"]
    public static func describe(_ command: String) throws -> AgentCommand {
        guard let descriptor = commands.first(where: { $0.name == command }) else { throw VideoError.invalid("未知命令，请用schema发现受支持命令") }; return descriptor
    }
    /// Performs side-effect-free outer DTO validation before repository creation or dry-run.
    /// Entity Codable decoding and domain validate() remain authoritative for nested business fields.
    @discardableResult public static func validate(command: String, data: Data) throws -> [String: AgentValue] {
        let descriptor = try describe(command)
        guard data.count <= 10 * 1024 * 1024 else { throw VideoError.invalid("Agent输入超过10MiB") }
        let value: AgentValue
        do { value = try Codec.decoder().decode(AgentValue.self, from: data) }
        catch { throw VideoError.invalid("输入须为合法JSON对象；不接受交互式提示") }
        guard let object = value.object else { throw VideoError.invalid("输入根节点须为JSON对象") }
        let allowed = Set(descriptor.required + descriptor.optional + common)
        guard Set(object.keys).isSubset(of: allowed) else { throw VideoError.invalid("输入存在当前命令不支持的字段，请查询schema") }
        for field in descriptor.required {
            guard let value = object[field], value != .null else { throw VideoError.invalid("缺少必填字段：" + field) }
        }
        for (key, value) in object where value != .null {
            if objectFields.contains(key) { guard value.object != nil else { throw VideoError.invalid(key + "须为对象") } }
            else if arrayFields.contains(key) {
                guard case .array(let values) = value, !descriptor.required.contains(key) || !values.isEmpty else { throw VideoError.invalid(key + "须为数组且必填数组不能为空") }
                if key == "evidence_ids" || key == "job_ids" { guard values.allSatisfy({ $0.string != nil && !($0.string?.isEmpty ?? true) }) else { throw VideoError.invalid(key+"须为非空字符串数组") } }
                else { guard values.allSatisfy({ $0.object != nil }) else { throw VideoError.invalid(key + "须为对象数组") } }
            } else if ["max_jobs","timeout_seconds"].contains(key) {
                guard case .number(let n)=value,n==Decimal(NSDecimalNumber(decimal:n).intValue),(key=="max_jobs" ? Decimal(1)...Decimal(25):Decimal(5)...Decimal(command.hasPrefix("speech ") ? 900:3600)).contains(n) else{throw VideoError.invalid(key+"须为范围内整数")}
            } else if ["resume_interrupted","query_remote","extend_scene"].contains(key) {
                guard case .boolean = value else{throw VideoError.invalid(key+"须为布尔值")}
            } else {
                guard let text = value.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VideoError.invalid(key + "须为非空字符串") }
                if key.hasSuffix("_id") || key == "base_revision" { guard text.utf8.count <= 200, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw VideoError.invalid("标识过长或含控制字符") } }
            }
        }
        if command == "production export" {
            let path = object["path"]?.string ?? ""
            guard path.hasPrefix("/"), path.utf8.count <= 4096,
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw VideoError.invalid("导出path须为调用者明确选择的本机绝对目录路径，且不含控制字符")
            }
        }
        var count = 0; try validateTree(value, depth: 0, count: &count)
        if let p = object["purpose"]?.string, !Purpose.allCases.map(\.rawValue).contains(p) { throw VideoError.invalid("purpose不在支持范围") }
        if let p = object["aspect"]?.string, !Aspect.allCases.map(\.rawValue).contains(p) { throw VideoError.invalid("aspect不在支持范围") }
        if let p = object["kind"]?.string, !SceneKind.allCases.map(\.rawValue).contains(p) { throw VideoError.invalid("kind不在支持范围") }
        return object
    }
    private static func validateTree(_ value: AgentValue, depth: Int, count: inout Int) throws {
        count += 1; guard depth <= 64, count <= 200_000 else { throw VideoError.invalid("Agent输入嵌套层级或元素数量过多") }
        switch value {
        case .object(let values):
            let prohibited: Set<String> = ["password", "passwd", "api_key", "apikey", "access_token", "refresh_token", "authorization", "cookie", "cookies", "secret", "private_key"]
            for (key, child) in values { guard !prohibited.contains(key.lowercased()) else { throw VideoError.permission("不得通过工程/Agent输入传递凭据，请在系统Keychain或宿主安全配置中绑定引用") }; try validateTree(child, depth: depth + 1, count: &count) }
        case .array(let values): for child in values { try validateTree(child, depth: depth + 1, count: &count) }
        default: break
        }
    }
    public static func authorize(command: String, workspace: Workspace, principal: String, projectID: String? = nil, revisionID: String? = nil, now: Date = Date()) throws {
        let permission = try describe(command).permission
        if principal == workspace.owner { return }
        switch permission {
        case .discovery: return
        case .workspaceOwner: guard principal == workspace.owner else { throw VideoError.permission("此命令仅限工作区所有者，不向协作者暴露全库或财务") }
        case .projectRead, .projectWrite, .projectReview:
            guard let projectID, let revisionID else { throw VideoError.permission("受限Agent必须绑定实际项目与指定版本，不能按空范围访问") }
            try workspace.authorize(principal: principal, project: projectID, revision: revisionID, write: permission == .projectWrite, now: now)
        }
    }
    public static func fingerprint(command: String, data: Data) throws -> String {
        var object = try validate(command: command, data: data); object.removeValue(forKey: "request_id")
        return try Codec.digest(AgentValue.object(["command": .string(command), "input": .object(object), "protocol": .string(version)]))
    }
    public static func replay(command: String, data: Data, records: [AgentReplayRecord]) throws -> AgentReplayDecision {
        let values = try validate(command: command, data: data)
        guard let request = values["request_id"]?.string else { return .execute }
        let matching = records.filter { $0.requestID == request }
        guard matching.count <= 1 else { throw VideoError.conflict("幂等回执重复，请修复账本，不得重复执行") }
        guard let record = matching.first else { return .execute }
        guard record.command == command, record.fingerprint == (try fingerprint(command: command, data: data)) else { throw VideoError.conflict("request_id已用于不同命令或内容；请核对原结果，不能复用为新操作") }
        return .replay(record.response)
    }
    public static func inputSchema(_ command: String) throws -> AgentValue {
        let descriptor = try describe(command)
        let fields = Set(descriptor.required + descriptor.optional + common)
        var properties: [String: AgentValue] = [:]
        for field in fields {
            var shape: [String: AgentValue]
            if let type=AgentSchemas.fieldTypes[field] {shape=AgentSchemas.shape(type).object ?? [:]}
            else if ["max_jobs","timeout_seconds"].contains(field) {shape=["type":.string("integer"),"minimum":.number(field=="max_jobs" ? 1:5),"maximum":.number(field=="max_jobs" ? 25:(command.hasPrefix("speech ") ? 900:3600)),"default":.number(field=="max_jobs" ? 5:(command.hasPrefix("speech ") ? 180:300))]}
            else if ["resume_interrupted","query_remote","extend_scene"].contains(field) {shape=["type":.string("boolean"),"default":.boolean(false)]}
            else {shape=["type":.string("string"),"minLength":.number(1)]}
            if field == "purpose" { shape["enum"] = .array(Purpose.allCases.map { .string($0.rawValue) }) }
            if field == "aspect" { shape["enum"] = .array(Aspect.allCases.map { .string($0.rawValue) }) }
            if field == "kind" { shape["enum"] = .array(SceneKind.allCases.map { .string($0.rawValue) }) }
            properties[field] = .object(shape)
        }
        return .object(["$schema": .string("https://json-schema.org/draft/2020-12/schema"), "type": .string("object"), "properties": .object(properties), "$defs":.object(AgentSchemas.definitions()), "required": .array(descriptor.required.map(AgentValue.string)), "additionalProperties": .boolean(false)])
    }
    public static func catalog() throws -> AgentValue {
        let descriptions = try commands.map { command -> AgentValue in
            .object(["name": .string(command.name), "input_schema": try inputSchema(command.name), "permission": .string(command.permission.rawValue), "writes": .boolean(command.writes), "network": .boolean(command.network), "idempotency": .string(command.idempotency), "dry_run": .boolean(command.writes), "noninteractive": .boolean(true)])
        }
        return .object(["schema_version": .string(version), "ir_schema_versions":.array([.number(1),.number(2)]), "project_formats":.object(["1":.string("legacy_product_snapshot; original encoded product facts and digest preserved"),"2":.string("contentContext without product; ordinary editing and teaching; older tools must upgrade before opening")]), "commands": .array(descriptions), "limits": .object(["max_input_bytes": .number(10 * 1024 * 1024), "max_depth": .number(64), "max_nodes": .number(200000)]), "exit_codes": .object(["0": .string("成功或已接受；仍需检查state"), "2": .string("输入/未找到"), "3": .string("缺权限"), "4": .string("预算"), "5": .string("待审核"), "6": .string("版本/幂等冲突"), "8": .string("外部条件不确定；先查原任务")])])
    }
}

public enum AgentExecutionSurface: String, Codable, Sendable { case localShell, restrictedSandbox, remoteConnector, chatOnly }
public struct AgentHostRoute: Codable, Equatable, Sendable {
    public var ecosystem: String; public var host: String; public var surface: AgentExecutionSurface
    public var source: String; public var installEvidence: String?
    public init(ecosystem: String, host: String, surface: AgentExecutionSurface, source: String, installEvidence: String? = nil) { self.ecosystem = ecosystem; self.host = host; self.surface = surface; self.source = source; self.installEvidence = installEvidence }
    public func requireExecution(shellAvailable: Bool, authenticatedConnector: Bool, compatibleRuntime: Bool) throws {
        switch surface {
        case .localShell: guard shellAvailable, compatibleRuntime else { throw VideoError.unavailable("此宿主需要可执行video CLI的Apple运行时与shell；模型API不提供本机执行能力") }
        case .remoteConnector: guard authenticatedConnector else { throw VideoError.permission("需用户配置且已认证的受限连接器；不得暴露无认证本地服务") }
        case .restrictedSandbox: throw VideoError.unavailable("受限沙箱仅可使用其允许的素材/结果交接；当前原生CLI未声明支持该运行时")
        case .chatOnly: throw VideoError.unavailable("当前聊天界面没有工程执行工具，不能把文案回复称作已生成视频")
        }
    }
}
