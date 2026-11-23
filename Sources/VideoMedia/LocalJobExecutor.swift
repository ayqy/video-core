import Foundation
import VideoCore

/// Lease liveness is independent of visual progress. One claimed invocation owns this
/// task, and its caller joins stop() before finishing or handling a failed render.
/// The short interval is internal for isolated rules, never a runtime flag or TTL change.
final class LocalJobKeepalive: @unchecked Sendable {
    private struct Stopped: Error {}
    private let repository: Repository
    private let invocation: RenderInvocation
    private let token: String
    private let interval: UInt64
    private let lock = NSLock()
    private var stopped = false
    private var firstFailure: Error?
    private var task: Task<Void, Never>?

    init(repository: Repository, invocation: RenderInvocation, token: String, interval: TimeInterval = 30) throws {
        guard interval.isFinite, (0.001...30).contains(interval), invocation.jobID != nil, !token.isEmpty else {
            throw VideoError.invalid("本地任务续租须绑定已认领范围及有界间隔")
        }
        self.repository = repository; self.invocation = invocation; self.token = token
        self.interval = UInt64(interval * 1_000_000_000)
        task = Task.detached(priority: .utility) { [self] in await run() }
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return firstFailure }
    /// Never hold the state lock while waiting for the repository or task. A cancellation
    /// requested by a caller holding a database lock must not invert the lock order.
    func cancel() {
        lock.lock(); stopped = true; lock.unlock()
        task?.cancel()
    }
    func stop() async -> Error? {
        cancel()
        await task?.value
        return failure
    }
    private func fail(_ error: Error) {
        lock.lock()
        if firstFailure == nil { firstFailure = error }
        stopped = true
        lock.unlock()
        invocation.cancellation.cancel()
    }
    private func run() async {
        while !isStopped {
            do {
                try await Task.sleep(nanoseconds: interval)
                guard !isStopped else { return }
                try repository.nativeJobTransaction { _, jobs in
                    guard !isStopped else { throw Stopped() }
                    // Repository has a recursive lock and an active SQLite write
                    // transaction here. This original authorization reads the same
                    // frozen snapshot, so budget/token changes cannot race the renewal.
                    try invocation.check()
                    guard !isStopped else { throw Stopped() }
                    guard let index = jobs.firstIndex(where: { $0.id == invocation.jobID }) else {
                        throw VideoError.notFound("原制作任务不存在，停止续租")
                    }
                    jobs[index] = try JobOperations.heartbeat(jobs[index], token: token, progress: jobs[index].progress)
                }
            } catch is Stopped {
                return
            } catch {
                // Cancelling our own sleep/check during normal stop is not an
                // authorization error. Other errors survive even if stop raced them.
                if error is CancellationError && isStopped { return }
                fail(error)
                return
            }
        }
    }
}

/// One backend for UI, free CLI and the independent premium Host.
public enum LocalJobExecutor {
    public static func run(repository:Repository,jobID:String,owner:String,modules:RenderModuleRegistry?=nil,videoEncoder:NativeEncoderSelection = .automatic,progress:@escaping @Sendable(Double)->Void={_ in}) async throws -> Job {
        let claimed:(Job,Revision)=try repository.nativeJobTransaction { state, jobs in
            for i in jobs.indices where jobs[i].quote.provider == "native" { jobs[i]=JobOperations.recoverExpired(jobs[i]) }
            guard let index=jobs.firstIndex(where:{$0.id==jobID}) else { throw VideoError.notFound("原任务不存在") }
            guard !jobs.contains(where:{$0.state == .running && $0.quote.provider=="native"}) else { throw VideoError.unavailable("已有本地任务执行中，请等待或取消原任务") }
            let p=try state.project(jobs[index].projectID)
            guard p.workspaceID==jobs[index].workspaceID,let r=p.revisions.first(where:{$0.id==jobs[index].revisionID}),
                  try repository.readWithRevisionDigest(projectID:p.id,revisionID:r.id).digest == jobs[index].digest else {throw VideoError.conflict("冻结版本或任务摘要不一致")}
            var current=state;current.jobs=jobs
            let issues=try Quality.inspect(r,database:current,requireReview:false);guard issues.isEmpty else {throw VideoError.review(issues.map(\.message).joined(separator:"；"))}
            try BatchRules.validateSubmission(project:p,quote:jobs[index].quote,batches:state.topicBatches ?? [],existingJobs:jobs,requestKey:jobs[index].requestKey)
            try TeachingBatchRules.validateSubmission(project:p,quote:jobs[index].quote,batches:state.teachingBatches ?? [],existingJobs:jobs,requestKey:jobs[index].requestKey)
            for s in r.scenes where RenderModuleRegistry.capability(for:s.kind) != nil {guard let modules else{throw VideoError.unavailable("当前执行端未安装有效高级能力，请使用独立高级Host或改用免费图文")};_ = try modules.validate(scene:s)}
            jobs[index]=try JobOperations.claim(jobs[index],owner:owner)
            return(jobs[index],r)
        }
        let token=claimed.0.lease!.token
        let cancellation=RenderCancellation()
        var scope:RenderInvocation?
        var keepalive:LocalJobKeepalive?
        do {
            let invocation=try RenderInvocation.job(repository:repository,claimed:claimed.0,revision:claimed.1,token:token,cancellation:cancellation)
            scope=invocation
            let heartbeat=try LocalJobKeepalive(repository:repository,invocation:invocation,token:token)
            keepalive=heartbeat
            let result=try await withTaskCancellationHandler(operation: {
                try await render(repository:repository,jobID:jobID,revision:claimed.1,token:token,modules:modules,videoEncoder:videoEncoder,invocation:invocation,progress:progress)
            }, onCancel: { cancellation.cancel();heartbeat.cancel() })
            if let failure=await heartbeat.stop(){throw failure}
            try invocation.check()
            return try repository.nativeJobTransaction { _,jobs in try invocation.check();guard let i=jobs.firstIndex(where:{$0.id==jobID}) else {throw VideoError.notFound("原任务不存在")};jobs[i]=try JobOperations.finish(jobs[i],token:token,artifacts:result.artifacts);jobs[i].message=result.warnings.joined(separator:"；");return jobs[i] }
        } catch {
            var failure=error
            if let keepalive,let heartbeatFailure=await keepalive.stop(){failure=heartbeatFailure}
            cancellation.cancel()
            if let scope { try? modules?.close(invocationID:scope.id) }
            try? repository.nativeJobTransaction { _,jobs in guard let i=jobs.firstIndex(where:{$0.id==jobID}),jobs[i].state == .running,jobs[i].lease?.token==token else{return};jobs[i].lease=nil;jobs[i].state=failure is CancellationError ? .cancelled:.interrupted;jobs[i].message=(failure as? VideoError)?.localizedDescription ?? "本地制作中断，工程与已校验缓存保留，可沿原任务恢复" }
            throw failure
        }
    }
    private static func render(repository:Repository,jobID:String,revision:Revision,token:String,modules:RenderModuleRegistry?,videoEncoder:NativeEncoderSelection,invocation:RenderInvocation,progress:@escaping @Sendable(Double)->Void) async throws -> RenderResult {
        let result=try await MediaRenderer(modules:modules,videoEncoder:videoEncoder).render(revision:revision,repository:repository,output:repository.root.appendingPathComponent("exports/"+jobID),invocation:invocation) { value in
                try reportProgress(value,repository:repository,jobID:jobID,token:token,invocation:invocation,progress:progress)
            }
        return result
    }

    /// Replaying an already sealed interval still checks the live scope and
    /// reports its raw progress. Only a new persisted high-water mark needs a
    /// full snapshot write; the independent keepalive owns silent renewal.
    static func reportProgress(_ value:Double,repository:Repository,jobID:String,token:String,invocation:RenderInvocation,progress:@Sendable(Double)->Void) throws {
        try invocation.check()
        guard invocation.jobID==jobID else {throw VideoError.permission("制作进度不属于原任务范围")}
        try ManagedInstallRules.authorizeWrite(repositoryRoot:repository.root)
        let database=try repository.read()
        guard let current=database.jobs.first(where:{$0.id==jobID}) else {throw VideoError.notFound("原任务不存在")}
        // Keep the original token/state/expiry and finite-range guards even
        // when no write is needed. Never use a renderer-local progress cache.
        _ = try JobOperations.heartbeat(current,token:token,progress:value)
        if value>current.progress {
            try repository.nativeJobTransaction { _, jobs in
                try invocation.check()
                guard let i=jobs.firstIndex(where:{$0.id==jobID}) else {throw VideoError.notFound("原任务不存在")}
                jobs[i]=try JobOperations.heartbeat(jobs[i],token:token,progress:value)
            }
        }
        try invocation.check()
        try ManagedInstallRules.authorizeWrite(repositoryRoot:repository.root)
        progress(value)
        // A caller may cancel or revoke this scope from its callback. Do not
        // let the no-write branch hide that failure from the renderer.
        try invocation.check()
        try ManagedInstallRules.authorizeWrite(repositoryRoot:repository.root)
    }
}
