import Foundation
import Darwin

/// A read-only view of the exact currently reviewed four-file export.
/// It is not a permit: prepare and publish recheck current state and destination.
public struct ProductionExportPlan: Codable, Equatable, Sendable {
    public struct Artifact: Codable, Equatable, Sendable {
        public let name: String
        public let mime: String
        public let bytes: Int
        public let sha256: String
    }
    public let workspaceID: String
    public let projectID: String
    public let revisionID: String
    public let jobID: String
    public let contentDigest: String
    public let directory: String
    public let artifacts: [Artifact]
}

public struct ProductionExportResult: Sendable {
    public let directory: URL
    public let recordSaved: Bool
}

/// A process-local export prepared by this repository, not a caller-supplied path.
/// Abandoning it only removes its own unchanged, private staging directory.
public final class PreparedProductionExport: @unchecked Sendable {
    fileprivate enum State: Equatable { case prepared, published, discarded }
    fileprivate let repositoryRoot: URL
    fileprivate let principal: String
    fileprivate let projectID: String
    fileprivate let revisionID: String
    fileprivate let jobID: String
    fileprivate let contentDigest: String
    fileprivate let artifactsDigest: String
    fileprivate let artifactHashes: [String:String]
    fileprivate let parent: URL
    fileprivate let staging: URL
    fileprivate let final: URL
    fileprivate let parentIdentity: ProductionExportIdentity
    fileprivate let stagingIdentity: ProductionExportIdentity
    fileprivate let lock = NSLock()
    fileprivate var state: State = .prepared

    fileprivate init(repositoryRoot:URL, principal:String, project:Project, job:Job,
                     parent:URL, staging:URL, final:URL,
                     parentIdentity:ProductionExportIdentity, stagingIdentity:ProductionExportIdentity) throws {
        self.repositoryRoot=repositoryRoot; self.principal=principal
        projectID=project.id; revisionID=project.current.id; jobID=job.id
        contentDigest=try project.current.contentDigest(); artifactsDigest=try Codec.digest(job.artifacts)
        artifactHashes=Dictionary(uniqueKeysWithValues:job.artifacts.map{($0.mime,$0.sha256)})
        self.parent=parent; self.staging=staging; self.final=final
        self.parentIdentity=parentIdentity; self.stagingIdentity=stagingIdentity
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard state == .prepared else { return }
        removeOwnedStaging(); state = .discarded
    }

    fileprivate func removeOwnedStaging() {
        guard (try? ProductionExportIdentity.directory(parent)) == parentIdentity,
              (try? ProductionExportIdentity.directory(staging)) == stagingIdentity,
              let entries=try? FileManager.default.contentsOfDirectory(at:staging,includingPropertiesForKeys:nil),
              Set(entries.map(\.lastPathComponent)).isSubset(of:Set(ProductionExportRules.names.values)),
              entries.allSatisfy({(try? ProductionExportIdentity.regularFile($0)) != nil}) else { return }
        try? FileManager.default.removeItem(at:staging)
    }

    deinit { if state == .prepared { removeOwnedStaging() } }
}

fileprivate struct ProductionExportIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    private static func info(_ url:URL) throws -> stat {
        var value=stat()
        guard lstat(url.path,&value)==0 else { throw VideoError.unavailable("导出位置已变化或无法读取，请重新选择保存位置") }
        return value
    }
    static func directory(_ url:URL) throws -> Self {
        let value=try info(url)
        guard value.st_mode & S_IFMT == S_IFDIR else { throw VideoError.permission("导出目录已被替换或包含链接，未发布文件") }
        return Self(device:value.st_dev,inode:value.st_ino)
    }
    static func regularFile(_ url:URL) throws -> Self {
        let value=try info(url)
        guard value.st_mode & S_IFMT == S_IFREG, value.st_nlink==1 else { throw VideoError.permission("交付文件不是本次独立普通文件，未发布文件") }
        return Self(device:value.st_dev,inode:value.st_ino)
    }
}

fileprivate enum ProductionExportRules {
    static let names=["video/mp4":"video.mp4", "application/x-subrip":"subtitles.srt", "image/png":"cover.png", "text/plain":"source.txt"]
    // The native 30-minute renderer remains within this bounded staging inventory.
    static let maximumBytes=1024*1024*1024

    static func current(_ database:Database, projectID:String, revisionID:String, jobID:String,
                        principal:String, now:Date=Date()) throws -> (Project,Job) {
        let project=try database.project(projectID)
        try database.workspace(project.workspaceID).authorize(principal:principal,project:project.id,revision:revisionID,write:true,now:now)
        guard project.current.id==revisionID, project.current.review.complete,
              project.current.review.digest == (try project.current.contentDigest()),
              let job=database.jobs.first(where:{$0.id==jobID && $0.workspaceID==project.workspaceID && $0.projectID==project.id && $0.revisionID==revisionID && $0.state == .succeeded}),
              job.digest == (try project.current.contentDigest()), job.artifacts.count==4,
              Set(job.artifacts.map(\.mime))==Set(names.keys) else {
            throw VideoError.review("工程版本、审核或成片已变化，请重新核对后导出")
        }
        let issues=try Quality.inspect(project.current,database:database,requireReview:true,now:now)
        guard issues.isEmpty else { throw VideoError.review(issues.map(\.message).joined(separator:"；")) }
        var bytes=0
        for artifact in job.artifacts {
            guard artifact.bytes>=0,artifact.bytes<=maximumBytes-bytes else { throw VideoError.invalid("四项交付文件超过本机安全导出上限，请先分段或压缩") }
            bytes += artifact.bytes
        }
        return (project,job)
    }

    static func safeName(_ project:Project)->String {
        let name=project.name.components(separatedBy:CharacterSet(charactersIn:"/:\\").union(.controlCharacters))
            .joined(separator:"-").trimmingCharacters(in:CharacterSet(charactersIn:". "))
        return String((name.isEmpty ? "视频":name).prefix(80))+"-v\(project.current.number)"
    }

    static func verifyStaging(_ prepared:PreparedProductionExport, job:Job) throws {
        guard try ProductionExportIdentity.directory(prepared.parent)==prepared.parentIdentity,
              try ProductionExportIdentity.directory(prepared.staging)==prepared.stagingIdentity else {
            throw VideoError.permission("导出位置已被替换，未发布文件；请重新选择保存位置")
        }
        let entries=try FileManager.default.contentsOfDirectory(at:prepared.staging,includingPropertiesForKeys:nil)
        guard entries.count==4,Set(entries.map(\.lastPathComponent))==Set(names.values) else { throw VideoError.review("暂存交付文件不完整或出现额外文件，未发布文件") }
        for artifact in job.artifacts {
            guard let name=names[artifact.mime] else { throw VideoError.review("交付文件类型不完整") }
            let url=prepared.staging.appendingPathComponent(name)
            _ = try ProductionExportIdentity.regularFile(url)
            let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
            guard (attributes[.size] as? NSNumber)?.intValue==artifact.bytes else { throw VideoError.review("暂存交付文件大小已变化，未发布文件") }
            let data=try Data(contentsOf:url)
            guard data.count==artifact.bytes,Codec.hash(data)==artifact.sha256 else { throw VideoError.review("暂存交付文件摘要已变化，未发布文件") }
        }
    }

    static func publish(staging:URL, final:URL) throws {
        // Same-parent exclusive rename: an existing user output is never replaced.
        let status=staging.path.withCString { source in final.path.withCString { destination in
            renameatx_np(AT_FDCWD,source,AT_FDCWD,destination,UInt32(RENAME_EXCL))
        }}
        guard status==0 else {
            if errno==EEXIST || errno==ENOTEMPTY { throw VideoError.conflict("所选位置已有同名项目版本文件夹；现有交付不会覆盖，请换一个位置") }
            throw VideoError.unavailable("交付目录未能发布；已有文件保持，请检查保存位置后重新导出")
        }
    }
}

public extension Repository {
    private func productionExportContext(projectID:String, revisionID:String, jobID:String,
                                         principal:String, destination:URL) throws -> (Project,Job,URL,URL,ProductionExportIdentity) {
        let (project,job)=try ProductionExportRules.current(read(),projectID:projectID,revisionID:revisionID,jobID:jobID,principal:principal)
        try verifyDelivery(job,revision:project.current)
        guard destination.isFileURL else { throw VideoError.invalid("请选择本机文件夹保存交付") }
        let parent=destination.standardizedFileURL.resolvingSymlinksInPath()
        let parentIdentity=try ProductionExportIdentity.directory(parent)
        let final=parent.appendingPathComponent(ProductionExportRules.safeName(project),isDirectory:true)
        var existing=stat()
        if lstat(final.path,&existing)==0 { throw VideoError.conflict("所选位置已有 \(final.lastPathComponent) 条目；现有交付不会覆盖，请换一个保存位置") }
        guard errno==ENOENT else { throw VideoError.unavailable("无法确认所选位置的现有条目，请检查保存目录后重新预演") }
        return (project,job,parent,final,parentIdentity)
    }

    /// No staging directory, file copy, database mutation or delivery record.
    /// The caller must still retain destination access and recheck at export time.
    func previewProductionExport(projectID:String, revisionID:String, jobID:String,
                                 principal:String, destination:URL) throws -> ProductionExportPlan {
        let (project,job,_,final,_)=try productionExportContext(projectID:projectID,revisionID:revisionID,jobID:jobID,principal:principal,destination:destination)
        let artifacts=try job.artifacts.sorted{$0.mime<$1.mime}.map { artifact -> ProductionExportPlan.Artifact in
            guard let name=ProductionExportRules.names[artifact.mime] else { throw VideoError.review("交付文件类型不完整") }
            return ProductionExportPlan.Artifact(name:name,mime:artifact.mime,bytes:artifact.bytes,sha256:artifact.sha256)
        }
        return ProductionExportPlan(workspaceID:project.workspaceID,projectID:project.id,revisionID:project.current.id,jobID:job.id,contentDigest:try project.current.contentDigest(),directory:final.path,artifacts:artifacts)
    }

    /// The caller retains any security-scoped destination access until publish/cancel.
    /// Staging does not approve a revision or create a final export directory.
    func prepareProductionExport(projectID:String, revisionID:String, jobID:String,
                                 principal:String, destination:URL) throws -> PreparedProductionExport {
        try requireProductionExportWriteAccess()
        let (project,job,parent,final,parentIdentity)=try productionExportContext(projectID:projectID,revisionID:revisionID,jobID:jobID,principal:principal,destination:destination)
        let stem=final.lastPathComponent
        let staging=parent.appendingPathComponent(".\(stem).\(Codec.id()).preparing",isDirectory:true)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let prepared:PreparedProductionExport
        do {
            prepared=try PreparedProductionExport(repositoryRoot:root,principal:principal,project:project,job:job,parent:parent,staging:staging,final:final,
                parentIdentity:parentIdentity,stagingIdentity:ProductionExportIdentity.directory(staging))
        } catch {
            // Without an established identity, preserve the location rather than
            // risking deletion of a directory replaced by another actor.
            throw error
        }
        do {
            for artifact in job.artifacts {
                let source=try verifiedArtifactURL(artifact,job:job,revision:project.current)
                let data=try Data(contentsOf:source)
                guard data.count==artifact.bytes,Codec.hash(data)==artifact.sha256,let name=ProductionExportRules.names[artifact.mime] else { throw VideoError.review("成片文件已变化，请重新制作；未发布文件") }
                try data.write(to:staging.appendingPathComponent(name),options:.atomic)
            }
            try ProductionExportRules.verifyStaging(prepared,job:job)
            return prepared
        } catch { prepared.cancel();throw error }
    }

    /// Recheck after copying under the same SQLite writer lock used by all editors.
    /// Filesystem publication and SQLite commit are not one cross-system transaction.
    /// A persistence failure after a successful rename preserves the verified output
    /// and explicitly reports that its local delivery record was not saved.
    func publishProductionExport(_ prepared:PreparedProductionExport) throws -> ProductionExportResult {
        prepared.lock.lock();defer{prepared.lock.unlock()}
        guard prepared.state == .prepared,prepared.repositoryRoot==root else { throw VideoError.conflict("此导出已结束或不属于当前创作空间；不会重复发布或覆盖") }
        do {
            try requireProductionExportWriteAccess()
            try transaction { database in
                let (project,job)=try ProductionExportRules.current(database,projectID:prepared.projectID,revisionID:prepared.revisionID,jobID:prepared.jobID,principal:prepared.principal)
                guard try project.current.contentDigest()==prepared.contentDigest,
                      try Codec.digest(job.artifacts)==prepared.artifactsDigest else { throw VideoError.conflict("当前成片版本或文件索引已变化，未发布暂存文件") }
                try verifyDelivery(job,revision:project.current)
                try ProductionExportRules.verifyStaging(prepared,job:job)
                // This fresh quality check also rejects rights/terms expiring during file hashing.
                try database.recordProductionDelivery(projectID:project.id,jobID:job.id,destinationName:prepared.final.lastPathComponent,artifactHashes:prepared.artifactHashes)
                try ProductionExportRules.publish(staging:prepared.staging,final:prepared.final)
                prepared.state = .published
            }
            return ProductionExportResult(directory:prepared.final,recordSaved:true)
        } catch {
            if prepared.state == .published { return ProductionExportResult(directory:prepared.final,recordSaved:false) }
            prepared.removeOwnedStaging();prepared.state = .discarded
            throw error
        }
    }
}
