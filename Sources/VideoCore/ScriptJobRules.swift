import Foundation

/// A candidate generation is a durable, one-shot paid intent. Its body digest is
/// stored before transport, so reopening or changing request keys cannot resubmit
/// an unresolved identical input. A result is always a draft, never an approval.
public enum ScriptJobRules {
    /// The transport uses this same per-resource bound. A malformed result may
    /// consume one explicitly budgeted repair, never an unbounded new lease.
    public static let requestTimeoutSeconds:TimeInterval=60
    public static func executionAttempts(profile:ProviderProfile,quote:Quote?,now:Date=Date())->Int {
        ProviderRules.mayRepair(profile:profile,quote:quote,now:now) ? 2:1
    }
    public static func executionDeadline(profile:ProviderProfile,quote:Quote?,now:Date=Date())->Date {
        // Codec persists ISO-8601 whole seconds. Return that same exact deadline
        // to the original transport so another client never recovers it earlier.
        // Rounding down also keeps it within the original HTTP/repair maximum.
        let upper=now.addingTimeInterval(requestTimeoutSeconds * Double(executionAttempts(profile:profile,quote:quote,now:now)))
        return Date(timeIntervalSince1970:upper.timeIntervalSince1970.rounded(.down))
    }
    public static func authorizeExecution(_ job:Job,token:String,now:Date=Date())throws {
        guard job.quote.provider != "native",job.state == .running,
              let lease=job.lease,lease.owner=="script:"+job.id,lease.token==token,
              lease.expiresAt>now else {
            throw VideoError.conflict("原脚本请求执行权已取消、过期或被替换；不得继续付费或覆盖候选")
        }
    }
    public static func specification(profile:ProviderProfile,revision:Revision,evidence:[Evidence],brief:String)throws->String {
        "chat-candidate-v2/input-sha256="+Codec.hash(try ProviderRules.body(profile:profile,revision:revision,evidence:evidence,brief:brief))
    }
    public static func prepare(database:inout Database,workspaceID:String,projectID:String,profile:ProviderProfile,evidence:[Evidence],brief:String,quote:Quote,requestKey:String,principal:String,now:Date=Date())throws->(job:Job,shouldSubmit:Bool) {
        guard try database.workspace(workspaceID).owner==principal,
              let live=database.providers.first(where:{$0.id==profile.id}),try Codec.digest(live)==Codec.digest(profile) else{throw VideoError.permission("原服务配置或本机工作区所有者权限已变化")}
        let project=try database.project(projectID)
        guard project.workspaceID==workspaceID else{throw VideoError.permission("工程不属于当前工作区")}
        for selected in evidence {guard let current=database.evidence.first(where:{$0.id==selected.id && $0.workspaceID==workspaceID}),try current.contentDigest()==selected.contentDigest() else{throw VideoError.conflict("所选上传证据已变化，请重新核对输入与报价")}}
        let body=try ProviderRules.body(profile:profile,revision:project.current,evidence:evidence,brief:brief,now:now)
        let digest=Codec.hash(body)
        if let old=database.jobs.first(where:{$0.workspaceID==workspaceID && $0.requestKey==requestKey}) {
            guard old.projectID==project.id,old.quote.id==quote.id,old.providerAttempts?.first?.inputDigest==digest else{throw VideoError.conflict("原请求键绑定其他输入或报价")}
            return(old,false)
        }
        guard !requestKey.isEmpty,requestKey.utf8.count<=200,!requestKey.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else{throw VideoError.invalid("请求键为空或格式不合法")}
        guard let details=quote.breakdown,details.specification==(try specification(profile:profile,revision:project.current,evidence:evidence,brief:brief)),quote.provider==profile.id else{throw VideoError.review("报价未绑定此服务和本次实际上传内容，请重新冻结费用")}
        guard !database.jobs.contains(where:{$0.quote.id==quote.id}) else{throw VideoError.conflict("原报价已使用，请读取原任务，不能重复付费")}
        guard !database.jobs.contains(where:{
            $0.workspaceID==workspaceID && $0.projectID==projectID && $0.quote.provider==profile.id &&
            $0.providerAttempts?.first?.inputDigest==digest &&
            [.running,.unknownRemote,.cancelRequested,.billingPending].contains($0.state) &&
            $0.artifacts.isEmpty
        }) else{throw VideoError.conflict("相同输入存在未核实原任务；新报价或请求键不能绕过，先查询原ID或按供应商账单核对")}
        try BatchRules.validateSubmission(project:project,quote:quote,batches:database.topicBatches ?? [],existingJobs:database.jobs,requestKey:requestKey)
        try TeachingBatchRules.validateSubmission(project:project,quote:quote,batches:database.teachingBatches ?? [],existingJobs:database.jobs,requestKey:requestKey)
        var job=try JobRules.submit(workspaceID:workspaceID,project:project,quote:quote,requestKey:requestKey,existing:database.jobs,budget:database.budget,now:now)
        job.state = .running
        job.lease=WorkerLease(owner:"script:"+job.id,token:Codec.id(),heartbeat:now,expiresAt:executionDeadline(profile:profile,quote:quote,now:now))
        job.providerAttempts=[ProviderAttempt(id:requestKey+"-attempt-1",number:1,inputDigest:digest,capabilityVersion:profile.capabilities?.version,startedAt:now)]
        job.message="本次候选请求已冻结；网络结果未知时不自动重交，费用待原账单核对"
        database.jobs.append(job)
        return(job,true)
    }
    public static func record(_ receipt:ProviderAttempt,in job:Job,executionToken:String?=nil,now:Date=Date())throws->Job {
        guard job.state == .running else{throw VideoError.conflict("原任务不再执行，停止后续付费请求和结果覆盖")}
        guard let executionToken else{throw VideoError.conflict("原脚本请求缺少执行权，不能记录回执")}
        try authorizeExecution(job,token:executionToken,now:now)
        var updated=job,receipts=job.providerAttempts ?? []
        if let old=receipts.first(where:{$0.id==receipt.id}) {guard old.inputDigest==receipt.inputDigest,old.number==receipt.number else{throw VideoError.conflict("原请求回执的输入摘要不一致")}}
        guard receipt.id==job.requestKey+"-attempt-\(receipt.number)",(1...min(job.quote.attempts,2)).contains(receipt.number) else{throw VideoError.conflict("服务尝试超出冻结预算或原请求键")}
        receipts.removeAll{$0.id==receipt.id};receipts.append(receipt);receipts.sort{$0.number<$1.number}
        updated.providerAttempts=receipts;updated.attempt=max(updated.attempt,receipt.number);updated.updatedAt=now
        return updated
    }
    public static func completingDraft(_ job:Job,artifact:Artifact,executionToken:String,now:Date=Date())throws->Job {
        try authorizeExecution(job,token:executionToken,now:now)
        guard job.artifacts.isEmpty,artifact.mime=="text/plain",artifact.revision==job.revisionID,
              (1...120000).contains(artifact.bytes),artifact.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else {
            throw VideoError.conflict("候选讲稿索引已存在或与原任务不符，不能覆盖")
        }
        var updated=job
        updated.artifacts=[artifact];updated.state = .billingPending;updated.progress=1;updated.lease=nil;updated.updatedAt=now
        updated.message="候选已保存；人工审稿后才可加入镜头，现金与退款按实际账单独立核对"
        return updated
    }
    public static func interrupted(_ job:Job,executionToken:String?=nil,now:Date=Date())->Job {
        guard job.state == .running else{return job}
        guard let lease=job.lease,lease.token==executionToken,lease.owner=="script:"+job.id else{return job}
        var updated=job
        updated.state = job.providerAttempts?.last?.respondedAt == nil ? .unknownRemote:.billingPending
        updated.message=updated.state == .unknownRemote ? "请求结果可能已收费；先查原任务或账单，不自动重交":"原服务已响应但草稿未通过完整结构检查；停止修复，实际现金待核"
        updated.lease=nil;updated.updatedAt=now
        return updated
    }
}
