import Foundation
import Darwin
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
        guard let lease=job.lease else{throw VideoError.conflict("原脚本请求缺少有界执行权，不能提交")}
        do {
            let text=try await ProviderClient.script(profile:profile,revision:project.current,evidence:evidence,brief:brief,requestKey:requestKey,quote:quote,deadline:lease.expiresAt,onAttempt:{receipt in
                try repository.transaction{db in
                    guard try db.workspace(workspaceID).owner==principal,let i=db.jobs.firstIndex(where:{$0.id==job.id && $0.digest==job.digest}) else{throw VideoError.permission("原任务权限已撤销")}
                    db.jobs[i]=try ScriptJobRules.record(receipt,in:db.jobs[i],executionToken:lease.token)
                }
            })
            let draft=try prepareDraft(text:text,job:job,repository:repository,principal:principal)
            return try publishDraft(draft,repository:repository)
        }catch{
            try? repository.transaction{db in guard let i=db.jobs.firstIndex(where:{$0.id==job.id}) else{return};db.jobs[i]=ScriptJobRules.interrupted(db.jobs[i],executionToken:lease.token)}
            throw error
        }
    }
    /// This normal two-phase path permits a fresh authority/state check after
    /// copying. Only its own unchanged temporary or published file is reclaimed.
    static func prepareDraft(text:String,job:Job,repository:Repository,principal:String)throws->PreparedScriptDraft {
        try Task.checkCancellation()
        let bytes=Data(text.utf8)
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.count<=30000,bytes.count<=120000,
              UUID(uuidString:job.id) != nil,let token=job.lease?.token else{throw VideoError.invalid("候选讲稿或原执行权不可用")}
        return try repository.transaction{database in
        _=try currentDraftJob(database,job:job,principal:principal,token:token)
        let parent=repository.root.appendingPathComponent("drafts",isDirectory:true)
        try PluginHost.validateOutput(path:parent,root:repository.root)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let parentIdentity=try ScriptDraftIdentity.directory(parent)
        let staging=parent.appendingPathComponent(".\(job.id).\(Codec.id()).preparing",isDirectory:true)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let directoryIdentity=try ScriptDraftIdentity.directory(staging),temporary=staging.appendingPathComponent("candidate.txt")
        let descriptor=open(temporary.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,S_IRUSR|S_IWUSR)
        guard descriptor>=0 else{throw VideoError.unavailable("候选暂存文件无法独占创建，未覆盖已有讲稿")}
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        do {
            try handle.write(contentsOf:bytes);try handle.synchronize();try handle.close()
            let fileIdentity=try ScriptDraftIdentity.regularFile(temporary)
            let prepared=PreparedScriptDraft(root:repository.root,principal:principal,job:job,token:token,parent:parent,staging:staging,temporary:temporary,parentIdentity:parentIdentity,directoryIdentity:directoryIdentity,fileIdentity:fileIdentity,bytes:bytes)
            do{try prepared.verifyStaging();return prepared}catch{prepared.cancel();throw error}
        }catch{
            try? handle.close()
            // Without a complete established file identity, retain the private
            // location rather than deleting a concurrently replaced user path.
            throw error
        }
        }
    }
    static func publishDraft(_ prepared:PreparedScriptDraft,repository:Repository)throws->Job {
        prepared.lock.lock();defer{prepared.lock.unlock()}
        guard prepared.state == .prepared,prepared.root==repository.root else{throw VideoError.conflict("候选暂存不属于当前请求或已结束，不能重复发布")}
        do {
            let result=try repository.transaction{database in
                try Task.checkCancellation()
                let current=try currentDraftJob(database,job:prepared.job,principal:prepared.principal,token:prepared.token)
                try prepared.verifyStaging()
                let artifact=Artifact(path:prepared.final.path,mime:"text/plain",bytes:prepared.bytes.count,sha256:Codec.hash(prepared.bytes),revision:current.revisionID)
                let completed=try ScriptJobRules.completingDraft(current,artifact:artifact,executionToken:prepared.token)
                guard let index=database.jobs.firstIndex(where:{$0.id==current.id}) else{throw VideoError.notFound("原脚本任务不存在")}
                try Task.checkCancellation()
                try ScriptJobRules.authorizeExecution(current,token:prepared.token)
                let status=prepared.temporary.path.withCString{source in prepared.final.path.withCString{destination in renameatx_np(AT_FDCWD,source,AT_FDCWD,destination,UInt32(RENAME_EXCL))}}
                guard status==0 else{throw VideoError.conflict("候选正式位置已存在或无法发布；已有讲稿未覆盖")}
                prepared.state = .moved
                database.jobs[index]=completed
                return completed
            }
            prepared.state = .published;prepared.removeOwnedStaging();return result
        }catch{
            if prepared.state == .moved{prepared.removeOwnedFinal()}
            prepared.removeOwnedStaging();prepared.state = .discarded
            throw error
        }
    }
    private static func currentDraftJob(_ database:Database,job:Job,principal:String,token:String)throws->Job {
        guard try database.workspace(job.workspaceID).owner==principal,
              let current=database.jobs.first(where:{$0.id==job.id && $0.workspaceID==job.workspaceID && $0.projectID==job.projectID && $0.revisionID==job.revisionID && $0.digest==job.digest && $0.requestKey==job.requestKey}),
              current.artifacts.isEmpty else{throw VideoError.conflict("原请求权限、身份或候选索引已变化，不能发布")}
        try ScriptJobRules.authorizeExecution(current,token:token)
        return current
    }
    public static func draft(repository:Repository,job:Job)throws->String {
        let db=try repository.read()
        guard let project=db.projects.first(where:{$0.id==job.projectID && $0.workspaceID==job.workspaceID}),let revision=project.revisions.first(where:{$0.id==job.revisionID}),let artifact=job.artifacts.first(where:{$0.mime=="text/plain"}) else{throw VideoError.notFound("原任务没有可回读的候选讲稿")}
        let url=try repository.verifiedArtifactURL(artifact,job:job,revision:revision),data=try Data(contentsOf:url)
        guard data.count<=120000,let text=String(data:data,encoding:.utf8) else{throw VideoError.review("候选讲稿不是可用的有界UTF-8文本")}
        return text
    }
}

struct ScriptDraftIdentity:Equatable {
    let device:dev_t;let inode:ino_t
    private static func info(_ path:URL)throws->stat{var value=stat();guard lstat(path.path,&value)==0 else{throw VideoError.unavailable("候选暂存位置已变化")};return value}
    static func directory(_ path:URL)throws->Self{let value=try info(path);guard value.st_mode&S_IFMT==S_IFDIR else{throw VideoError.permission("候选目录被替换或包含链接")};return Self(device:value.st_dev,inode:value.st_ino)}
    static func regularFile(_ path:URL)throws->Self{let value=try info(path);guard value.st_mode&S_IFMT==S_IFREG,value.st_nlink==1 else{throw VideoError.permission("候选须为本次独立普通文件")};return Self(device:value.st_dev,inode:value.st_ino)}
}

final class PreparedScriptDraft {
    enum State:Equatable{case prepared,moved,published,discarded}
    let root:URL;let principal:String;let job:Job;let token:String;let parent:URL;let staging:URL;let temporary:URL;let final:URL;let bytes:Data
    let parentIdentity:ScriptDraftIdentity;let directoryIdentity:ScriptDraftIdentity;let fileIdentity:ScriptDraftIdentity
    let lock=NSLock();var state:State = .prepared
    init(root:URL,principal:String,job:Job,token:String,parent:URL,staging:URL,temporary:URL,parentIdentity:ScriptDraftIdentity,directoryIdentity:ScriptDraftIdentity,fileIdentity:ScriptDraftIdentity,bytes:Data){self.root=root;self.principal=principal;self.job=job;self.token=token;self.parent=parent;self.staging=staging;self.temporary=temporary;self.parentIdentity=parentIdentity;self.directoryIdentity=directoryIdentity;self.fileIdentity=fileIdentity;self.bytes=bytes;final=parent.appendingPathComponent(job.id+".txt")}
    func verifyStaging()throws {
        guard try ScriptDraftIdentity.directory(parent)==parentIdentity,try ScriptDraftIdentity.directory(staging)==directoryIdentity,
              try ScriptDraftIdentity.regularFile(temporary)==fileIdentity,
              Set(try FileManager.default.contentsOfDirectory(atPath:staging.path))==["candidate.txt"],
              try Data(contentsOf:temporary)==bytes else{throw VideoError.conflict("本次候选暂存内容或位置变化，未发布")}
    }
    func removeOwnedFinal(){guard (try? ScriptDraftIdentity.directory(parent))==parentIdentity,(try? ScriptDraftIdentity.regularFile(final))==fileIdentity,(try? Data(contentsOf:final))==bytes else{return};try? FileManager.default.removeItem(at:final)}
    func removeOwnedStaging(){guard (try? ScriptDraftIdentity.directory(parent))==parentIdentity,(try? ScriptDraftIdentity.directory(staging))==directoryIdentity,let names=try? FileManager.default.contentsOfDirectory(atPath:staging.path),Set(names).isSubset(of:["candidate.txt"]),names.isEmpty || ((try? ScriptDraftIdentity.regularFile(temporary))==fileIdentity && (try? Data(contentsOf:temporary))==bytes) else{return};try? FileManager.default.removeItem(at:staging)}
    func cancel(){lock.lock();defer{lock.unlock()};guard state == .prepared else{return};removeOwnedStaging();state = .discarded}
    deinit{if state == .prepared{removeOwnedStaging()}}
}
