import Foundation
import Darwin
import VideoCore
import VideoMedia

struct WorkerOutcome:Codable,Sendable {var jobID:String;var state:String;var note:String}
struct WorkerTicket:Codable,Sendable {
    var id:String;var requestID:String;var principal:String;var plan:AgentWorkerPlan;var fingerprint:String
    var state:String;var createdAt:Date;var updatedAt:Date;var deadline:Date?;var pid:Int32?;var outcomes:[WorkerOutcome]
}

/// Local control records contain no input prose, credentials or financial rows.
/// A launch is intentionally a filesystem/process operation, not an SQL transaction.
final class WorkerStore:@unchecked Sendable {
    let directory:URL;private let mutex=NSLock()
    init(root:URL,create:Bool=true)throws {
        directory=root.appendingPathComponent(".workers",isDirectory:true)
        if FileManager.default.fileExists(atPath:directory.path) {let info=try directory.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey]);guard info.isSymbolicLink != true,info.isDirectory==true else{throw VideoError.permission("worker目录不能是符号链接或普通文件")}}
        else if create {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
        else{throw VideoError.notFound("此工程还没有worker控制记录")}
        guard directory.resolvingSymlinksInPath().deletingLastPathComponent()==root.resolvingSymlinksInPath() else{throw VideoError.permission("worker目录超出工程")}
    }
    func url(_ id:String,_ ext:String="worker")throws->URL {guard id.range(of:"^[a-f0-9]{32}$",options:.regularExpression) != nil else{throw VideoError.invalid("worker_id须为返回的32位标识")};let u=directory.appendingPathComponent(id+"."+ext);if FileManager.default.fileExists(atPath:u.path){let s=try u.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey]);guard s.isSymbolicLink != true,s.isRegularFile==true,(s.fileSize ?? 0)<1_048_576 else{throw VideoError.permission("worker控制文件不安全或过大")}};return u}
    private func synchronized<T>(_ id:String,_ body:()throws->T)throws->T {
        mutex.lock();defer{mutex.unlock()}
        let fd=open(try url(id,"state-lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600);guard fd>=0 else{throw VideoError.permission("不能协调worker控制状态")};defer{close(fd)}
        guard flock(fd,LOCK_EX)==0 else{throw VideoError.unavailable("不能读取worker控制状态")};defer{flock(fd,LOCK_UN)}
        return try body()
    }
    func read(_ id:String)throws->WorkerTicket {try synchronized(id){try PropertyListDecoder().decode(WorkerTicket.self,from:Data(contentsOf:url(id)))}}
    func update(_ id:String,_ body:(inout WorkerTicket)throws->Void)throws->WorkerTicket {try synchronized(id){let u=try url(id);var ticket=try PropertyListDecoder().decode(WorkerTicket.self,from:Data(contentsOf:u));try body(&ticket);ticket.updatedAt=Date();try write(ticket,to:u);return ticket}}
    func create(_ ticket:WorkerTicket)throws->Bool {try synchronized(ticket.id){let u=try url(ticket.id);if FileManager.default.fileExists(atPath:u.path){let old=try PropertyListDecoder().decode(WorkerTicket.self,from:Data(contentsOf:u));guard old.fingerprint==ticket.fingerprint,old.principal==ticket.principal,old.plan.workspaceID==ticket.plan.workspaceID else{throw VideoError.conflict("worker request_id已用于不同批次")};return false};try write(ticket,to:u);return true}}
    private func write(_ ticket:WorkerTicket,to url:URL)throws {let encoder=PropertyListEncoder();encoder.outputFormat = .binary;try encoder.encode(ticket).write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
    func stopped(_ id:String)->Bool {(try? url(id,"stop")).map{FileManager.default.fileExists(atPath:$0.path)} ?? true}
    func stop(_ id:String)throws {try Data().write(to:url(id,"stop"),options:.atomic)}
    func lock(_ id:String)throws->Int32 {let fd=open(try url(id,"lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600);guard fd>=0 else{throw VideoError.permission("不能锁定worker控制文件")};guard flock(fd,LOCK_EX|LOCK_NB)==0 else{close(fd);throw VideoError.conflict("该worker已有独立执行进程")};return fd}
}

enum FiniteWorker {
    static func handle(command:String,data:Data,repository:Repository,principal:String,requestID:String) async throws->AgentValue {
        let values=try AgentContract.validate(command:command,data:data),workspaceID=values["workspace_id"]?.string ?? ""
        guard try repository.read().workspace(workspaceID).owner==principal else{throw VideoError.permission("worker仅由当前本机工作区所有者操作")}
        let store=try WorkerStore(root:repository.root,create:command != "worker status")
        if command=="worker status" || command=="worker stop" {
            let id=values["worker_id"]?.string ?? "",ticket=try store.read(id)
            guard ticket.plan.workspaceID==workspaceID,ticket.principal==principal else{throw VideoError.permission("worker不属于此本机身份或工作区")}
            if command=="worker stop" {try store.stop(id);try interrupt(repository:repository,workspaceID:workspaceID,principal:principal,owner:"worker:"+id);_ = try store.update(id){if ["pending","running"].contains($0.state){$0.state="stop_requested"}}}
            return try response(store.read(id),requestID:requestID)
        }
        func integer(_ name:String,_ fallback:Int)->Int {if case .number(let value)=values[name] {return NSDecimalNumber(decimal:value).intValue};return fallback}
        func boolean(_ name:String)->Bool {values[name] == .boolean(true)}
        let ids:[String];if case .array(let list)=values["job_ids"] {ids=list.compactMap(\.string)}else{ids=[]}
        let plan=try AgentWorkerPlan(workspaceID:workspaceID,jobIDs:ids,maximumJobs:integer("max_jobs",5),timeoutSeconds:integer("timeout_seconds",300),resumeInterrupted:boolean("resume_interrupted"),queryRemote:boolean("query_remote"))
        let fingerprint=try Codec.digest(plan),id=String(Codec.hash(Data(requestID.utf8)).prefix(32))
        if let internalID=values["worker_id"]?.string,internalID != id{throw VideoError.conflict("worker_id与原request_id不符")}
        let ticket=WorkerTicket(id:id,requestID:requestID,principal:principal,plan:plan,fingerprint:fingerprint,state:"pending",createdAt:Date(),updatedAt:Date(),deadline:nil,pid:nil,outcomes:[])
        let fresh:Bool
        if let old=try? store.read(id) {guard old.fingerprint==fingerprint,old.principal==principal,old.plan.workspaceID==workspaceID else{throw VideoError.conflict("worker request_id已用于不同批次")};fresh=false}
        else{fresh=try {let creationLock=try store.lock(id);defer{flock(creationLock,LOCK_UN);close(creationLock)};return try store.create(ticket)}()}
        if command=="worker launch" {
            if fresh {
                var childValues=values;childValues["request_id"] = .string(requestID);childValues["principal"] = .string(principal);childValues["worker_id"] = .string(id)
                // Spawn into a new OS session, with no inherited pipes/terminal or
                // parent lifetime. No shell, credential argument, request or log file.
                do{let pid=try spawn(repository:repository,input:Codec.data(AgentValue.object(childValues)));_ = try store.update(id){$0.pid=pid}}
                catch{_ = try? store.update(id){$0.state="launch_failed"};throw VideoError.unavailable("有限worker未能启动；原任务未重新提交")}
            }
            return try response(store.read(id),requestID:requestID)
        }
        let lock=try store.lock(id);defer{flock(lock,LOCK_UN);close(lock)}
        let existing=try store.read(id)
        if store.stopped(id),["pending","running","stop_requested"].contains(existing.state) {return try response(store.update(id){$0.state="stopped"},requestID:requestID)}
        guard ["pending","running"].contains(existing.state) else{return try response(existing,requestID:requestID)}
        if existing.state=="running" {throw VideoError.conflict("原worker异常退出；查原job租约后，用新worker request_id显式续跑")}
        let selected=try plan.select(database:repository.read(),principal:principal),deadline=Date().addingTimeInterval(Double(plan.timeoutSeconds))
        _ = try store.update(id){$0.state="running";$0.deadline=deadline;$0.pid=getpid()}
        defer {try? interrupt(repository:repository,workspaceID:workspaceID,principal:principal,owner:"worker:"+id);if let ticket=try? store.read(id),ticket.state=="running" {_ = try? store.update(id){$0.state="interrupted"}}}
        // The hard bound also covers a blocked native export/provider call. Leases are
        // invalidated first, so a late result cannot overwrite the original job.
        let timer=DispatchSource.makeTimerSource(queue:.global(qos:.utility))
        timer.schedule(deadline:.now()+Double(plan.timeoutSeconds)+2)
        timer.setEventHandler {
            guard let latest=try? store.read(id),["running","stop_requested"].contains(latest.state) else{return}
            try? store.stop(id);try? interrupt(repository:repository,workspaceID:workspaceID,principal:principal,owner:"worker:"+id)
            if let terminal=try? store.update(id,{$0.state="timed_out"}),let output=try? Codec.data(try response(terminal,requestID:requestID)){FileHandle.standardOutput.write(output);FileHandle.standardOutput.write(Data("\n".utf8))}
            _exit(8)
        };timer.resume();defer{timer.cancel()}
        for jobID in selected {
            if store.stopped(id) || Date()>=deadline {break}
            guard try repository.read().workspace(workspaceID).owner==principal else{throw VideoError.permission("工作区所有者已变化，有限worker停止")}
            let job=try repository.read().jobs.first{$0.id==jobID && $0.workspaceID==workspaceID}
            guard let job else{continue}
            do {
                switch plan.action(for:job) {
                case .skip(let note):_ = try store.update(id){$0.outcomes.append(WorkerOutcome(jobID:jobID,state:"skipped",note:note))}
                case .query:
                    let refreshed=try await RemoteJobs.query(repository:repository,workspaceID:workspaceID,jobID:jobID,principal:principal,authorizationCommand:"worker run")
                    let state=refreshed.state.rawValue
                    _ = try store.update(id){$0.outcomes.append(WorkerOutcome(jobID:jobID,state:state,note:"只查询原远端ID/幂等键；未重新提交或免除费用"))}
                case .run:
                    while try repository.read().jobs.contains(where:{$0.quote.provider=="native" && $0.state == .running && ($0.lease?.expiresAt ?? .distantPast)>Date()}) {
                        if store.stopped(id) || Date()>=deadline {break};try await Task.sleep(nanoseconds:250_000_000)
                    }
                    if store.stopped(id) || Date()>=deadline {break}
                    try repository.transaction {db in guard try db.workspace(workspaceID).owner==principal else{throw VideoError.permission("工作区所有者已变化，未恢复原任务")};guard let i=db.jobs.firstIndex(where:{$0.id==jobID && $0.workspaceID==workspaceID}) else{throw VideoError.notFound("原任务不存在")};db.jobs[i]=JobOperations.recoverExpired(db.jobs[i]);if plan.resumeInterrupted && [.interrupted,.failed].contains(db.jobs[i].state){db.jobs[i]=try JobRules.recover(db.jobs[i])}}
                    let result=try await LocalJobExecutor.run(repository:repository,jobID:jobID,owner:"worker:"+id){_ in if store.stopped(id) || Date()>=deadline {try? interrupt(repository:repository,workspaceID:workspaceID,principal:principal,owner:"worker:"+id)}}
                    _ = try store.update(id){$0.outcomes.append(WorkerOutcome(jobID:jobID,state:result.state.rawValue,note:"原任务产物已生成；仍需人工完整看听审核"))}
                }
            } catch {let note=(error as? VideoError)?.localizedDescription ?? "原任务执行中断，未重新提交";_ = try store.update(id){$0.outcomes.append(WorkerOutcome(jobID:jobID,state:(error as? VideoError)?.code ?? "interrupted",note:note))}}
        }
        let stopped=store.stopped(id),expired=Date()>=deadline
        if stopped || expired {try interrupt(repository:repository,workspaceID:workspaceID,principal:principal,owner:"worker:"+id)}
        let terminal=try store.update(id){$0.state=expired ? "timed_out":stopped ? "stopped":"completed"}
        return try response(terminal,requestID:requestID)
    }
    private static func interrupt(repository:Repository,workspaceID:String,principal:String,owner:String)throws {
        // Avoid creating a database generation for a query-only or already-finished worker.
        guard try repository.read().jobs.contains(where:{$0.workspaceID==workspaceID && $0.state == .running && $0.quote.provider=="native" && $0.lease?.owner==owner}) else{return}
        try repository.transaction{db in
            guard try AgentWorkerPlan.interruptOwned(database:&db,owner:owner,workspaceID:workspaceID,principal:principal) else{throw VideoError.conflict("原worker已无可清理租约，未写入数据库")}
        }
    }
    private static func response(_ ticket:WorkerTicket,requestID:String)throws->AgentValue {
        let result=try Codec.decoder().decode(AgentValue.self,from:Codec.data(ticket))
        return AgentMutationExecutor.envelope(requestID:requestID,state:ticket.state,result:result)
    }
    private static func spawn(repository:Repository,input:Data)throws->pid_t {
        let executable=(Bundle.main.executableURL ?? URL(fileURLWithPath:CommandLine.arguments[0])).standardizedFileURL.path
        var descriptors:[Int32]=[0,0];guard pipe(&descriptors)==0 else{throw VideoError.unavailable("不能建立有限worker输入管道")}
        let reader=descriptors[0],writer=descriptors[1];defer{close(reader)}
        let handle=FileHandle(fileDescriptor:writer,closeOnDealloc:true);defer{try? handle.close()}
        var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions)==0 else{throw VideoError.unavailable("不能初始化有限worker进程")};defer{posix_spawn_file_actions_destroy(&actions)}
        guard posix_spawnattr_init(&attributes)==0 else{throw VideoError.unavailable("不能初始化有限worker会话")};defer{posix_spawnattr_destroy(&attributes)}
        let flags=Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes,flags)==0,
              posix_spawn_file_actions_adddup2(&actions,reader,STDIN_FILENO)==0,
              posix_spawn_file_actions_addopen(&actions,STDOUT_FILENO,"/dev/null",O_WRONLY,0)==0,
              posix_spawn_file_actions_addopen(&actions,STDERR_FILENO,"/dev/null",O_WRONLY,0)==0 else{throw VideoError.unavailable("不能隔离有限worker会话与标准输出")}
        let arguments=[executable,"worker","run","--workspace",repository.root.path,"--input","-"]
        let environment=["PATH=/usr/bin:/bin:/usr/sbin:/sbin","LANG=zh_CN.UTF-8"]
        let argv=arguments.map{strdup($0)}+[nil],env=environment.map{strdup($0)}+[nil];defer{for p in argv+env{free(p)}}
        var pid:pid_t=0
        let status=argv.withUnsafeBufferPointer{a in env.withUnsafeBufferPointer{e in posix_spawn(&pid,executable,&actions,&attributes,UnsafeMutablePointer(mutating:a.baseAddress!),UnsafeMutablePointer(mutating:e.baseAddress!))}}
        guard status==0 else{throw VideoError.unavailable("有限worker未启动（系统状态\(status)），原任务未重新提交")}
        try handle.write(contentsOf:input);try handle.close();return pid
    }
}
