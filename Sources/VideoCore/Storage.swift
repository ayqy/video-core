import Foundation
import CSQLite
import CryptoKit
import Darwin

public struct ImportReceipt: Codable, Identifiable, Sendable {
    public var tags: [String]?
    public var workspaceID: String?
    public var id: String; public var kind: String; public var orderIDs: [String]; public var previousOrders: [Order]; public var metricIDs: [String]; public var previousMetrics: [Metric]; public var at: Date; public var rolledBack = false
    public init(id: String, kind: String, orderIDs: [String] = [], previousOrders: [Order] = [], metricIDs: [String] = [], previousMetrics: [Metric] = [], at: Date = Date()) { self.id = id; self.kind = kind; self.orderIDs = orderIDs; self.previousOrders = previousOrders; self.metricIDs = metricIDs; self.previousMetrics = previousMetrics; self.at = at }
}
public struct Database: Codable, Sendable {
    public var schema = 1; public var generation = 0; public var workspaces: [Workspace] = []; public var products: [Product] = []; public var evidence: [Evidence] = []; public var assets: [Asset] = []; public var projects: [Project] = []; public var topics: [Topic] = []; public var jobs: [Job] = []; public var publications: [Publication] = []; public var metrics: [Metric] = []; public var orders: [Order] = []; public var imports: [ImportReceipt] = []; public var attributions: [Attribution] = []; public var cash: [CashEntry] = []; public var expenses: [Expense] = []; public var toolSales: [ToolSale] = []; public var brandDeals: [BrandDeal] = []; public var providers: [ProviderProfile] = []; public var funnel: [FunnelEvent] = []; public var budget = BudgetPolicy(); public var baseline: Baseline?; public var terminology: [String: String] = [:]
    public init() {}
    public var baselines: [String: Baseline] = [:]
    public var narrativeDocuments: [NarrativeDocument]?
    public var styleKits: [StyleKit]?
    public var narrativeTemplates: [NarrativeTemplate]?
    public var seriesProfiles: [SeriesProfile]?
    public var supportRecords: [SupportRecord]?
    public var intentReceipts: [IntentReceipt]?
    public var agentReplayRecords: [AgentReplayRecord]?
    public var topicBatches: [TopicBatch]?
    public func workspace(_ id: String) throws -> Workspace { guard let w = workspaces.first(where: { $0.id == id }) else { throw VideoError.notFound("工作区不存在") }; return w }
    public func project(_ id: String) throws -> Project { guard let p = projects.first(where: { $0.id == id }) else { throw VideoError.notFound("项目不存在") }; return p }
    public func validate() throws {
        guard schema == 1 else { throw VideoError.unavailable("工程主版本不支持，请保留原文件") }
        let ws = Set(workspaces.map(\.id)); guard ws.count == workspaces.count else { throw VideoError.invalid("工作区ID重复") }
        for p in products { guard ws.contains(p.workspaceID) else { throw VideoError.invalid("产品工作区缺失") }; try p.validate(); try DependencyRules.validateMappings(product:p,assets:assets,evidence:evidence) }
        for p in projects { guard ws.contains(p.workspaceID), !p.revisions.isEmpty else { throw VideoError.invalid("项目工作区或版本缺失") }; for r in p.revisions { try r.audioQuality?.validate();guard r.schemaVersion == 1, r.product.workspaceID == p.workspaceID, !r.scenes.isEmpty, r.fps == 30 else { throw VideoError.invalid("工程IR不完整或版本不兼容") }; for s in r.scenes { try s.validate(assets: assets.filter { $0.workspaceID == p.workspaceID }) } } }
        for o in orders { try o.validate() }; for m in metrics {try m.validate()}; try Finance.validateAttribution(attributions)
        guard Set(orders.map(\.id)).count == orders.count, Set(metrics.map(\.id)).count == metrics.count, Set(cash.map(\.id)).count == cash.count, Set(expenses.map(\.id)).count == expenses.count else { throw VideoError.invalid("订单、指标或账目ID重复") }
        for x in expenses { guard x.hours >= 0, x.money == nil || x.money!.amount >= 0, x.allocation.values.allSatisfy({ $0 >= 0 }), x.allocation.values.reduce(0,+) <= 1 else { throw VideoError.invalid("工时、成本与分摊比例不合法") } }
        for x in cash { guard x.refunded >= 0, x.refunded <= x.received.amount else { throw VideoError.invalid("现金退款超过实收") } }
        for x in toolSales { try x.validate() }; for x in brandDeals { try x.validate() }
    }
    public mutating func importOrders(_ rows: [Order], batchID: String) throws {
        if imports.contains(where: { $0.id == batchID && !$0.rolledBack }) { return }
        guard Set(rows.map(\.id)).count == rows.count else { throw VideoError.invalid("同批次订单重复，先合并退款事件") }
        for o in rows { try o.validate() }
        let keys = Set(rows.map(\.id)); let previous = orders.filter { keys.contains($0.id) }
        let incoming = rows.map { row -> Order in var updated=row; if updated.tags == nil { updated.tags=previous.first{$0.id==row.id}?.tags }; return updated }
        orders.removeAll { keys.contains($0.id) }; orders += incoming
        var receipt=ImportReceipt(id: batchID, kind: "orders", orderIDs: Array(keys), previousOrders: previous)
        let scopes=Set(rows.map(\.workspaceID));if scopes.count==1 {receipt.workspaceID=scopes.first};imports.append(receipt)
    }
    public mutating func importMetrics(_ rows: [Metric], batchID: String) throws {
        if imports.contains(where: { $0.id == batchID && !$0.rolledBack }) { return }
        guard Set(rows.map(\.id)).count == rows.count else { throw VideoError.invalid("同批次指标快照重复") }
        let keys = Set(rows.map(\.id)); let previous = metrics.filter { keys.contains($0.id) }
        metrics.removeAll { keys.contains($0.id) }; metrics += rows
        var receipt=ImportReceipt(id: batchID, kind: "metrics", metricIDs: Array(keys), previousMetrics: previous)
        let scopes=Set(rows.map(\.workspaceID));if scopes.count==1 {receipt.workspaceID=scopes.first};imports.append(receipt)
    }
    public mutating func rollbackImport(_ id: String) throws {
        guard let i = imports.firstIndex(where: { $0.id == id && !$0.rolledBack }) else { throw VideoError.notFound("可回滚批次不存在") }
        let receipt = imports[i]
        guard !orders.contains(where: { receipt.orderIDs.contains($0.id) && $0.importID != id }), !metrics.contains(where: { receipt.metricIDs.contains($0.id) && $0.importID != id }) else { throw VideoError.conflict("后续批次已更新相同行，请先回滚后续批次") }
        orders.removeAll { receipt.orderIDs.contains($0.id) }; orders += receipt.previousOrders
        metrics.removeAll { receipt.metricIDs.contains($0.id) }; metrics += receipt.previousMetrics; imports[i].rolledBack = true
    }
}

/// One SQLite transaction serializes all domain mutations across UI, worker and CLI.
/// The snapshot is atomically versioned; WAL and busy timeout preserve concurrent readers.
public final class Repository: @unchecked Sendable {
    public let root: URL; private var db: OpaquePointer?; private let lock = NSRecursiveLock();private let readOnly:Bool
    public init(root requestedRoot: URL,readOnly:Bool=false) throws {
        // Keep a stable physical generation even if an installer's current pointer changes later.
        let root=requestedRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.root = root
        self.readOnly=readOnly
        if !readOnly { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        guard sqlite3_open_v2(root.appendingPathComponent("workspace.sqlite").path, &db, (readOnly ? SQLITE_OPEN_READONLY:SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw VideoError.unavailable("无法打开本地数据库") }
        sqlite3_busy_timeout(db, 5000)
        if readOnly { _ = try readUnlocked();return }
        try sql("PRAGMA journal_mode=WAL"); try sql("PRAGMA synchronous=FULL"); try sql("CREATE TABLE IF NOT EXISTS snapshot (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL)")
        if try readUnlocked().generation == 0 { try transaction { _ in } }
        // An app update may move its entire data container. A damaged historical
        // job must not prevent opening the workspace; it remains unchanged.
        _ = try? relocateHistoricalArtifacts()
    }
    deinit { sqlite3_close(db) }
    private func sql(_ s: String) throws { guard sqlite3_exec(db, s, nil, nil, nil) == SQLITE_OK else { throw VideoError.unavailable("本地事务失败，请稍后重试；原数据未覆盖") } }
    private func readUnlocked() throws -> Database {
        var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db, "SELECT payload FROM snapshot WHERE id=1", -1, &stmt, nil) == SQLITE_OK else { throw VideoError.unavailable("数据库读取失败") }; defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW { let count = Int(sqlite3_column_bytes(stmt, 0)); guard let bytes = sqlite3_column_blob(stmt, 0) else { throw VideoError.invalid("数据库记录损坏") }; let result = try Codec.decoder().decode(Database.self, from: Data(bytes: bytes, count: count)); guard result.schema == 1 else { throw VideoError.unavailable("数据库版本不支持") }; return result }
        return Database()
    }
    public func read() throws -> Database { lock.lock(); defer { lock.unlock() }; return try readUnlocked() }
    @discardableResult public func transaction<T>(expectedGeneration: Int? = nil, _ mutate: (inout Database) throws -> T) throws -> T {
        guard !readOnly else { throw VideoError.permission("只读检查不能写入工程") }
        lock.lock(); defer { lock.unlock() }; try sql("BEGIN IMMEDIATE")
        do {
            try ManagedInstallRules.authorizeWrite(repositoryRoot:root)
            var state = try readUnlocked(); if let expectedGeneration, state.generation != expectedGeneration { throw VideoError.conflict("数据已在另一窗口修改，请刷新后重试") }
            let result = try mutate(&state); try state.validate(); state.generation += 1; let data = try Codec.data(state)
            var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO snapshot(id,payload) VALUES(1,?)", -1, &stmt, nil) == SQLITE_OK else { throw VideoError.unavailable("保存数据失败") }; defer { sqlite3_finalize(stmt) }
            let rc = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }; guard rc == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else { throw VideoError.unavailable("保存数据失败") }; try sql("COMMIT"); return result
        } catch { try? sql("ROLLBACK"); throw error }
    }
    public func assetURL(_ asset: Asset) -> URL { root.appendingPathComponent(asset.relativePath) }
    public func ingest(_ data: Data, name: String, workspaceID: String, mediaType: String, durationFrames: Int? = nil) throws -> Asset {
        try ManagedInstallRules.authorizeWrite(repositoryRoot:root)
        guard !data.isEmpty, data.count <= 256 * 1024 * 1024 else { throw VideoError.invalid("素材为空或超过256MiB，请先裁短媒体") }
        let hash = Codec.hash(data); let ext = URL(fileURLWithPath: name).pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }; guard !ext.isEmpty, ext.count <= 12 else { throw VideoError.invalid("文件扩展名不合法") }
        var asset = Asset(workspaceID: workspaceID, name: name, hash: hash, ext: ext, bytes: data.count, mediaType: mediaType, durationFrames: durationFrames);asset.importedAt=Date()
        let url = assetURL(asset); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) { guard Codec.hash(try Data(contentsOf: url)) == hash else { throw VideoError.invalid("源文件哈希校验失败") } } else { try data.write(to: url, options: .atomic) }
        return asset
    }
    public func verifyAssets(_ state: Database) throws { for a in state.assets { let data = try Data(contentsOf: assetURL(a)); guard data.count == a.bytes, Codec.hash(data) == a.hash else { throw VideoError.invalid("源素材缺失或哈希不符：\(a.name)") } } }
    public func verifyDelivery(_ job:Job,revision:Revision) throws {
        guard job.revisionID==revision.id,job.digest == (try revision.contentDigest()),Set(job.artifacts.map(\.mime))==["video/mp4","image/png","application/x-subrip","text/plain"],job.artifacts.count==4 else { throw VideoError.review("尚无绑定当前版本的完整四项制作产物") }
        for artifact in job.artifacts { _ = try verifiedArtifactURL(artifact,job:job,revision:revision) }
    }
    /// Returns only the verified file in this physical workspace, never a stale
    /// absolute path from another container. This read API does not mutate SQLite.
    public func verifiedArtifactURL(_ artifact:Artifact,job:Job,revision:Revision)throws->URL {
        try Self.validateArtifactBinding(job,revision:revision)
        let state=try read()
        guard let project=state.projects.first(where:{$0.id==job.projectID && $0.workspaceID==job.workspaceID}),
              let frozen=project.revisions.first(where:{$0.id==job.revisionID}),try frozen.contentDigest()==job.digest,
              let stored=state.jobs.first(where:{$0.id==job.id && $0.workspaceID==job.workspaceID && $0.projectID==job.projectID && $0.revisionID==job.revisionID && $0.digest==job.digest}),
              stored.artifacts.contains(where:{$0.id==artifact.id && $0.path==artifact.path && $0.mime==artifact.mime && $0.bytes==artifact.bytes && $0.sha256==artifact.sha256 && $0.revision==artifact.revision}) else{throw VideoError.review("产物不属于指定工作区、历史版本与原任务")}
        let location=try artifactLocation(artifact,job:job)
        _ = try artifactLocations(job)
        var budget=Int.max
        _ = try verifyArtifactFile(artifact,components:location.components,budget:&budget)
        return location.url
    }
    /// Atomic per job: all of its artifacts must exist under exports/<same job>,
    /// with matching revision, exact bytes and SHA-256, before any path changes.
    /// The old prefix is never read. It is accepted only as a previous workspace
    /// prefix followed by the exact exports/job/filename structure, not basename.
    @discardableResult public func relocateHistoricalArtifacts()throws->Int {
        guard !readOnly else{return 0}
        lock.lock();defer{lock.unlock()}
        let state=try readUnlocked();var replacements:[Int:[Artifact]]=[:]
        var budget=256*1024*1024
        for (index,job) in state.jobs.enumerated().reversed().prefix(64) {
            guard budget>0 else{break}
            guard !job.artifacts.isEmpty,job.artifacts.count<=16 else{continue}
            do {
                let locations=try artifactLocations(job)
                guard locations.contains(where:{$0.url.path != $0.original.path}) else{continue}
                // Mixed old roots are not one relocated workspace generation.
                guard let project=state.projects.first(where:{$0.id==job.projectID && $0.workspaceID==job.workspaceID}),
                      let revision=project.revisions.first(where:{$0.id==job.revisionID}) else{continue}
                try Self.validateArtifactBinding(job,revision:revision)
                for (artifact,location) in zip(job.artifacts,locations) {_ = try verifyArtifactFile(artifact,components:location.components,budget:&budget)}
                replacements[index]=zip(job.artifacts,locations).map{artifact,location in var updated=artifact;updated.path=location.url.path;return updated}
            }catch{continue}
        }
        guard !replacements.isEmpty else{return 0}
        // Keep the normal cross-process generation check and managed-install
        // write authorization. An old generation or concurrent writer wins.
        try transaction(expectedGeneration:state.generation){database in
            for (index,artifacts) in replacements{database.jobs[index].artifacts=artifacts}
        }
        return replacements.count
    }
    private static func validateArtifactBinding(_ job:Job,revision:Revision)throws {
        guard job.workspaceID==revision.product.workspaceID,job.revisionID==revision.id,job.digest == (try revision.contentDigest()),
              job.quote.projectID==job.projectID,job.quote.revisionID==job.revisionID,job.quote.digest==job.digest,
              !job.artifacts.isEmpty,Set(job.artifacts.map(\.id)).count==job.artifacts.count else{throw VideoError.review("原任务、冻结版本、报价或产物绑定不一致")}
    }
    private func artifactLocation(_ artifact:Artifact,job:Job)throws->(url:URL,original:URL,oldRoot:String,components:[String]) {
        let path=artifact.path
        guard path.utf8.count<=4096,path.hasPrefix("/"),!path.contains("\0"),!path.contains("\\"),
              job.id.range(of:"^[a-z0-9][a-z0-9-]{0,79}$",options:.regularExpression) != nil,
              artifact.revision==job.revisionID,artifact.bytes>=0,
              artifact.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{throw VideoError.review("历史产物路径、版本或摘要格式无效")}
        let parts=path.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count>=4,parts.dropFirst().allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}) else{throw VideoError.permission("历史产物路径包含目录穿越或空组件")}
        let filename=String(parts.last!)
        guard filename.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",options:.regularExpression) != nil,!filename.contains("..") else{throw VideoError.permission("历史产物文件名无效")}
        let components:[String]
        if parts.count>=5,parts[parts.count-3]=="exports",parts[parts.count-2]==job.id {components=["exports",job.id,filename]}
        else if parts[parts.count-2]=="drafts",filename==job.id+".txt",artifact.mime=="text/plain" {components=["drafts",filename]}
        else{throw VideoError.permission("历史产物不属于原任务导出或讲稿目录")}
        let original=URL(fileURLWithPath:path),oldRoot=parts.dropLast(components.count).joined(separator:"/")
        // The candidate is constructed exclusively from this trusted root and
        // validated path components. No old root or user-supplied directory is read.
        let candidate=components.reduce(root){$0.appendingPathComponent($1)}
        return(candidate,original,oldRoot,components)
    }
    private func artifactLocations(_ job:Job)throws->[(url:URL,original:URL,oldRoot:String,components:[String])] {
        let locations=try job.artifacts.map{try artifactLocation($0,job:job)}
        guard Set(locations.map(\.oldRoot)).count==1,Set(locations.map{$0.components.joined(separator:"/")}).count==locations.count else{throw VideoError.permission("同一原任务产物来源目录混杂或位置重复")}
        return locations
    }
    private func verifyArtifactFile(_ artifact:Artifact,components:[String],budget:inout Int,includeData:Bool=false)throws->Data {
        guard artifact.bytes<=budget else{throw VideoError.review("历史导出校验超过本次读取上限，原记录保留")}
        // Opening each component relative to the previous descriptor prevents
        // both final-file and parent-directory symlinks, including internal ones.
        let base=open(root.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard base>=0 else{throw VideoError.review("当前工作区不可读取")};defer{close(base)}
        var parents:[Int32]=[],directory=base
        defer{for descriptor in parents.reversed(){close(descriptor)}}
        for component in components.dropLast(){let next=openat(directory,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);guard next>=0 else{throw VideoError.review("原任务产物目录缺失或为链接")};parents.append(next);directory=next}
        let file=openat(directory,components.last!,O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
        guard file>=0 else{throw VideoError.review("导出产物缺失或为链接")};defer{close(file)}
        var before=stat()
        guard fstat(file,&before)==0,(before.st_mode & S_IFMT)==S_IFREG,before.st_nlink==1,before.st_size==Int64(artifact.bytes) else{throw VideoError.review("导出产物类型、链接数或大小不符")}
        budget -= artifact.bytes
        var digest=SHA256(),buffer=[UInt8](repeating:0,count:1024*1024),total=0,data=Data()
        while true {
            try Task.checkCancellation()
            let count=buffer.withUnsafeMutableBytes{Darwin.read(file,$0.baseAddress,$0.count)}
            guard count>=0 else{throw VideoError.review("导出产物读取失败")}
            if count==0{break}
            guard count<=artifact.bytes-total else{throw VideoError.review("导出产物在校验中变化")}
            total += count;let block=Data(buffer[0..<count]);digest.update(data:block);if includeData{data.append(block)}
        }
        var after=stat()
        guard fstat(file,&after)==0,total==artifact.bytes,after.st_size==before.st_size,
              after.st_mtimespec.tv_sec==before.st_mtimespec.tv_sec,after.st_mtimespec.tv_nsec==before.st_mtimespec.tv_nsec,
              digest.finalize().map({String(format:"%02x",$0)}).joined()==artifact.sha256 else{throw VideoError.review("导出产物缺失、变化或摘要不符")}
        return data
    }
    public struct Backup: Codable { public var version: Int; public var snapshot: Data; public var digest: String; public var assets: [String: Data]; public var exports: [String:Data]? }
    public func backup() throws -> Data {
        let state = try read(); try verifyAssets(state); var clean = state; clean.providers = []
        var assets: [String: Data] = [:]; var bytes = 0; var exports:[String:Data]=[:]
        for a in clean.assets { if assets[a.relativePath] == nil { let d = try Data(contentsOf: assetURL(a)); bytes += d.count; guard bytes <= 300 * 1024 * 1024 else { throw VideoError.invalid("备份源素材超过300MiB，请分工作区备份") }; assets[a.relativePath] = d } }
        for j in clean.jobs.indices {
            let job=clean.jobs[j]
            if !job.artifacts.isEmpty {guard let project=clean.projects.first(where:{$0.id==job.projectID && $0.workspaceID==job.workspaceID}),let revision=project.revisions.first(where:{$0.id==job.revisionID}) else{throw VideoError.review("历史产物原任务或版本缺失，备份未标成功")};try Self.validateArtifactBinding(job,revision:revision)}
            let locations=job.artifacts.isEmpty ? []:try artifactLocations(job)
            for a in clean.jobs[j].artifacts.indices {
            let artifact=clean.jobs[j].artifacts[a],location=locations[a]
            let relative=location.components.joined(separator:"/")
            guard Self.validExportPath(relative)else{throw VideoError.invalid("历史导出路径不属于工程，无法制作完整备份")}
            if exports[relative]==nil{var remaining=300*1024*1024-bytes;let d=try verifyArtifactFile(artifact,components:location.components,budget:&remaining,includeData:true);bytes+=d.count;exports[relative]=d}
            clean.jobs[j].artifacts[a].path=relative
        }}
        let data=try Codec.data(clean)
        return try PropertyListEncoder().encode(Backup(version: 2, snapshot: data, digest: Codec.hash(data), assets: assets,exports:exports))
    }
    public static func restore(_ data: Data, to root: URL) throws -> Repository {
        guard data.count <= 350 * 1024 * 1024 else { throw VideoError.invalid("备份过大") }
        let b = try PropertyListDecoder().decode(Backup.self, from: data); guard [1,2].contains(b.version), b.digest == Codec.hash(b.snapshot) else { throw VideoError.invalid("备份版本或完整性校验失败") }
        var state = try Codec.decoder().decode(Database.self, from: b.snapshot); try state.validate()
        guard !FileManager.default.fileExists(atPath: root.path) else { throw VideoError.conflict("恢复目标必须是新目录，避免覆盖已有数据") }
        for a in state.assets { guard let d = b.assets[a.relativePath], Codec.hash(d) == a.hash, d.count == a.bytes, a.relativePath == "assets/\(Codec.hash(d)).\(a.ext)", a.ext.range(of: "^[a-z0-9]{1,12}$", options: .regularExpression) != nil else { throw VideoError.invalid("备份缺少源文件或摘要不符") } }
        for j in state.jobs.indices {
            if b.version==1 && !state.jobs[j].artifacts.isEmpty {state.jobs[j].artifacts=[];state.jobs[j].state = .interrupted;state.jobs[j].message="旧版备份没有历史成片，请沿原任务重做；源素材与版本保留";continue}
            for a in state.jobs[j].artifacts.indices {let artifact=state.jobs[j].artifacts[a];guard Self.validExportPath(artifact.path),let d=b.exports?[artifact.path],d.count==artifact.bytes,Codec.hash(d)==artifact.sha256 else{throw VideoError.invalid("备份缺少历史导出或摘要不符")};state.jobs[j].artifacts[a].path=root.appendingPathComponent(artifact.path).path}
        }
        let repo = try Repository(root: root)
        do { for a in state.assets { let u = repo.assetURL(a); try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); try b.assets[a.relativePath]!.write(to: u, options: .atomic) };for (relative,d) in b.exports ?? [:]{guard Self.validExportPath(relative)else{throw VideoError.invalid("备份导出路径越界")};let u=root.appendingPathComponent(relative);try FileManager.default.createDirectory(at:u.deletingLastPathComponent(),withIntermediateDirectories:true);try d.write(to:u,options:.atomic)}; try repo.transaction { $0 = state }; return repo }
        catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    private static func validExportPath(_ path:String)->Bool{path.range(of:"^(exports/[a-z0-9-]+/[A-Za-z0-9._-]+|drafts/[a-z0-9-]+\\.txt)$",options:.regularExpression) != nil && !path.contains("..")}
    public func clearCache() throws { try ManagedInstallRules.authorizeWrite(repositoryRoot:root); let cache = root.appendingPathComponent("cache"); if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) } }
}
