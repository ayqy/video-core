import Foundation
import VideoCore

public enum ScriptJobs {
    public static func submit(repository:Repository,workspaceID:String,projectID:String,profileID:String,evidenceIDs:Set<String>,brief:String,quote:Quote,requestKey:String,principal:String)async throws->Job {
        let snapshot=try repository.read()
        guard try snapshot.workspace(workspaceID).owner==principal,
              let profile=snapshot.providers.first(where:{$0.id==profileID}) else{throw VideoError.permission("本机服务或工作区权限不可用")}
        let project=try snapshot.project(projectID)
        let evidence=snapshot.evidence.filter{evidenceIDs.contains($0.id)}
        guard Set(evidence.map(\.id))==evidenceIDs else{throw VideoError.review("所选证据已缺失，请重新核对上传范围")}
        let inputHash=Codec.hash(try ProviderRules.body(profile:profile,revision:project.current,evidence:evidence,brief:brief))
        if let old=snapshot.jobs.first(where:{$0.workspaceID==workspaceID && $0.requestKey==requestKey}) {
            guard old.projectID==projectID,old.quote.id==quote.id,old.providerAttempts?.first?.inputDigest==inputHash,old.digest==(try project.current.contentDigest()) else{throw VideoError.conflict("原请求键与此次输入不符")}
            return old
        }
        // Missing/revoked local credentials fail before any paid intent is stored.
        _=try SecureCredentials.read(profile.keyReference)
        let prepared=try repository.transaction{db in
            try ScriptJobRules.prepare(database:&db,workspaceID:workspaceID,projectID:projectID,profile:profile,evidence:evidence,brief:brief,quote:quote,requestKey:requestKey,principal:principal)
        }
        guard prepared.shouldSubmit else{return prepared.job}
        let job=prepared.job
        do {
            let text=try await ProviderClient.script(profile:profile,revision:project.current,evidence:evidence,brief:brief,requestKey:requestKey,quote:quote,onAttempt:{receipt in
                try repository.transaction{db in
                    guard try db.workspace(workspaceID).owner==principal,let i=db.jobs.firstIndex(where:{$0.id==job.id && $0.digest==job.digest}) else{throw VideoError.permission("原任务权限已撤销")}
                    db.jobs[i]=try ScriptJobRules.record(receipt,in:db.jobs[i])
                }
            })
            let data=Data(text.utf8),path=repository.root.appendingPathComponent("drafts/\(job.id).txt")
            try PluginHost.validateOutput(path:path,root:repository.root)
            try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
            try data.write(to:path,options:.atomic)
            return try repository.transaction{db in
                guard try db.workspace(workspaceID).owner==principal,let i=db.jobs.firstIndex(where:{$0.id==job.id}),db.jobs[i].state == .running else{throw VideoError.conflict("原任务状态或权限已变化，草稿不会覆盖其他版本")}
                db.jobs[i].artifacts=[Artifact(path:path.path,mime:"text/plain",bytes:data.count,sha256:Codec.hash(data),revision:job.revisionID)]
                db.jobs[i].state = .billingPending;db.jobs[i].progress=1;db.jobs[i].updatedAt=Date()
                db.jobs[i].message="候选已保存；人工审稿后才可加入镜头，现金与退款按实际账单独立核对"
                return db.jobs[i]
            }
        }catch{
            try? repository.transaction{db in guard let i=db.jobs.firstIndex(where:{$0.id==job.id}) else{return};db.jobs[i]=ScriptJobRules.interrupted(db.jobs[i])}
            throw error
        }
    }
    public static func draft(repository:Repository,job:Job)throws->String {
        let db=try repository.read()
        guard let project=db.projects.first(where:{$0.id==job.projectID && $0.workspaceID==job.workspaceID}),let revision=project.revisions.first(where:{$0.id==job.revisionID}),let artifact=job.artifacts.first(where:{$0.mime=="text/plain"}) else{throw VideoError.notFound("原任务没有可回读的候选讲稿")}
        let url=try repository.verifiedArtifactURL(artifact,job:job,revision:revision),data=try Data(contentsOf:url)
        guard data.count<=120000,let text=String(data:data,encoding:.utf8) else{throw VideoError.review("候选讲稿不是可用的有界UTF-8文本")}
        return text
    }
}
