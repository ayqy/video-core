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
                try repository.transaction { database in
                    guard !isStopped else { throw Stopped() }
                    // Repository has a recursive lock and an active SQLite write
                    // transaction here. This original authorization reads the same
                    // frozen snapshot, so budget/token changes cannot race the renewal.
                    try invocation.check()
                    guard !isStopped else { throw Stopped() }
                    guard let index = database.jobs.firstIndex(where: { $0.id == invocation.jobID }) else {
                        throw VideoError.notFound("原制作任务不存在，停止续租")
                    }
                    database.jobs[index] = try JobOperations.heartbeat(database.jobs[index], token: token, progress: database.jobs[index].progress)
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
    public static func run(repository:Repository,jobID:String,owner:String,modules:RenderModuleRegistry?=nil,progress:@escaping @Sendable(Double)->Void={_ in}) async throws -> Job {
        let claimed:(Job,Revision)=try repository.transaction { db in
            for i in db.jobs.indices { db.jobs[i]=JobOperations.recoverExpired(db.jobs[i]) }
            guard let index=db.jobs.firstIndex(where:{$0.id==jobID}) else { throw VideoError.notFound("原任务不存在") }
            guard !db.jobs.contains(where:{$0.state == .running && $0.quote.provider=="native"}) else { throw VideoError.unavailable("已有本地任务执行中，请等待或取消原任务") }
            let p=try db.project(db.jobs[index].projectID)
            guard p.workspaceID==db.jobs[index].workspaceID,let r=p.revisions.first(where:{$0.id==db.jobs[index].revisionID}),try r.contentDigest()==db.jobs[index].digest else {throw VideoError.conflict("冻结版本或任务摘要不一致")}
            let issues=try Quality.inspect(r,database:db,requireReview:false);guard issues.isEmpty else {throw VideoError.review(issues.map(\.message).joined(separator:"；"))}
            try BatchRules.validateSubmission(project:p,quote:db.jobs[index].quote,batches:db.topicBatches ?? [],existingJobs:db.jobs,requestKey:db.jobs[index].requestKey)
            try TeachingBatchRules.validateSubmission(project:p,quote:db.jobs[index].quote,batches:db.teachingBatches ?? [],existingJobs:db.jobs,requestKey:db.jobs[index].requestKey)
            for s in r.scenes where RenderModuleRegistry.capability(for:s.kind) != nil {guard let modules else{throw VideoError.unavailable("当前执行端未安装有效高级能力，请使用独立高级Host或改用免费图文")};_ = try modules.validate(kind:s.kind)}
            db.jobs[index]=try JobOperations.claim(db.jobs[index],owner:owner)
            return(db.jobs[index],r)
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
                try await render(repository:repository,jobID:jobID,revision:claimed.1,token:token,modules:modules,invocation:invocation,progress:progress)
            }, onCancel: { cancellation.cancel();heartbeat.cancel() })
            if let failure=await heartbeat.stop(){throw failure}
            try invocation.check()
            return try repository.transaction { db in try invocation.check();guard let i=db.jobs.firstIndex(where:{$0.id==jobID}) else {throw VideoError.notFound("原任务不存在")};db.jobs[i]=try JobOperations.finish(db.jobs[i],token:token,artifacts:result.artifacts);db.jobs[i].message=result.warnings.joined(separator:"；");return db.jobs[i] }
        } catch {
            var failure=error
            if let keepalive,let heartbeatFailure=await keepalive.stop(){failure=heartbeatFailure}
            cancellation.cancel()
            if let scope { try? modules?.close(invocationID:scope.id) }
            try? repository.transaction { db in guard let i=db.jobs.firstIndex(where:{$0.id==jobID}),db.jobs[i].state == .running,db.jobs[i].lease?.token==token else{return};db.jobs[i].lease=nil;db.jobs[i].state=failure is CancellationError ? .cancelled:.interrupted;db.jobs[i].message=(failure as? VideoError)?.localizedDescription ?? "本地制作中断，工程与已校验缓存保留，可沿原任务恢复" }
            throw failure
        }
    }
    private static func render(repository:Repository,jobID:String,revision:Revision,token:String,modules:RenderModuleRegistry?,invocation:RenderInvocation,progress:@escaping @Sendable(Double)->Void) async throws -> RenderResult {
        let result=try await MediaRenderer(modules:modules).render(revision:revision,repository:repository,output:repository.root.appendingPathComponent("exports/"+jobID),invocation:invocation) { value in
                try repository.transaction { db in guard let i=db.jobs.firstIndex(where:{$0.id==jobID}) else {throw VideoError.notFound("原任务不存在")};db.jobs[i]=try JobOperations.heartbeat(db.jobs[i],token:token,progress:value) }
                progress(value)
            }
        return result
    }
}
