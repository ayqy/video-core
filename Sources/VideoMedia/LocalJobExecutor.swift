import Foundation
import VideoCore

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
        do {
            let result=try await MediaRenderer(modules:modules).render(revision:claimed.1,repository:repository,output:repository.root.appendingPathComponent("exports/"+jobID)) { value in
                try repository.transaction { db in guard let i=db.jobs.firstIndex(where:{$0.id==jobID}) else {throw VideoError.notFound("原任务不存在")};db.jobs[i]=try JobOperations.heartbeat(db.jobs[i],token:token,progress:value) }
                progress(value)
            }
            return try repository.transaction { db in guard let i=db.jobs.firstIndex(where:{$0.id==jobID}) else {throw VideoError.notFound("原任务不存在")};db.jobs[i]=try JobOperations.finish(db.jobs[i],token:token,artifacts:result.artifacts);db.jobs[i].message=result.warnings.joined(separator:"；");return db.jobs[i] }
        } catch {
            try? repository.transaction { db in guard let i=db.jobs.firstIndex(where:{$0.id==jobID}),db.jobs[i].state == .running,db.jobs[i].lease?.token==token else{return};db.jobs[i].lease=nil;db.jobs[i].state=error is CancellationError ? .cancelled:.interrupted;db.jobs[i].message=(error as? VideoError)?.localizedDescription ?? "本地制作中断，工程与已校验缓存保留，可沿原任务恢复" }
            throw error
        }
    }
}
