import Foundation
import Darwin
import CSQLite

/// Already signature-verified publisher declarations. This type grants no execution rights.
public struct ModuleCatalogPublication: Sendable {
    public var manifest: PluginManifest
    public var policy: CommercialPolicy
    public init(manifest: PluginManifest, policy: CommercialPolicy) {
        self.manifest = manifest; self.policy = policy
    }
}

/// Passive publisher review data. These declarations do not grant legal rights by themselves;
/// the publisher separately supplies the exact written approvals and matching source files.
public struct SourcePublicationFile: Codable, Equatable, Sendable {
    public var path: String
    public var bytes: Int
    public var sha256: String
    public init(path: String, bytes: Int, sha256: String) { self.path=path; self.bytes=bytes; self.sha256=sha256 }
}
public struct SourcePublicationApproval: Codable, Sendable {
    public var document: SourcePublicationFile
    public var approved: Bool
    public var reference: String
    public var reviewedBy: String
    public var reviewedAt: Date
    public init(document: SourcePublicationFile, approved: Bool, reference: String, reviewedBy: String, reviewedAt: Date) {
        self.document=document; self.approved=approved; self.reference=reference; self.reviewedBy=reviewedBy; self.reviewedAt=reviewedAt
    }
}
public struct ModuleSourcePublicationReview: Codable, Sendable {
    public var pluginID: String
    public var version: String
    public var sourceFiles: [SourcePublicationFile]
    public var inventoryDigest: String
    public var sourceLicense: SourcePublicationApproval
    public var upstreamRights: SourcePublicationApproval
    public init(pluginID: String, version: String, sourceFiles: [SourcePublicationFile], inventoryDigest: String, sourceLicense: SourcePublicationApproval, upstreamRights: SourcePublicationApproval) {
        self.pluginID=pluginID; self.version=version; self.sourceFiles=sourceFiles; self.inventoryDigest=inventoryDigest; self.sourceLicense=sourceLicense; self.upstreamRights=upstreamRights
    }
}
public struct SourcePublicationReview: Codable, Sendable {
    public var format = 1
    public var modules: [ModuleSourcePublicationReview]
    public init(modules: [ModuleSourcePublicationReview]) { self.modules=modules }
}

/// Deterministic publication checks shared by catalog generation and its read-only verifier.
/// Signing, persistent state and executable inspection remain publisher adapters.
public enum ModuleCatalogPublicationRules {
    /// Deliberate per-module source boundary. New implementation files require a boundary review,
    /// rather than silently widening an already approved source publication.
    public static func sourcePaths(pluginID: String,executionFormat:Int=1) throws -> Set<String> {
        guard [1,2].contains(executionFormat) else{throw VideoError.invalid("未知源码发布执行格式")}
        switch pluginID {
        case "video.game": return Set(["Sources/VideoGame/GameModule.swift","Sources/VideoGame/LICENSE"]+(executionFormat==2 ? ["Sources/VideoGamePlugin/main.swift"]:[]))
        case "video.cartoon": return Set(["Sources/VideoCartoon/CartoonModule.swift","Sources/VideoCartoon/LICENSE"]+(executionFormat==2 ? ["Sources/VideoCartoonPlugin/main.swift"]:[]))
        default: throw VideoError.permission("源码审查引用了未支持的模块；未声明源码开放")
        }
    }
    public static func isSourceApprovalPath(_ path: String) -> Bool {
        let parts=path.split(separator:"/",omittingEmptySubsequences:false)
        return parts.count>=3 && parts[0]=="release" && parts[1]=="source-reviews" && parts.allSatisfy {part in
            !part.isEmpty && part != "." && part != ".." && part.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$",options:.regularExpression) != nil
        } && (path.hasSuffix(".md") || path.hasSuffix(".txt"))
    }
    public static func sourceInventoryDigest(_ files: [SourcePublicationFile]) throws -> String {
        try Codec.digest(files.sorted{$0.path<$1.path})
    }
    /// Actual files come from the publisher's bounded read adapter, never from review claims.
    /// Signature generation is a later step; missing rights must fail before opening the Issuer.
    public static func approvedOpenSources(_ review: SourcePublicationReview, actualFiles: [SourcePublicationFile], version: String, now: Date = Date()) throws -> Set<String> {
        guard [1,2].contains(review.format), (1...2).contains(review.modules.count), Set(review.modules.map(\.pluginID)).count==review.modules.count,
              Set(actualFiles.map(\.path)).count==actualFiles.count, actualFiles.count<=(review.format==2 ? 10:8) else {
            throw VideoError.permission("源码审查的格式、模块或文件库存不合法；未声明源码开放")
        }
        func valid(_ file: SourcePublicationFile) -> Bool {
            (1...2*1024*1024).contains(file.bytes) && file.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil
        }
        guard actualFiles.allSatisfy(valid) else {throw VideoError.permission("源码审查的实际文件摘要或大小不合法")}
        let actual=Dictionary(uniqueKeysWithValues:actualFiles.map{($0.path,$0)})
        var expected=Set<String>(), approved=Set<String>()
        for module in review.modules {
            let paths=try sourcePaths(pluginID:module.pluginID,executionFormat:review.format)
            guard module.version==version, module.sourceFiles.count==paths.count, Set(module.sourceFiles.map(\.path))==paths,
                  module.sourceFiles.allSatisfy({valid($0) && actual[$0.path]==$0}),
                  module.inventoryDigest == (try sourceInventoryDigest(module.sourceFiles)),
                  module.sourceLicense.document.path != module.upstreamRights.document.path else {
                throw VideoError.permission("模块版本、源码库存或独立权利记录不匹配；未声明源码开放")
            }
            expected.formUnion(paths)
            for approval in [module.sourceLicense,module.upstreamRights] {
                guard approval.approved, isSourceApprovalPath(approval.document.path), valid(approval.document), actual[approval.document.path]==approval.document,
                      !approval.reference.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, approval.reference.utf8.count<=1000,
                      !approval.reviewedBy.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, approval.reviewedBy.utf8.count<=120,
                      approval.reviewedAt<=now.addingTimeInterval(300) else {
                    throw VideoError.permission("源码许可或上游权利尚无匹配的独立书面批准；未声明源码开放")
                }
                expected.insert(approval.document.path)
            }
            approved.insert(module.pluginID)
        }
        guard Set(actual.keys)==expected else {throw VideoError.permission("源码审查夹带、遗漏或重复实际文件；未声明源码开放")}
        return approved
    }
    public static func samePolicySemantics(_ lhs: CommercialPolicy, _ rhs: CommercialPolicy) -> Bool {
        lhs.pluginID == rhs.pluginID && lhs.version == rhs.version &&
            lhs.access == rhs.access && lhs.sourceVisibility == rhs.sourceVisibility
    }
    public static func validate(_ entries: [ModuleCatalogPublication], expectedCapabilities: [String: String], implementationDigest: String? = nil, now: Date = Date()) throws {
        let ids = entries.map { $0.manifest.id }
        guard !expectedCapabilities.isEmpty, expectedCapabilities.count <= 16,
              entries.count == expectedCapabilities.count, Set(ids).count == ids.count,
              Set(ids) == Set(expectedCapabilities.keys) else {
            throw VideoError.permission("发行目录须完整包含指定模块，拒绝缺项、重复或额外模块")
        }
        guard Set(entries.map { $0.manifest.implementationDigest }).count == 1 else {
            throw VideoError.conflict("同一发行目录的模块必须对应同一实际代码身份")
        }
        for entry in entries {
            let manifest = entry.manifest, policy = entry.policy
            guard manifest.abi == 1, manifest.minimumCore == 1,
                  manifest.inputSchema == 1, manifest.outputSchema == 1,
                  manifest.capabilities == [expectedCapabilities[manifest.id]!], manifest.permissions.isEmpty,
                  manifest.version.utf8.count <= 100,
                  manifest.version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?(?:\\+[A-Za-z0-9][A-Za-z0-9.-]*)?$", options: .regularExpression) != nil,
                  manifest.implementationDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  ["open", "closed"].contains(manifest.sourceVisibility),
                  policy.pluginID == manifest.id, policy.version > 0,
                  ["free", "paid"].contains(policy.access),
                  policy.sourceVisibility == manifest.sourceVisibility,
                  policy.updatedAt <= now.addingTimeInterval(300) else {
                throw VideoError.permission("发行目录的代码、ABI、能力、来源可见性或策略声明不合法")
            }
            if let implementationDigest, manifest.implementationDigest != implementationDigest {
                throw VideoError.conflict("发行目录不匹配指定实际构建或架构的代码身份")
            }
        }
    }

    /// Versions belong to individual modules. Rebuilding code need not change a commercial policy.
    /// An unchanged version reuses the complete previous policy, including its signed timestamp;
    /// changing access or source visibility requires a strictly newer version for that module.
    public static func reconcile(previous: [ModuleCatalogPublication]?, proposed: [ModuleCatalogPublication], expectedCapabilities: [String: String], implementationDigest: String, now: Date = Date()) throws -> [ModuleCatalogPublication] {
        try validate(proposed, expectedCapabilities: expectedCapabilities, implementationDigest: implementationDigest, now: now)
        guard let previous else { return proposed }
        try validate(previous, expectedCapabilities: expectedCapabilities, now: now)
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.manifest.id, $0) })
        return try proposed.map { entry in
            let prior = old[entry.manifest.id]!
            guard entry.policy.version >= prior.policy.version else {
                throw VideoError.permission("发行策略版本低于该模块已发布版本，未替换原目录")
            }
            guard entry.policy.version != prior.policy.version || samePolicySemantics(entry.policy, prior.policy) else {
                throw VideoError.conflict("同一模块的同版本策略存在不同内容；请提高策略版本，原目录保留")
            }
            var result = entry
            if entry.policy.version == prior.policy.version { result.policy = prior.policy }
            return result
        }
    }
}

/// Local rollback history only; an entry is never a licence or proof of payment. Callers must
/// verify the publisher signature and actual executable identity before observing a policy.
/// V1 contained version floors alone. Its unknown semantics are established only by a newly
/// verified declaration, never inferred from installation or an App entitlement.
public struct ModulePolicyHistory: Codable, Equatable, Sendable {
    public var format = 2
    public private(set) var versions: [String: Int]
    public private(set) var declarations: [String: CommercialPolicy]

    public init(legacyVersions: [String: Int] = [:]) throws {
        versions = legacyVersions; declarations = [:]
        try validate()
    }
    private func validate(now: Date = Date()) throws {
        guard format == 2, versions.count <= 128, declarations.count <= 128,
              versions.allSatisfy({ Self.validID($0.key) && $0.value > 0 }) else {
            throw VideoError.permission("高级策略历史损坏；未清空防回退记录")
        }
        for (id, policy) in declarations {
            try Self.validate(policy, now: now)
            guard id == policy.pluginID, versions[id] == policy.version else {
                throw VideoError.permission("高级策略语义与最高版本不一致；未重置历史")
            }
        }
    }
    public static func == (lhs: ModulePolicyHistory, rhs: ModulePolicyHistory) -> Bool {
        lhs.format == rhs.format && lhs.versions == rhs.versions &&
            lhs.declarations.count == rhs.declarations.count && lhs.declarations.allSatisfy { id, policy in
                guard let other = rhs.declarations[id] else { return false }
                return ModuleCatalogPublicationRules.samePolicySemantics(policy, other) && policy.updatedAt == other.updatedAt
            }
    }
    private static func validID(_ id: String) -> Bool {
        id.range(of: "^[a-z0-9][a-z0-9.-]{1,95}$", options: .regularExpression) != nil
    }
    private static func validate(_ policy: CommercialPolicy, now: Date) throws {
        guard validID(policy.pluginID), policy.version > 0,
              ["free", "paid", "disabled"].contains(policy.access),
              ["open", "closed"].contains(policy.sourceVisibility),
              policy.updatedAt <= now.addingTimeInterval(300) else {
            throw VideoError.permission("高级策略历史声明不合法")
        }
    }
    public static func decode(_ data: Data) throws -> ModulePolicyHistory {
        guard !data.isEmpty, data.count <= 65536, data.starts(with: Data("bplist00".utf8)) else {
            throw VideoError.permission("高级策略历史须为体积受限的二进制记录；未重置历史")
        }
        let decoder = PropertyListDecoder()
        if let legacy = try? decoder.decode([String: Int].self, from: data) {
            return try ModulePolicyHistory(legacyVersions: legacy)
        }
        do {
            let history = try decoder.decode(ModulePolicyHistory.self, from: data)
            try history.validate()
            return history
        } catch {
            throw VideoError.permission("高级策略历史损坏或版本不兼容；未重置防回退记录")
        }
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(self)
        guard data.count <= 65536 else { throw VideoError.invalid("高级策略历史超出保存上限") }
        return data
    }
    public func observing(_ policies: [CommercialPolicy], now: Date = Date()) throws -> ModulePolicyHistory {
        try validate(now: now)
        guard policies.count <= 16, Set(policies.map(\.pluginID)).count == policies.count else {
            throw VideoError.permission("策略声明重复或超限；原历史保留")
        }
        var result = self
        for policy in policies {
            try Self.validate(policy, now: now)
            let floor = result.versions[policy.pluginID] ?? 1
            guard policy.version >= floor else { throw VideoError.permission("策略低于已见最高版本；原历史保留") }
            if let previous = result.declarations[policy.pluginID], previous.version == policy.version {
                guard ModuleCatalogPublicationRules.samePolicySemantics(previous, policy) else {
                    throw VideoError.conflict("同版本策略的免费/付费或源码语义不同；请取得更高版本签名目录")
                }
                // A signature refresh or code relink cannot rewrite the original observation.
                continue
            }
            result.versions[policy.pluginID] = policy.version
            result.declarations[policy.pluginID] = policy
        }
        try result.validate(now: now)
        return result
    }
    /// Install/update/rollback merges both histories before publishing a generation. A newer
    /// legacy floor stays unknown rather than inheriting semantics from a superseded version.
    public func merging(_ other: ModulePolicyHistory) throws -> ModulePolicyHistory {
        try validate(); try other.validate()
        var result = self
        for (id, version) in other.versions {
            let previous = result.versions[id] ?? 0
            if version > previous {
                result.versions[id] = version
                result.declarations[id] = other.declarations[id]
            } else if version == previous, let incoming = other.declarations[id] {
                if let known = result.declarations[id] {
                    guard ModuleCatalogPublicationRules.samePolicySemantics(known, incoming) else {
                        throw VideoError.conflict("安装代存在同版本不同策略语义；原安装保留")
                    }
                } else { result.declarations[id] = incoming }
            }
        }
        try result.validate()
        return result
    }
}

/// Shared App/CLI adapter. The history is not part of a portable business backup, and is never
/// reset on a bad read. Installer generations explicitly merge it before activation.
public struct ModulePolicyHistoryFileStore: Sendable {
    public static let fileName = ".video-advanced-policy.plist"
    private let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }
    public func read(legacyVersions: [String: Int] = [:], additionalHistory: ModulePolicyHistory? = nil) throws -> ModulePolicyHistory {
        try ManagedReleaseRules.safeDirectory(root)
        let file = root.appendingPathComponent(Self.fileName), fm = FileManager.default
        let history: ModulePolicyHistory
        do {
            let attributes = try fm.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 0) == 1,
                  let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 65536 else {
                throw VideoError.permission("高级策略历史不是受限普通文件；未重置历史")
            }
            history = try ModulePolicyHistory.decode(Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            history = try ModulePolicyHistory()
        }
        let merged = try history.merging(ModulePolicyHistory(legacyVersions: legacyVersions))
        return try additionalHistory.map { try merged.merging($0) } ?? merged
    }
    @discardableResult public func observe(_ policies: [CommercialPolicy], legacyVersions: [String: Int] = [:], additionalHistory: ModulePolicyHistory? = nil) throws -> ModulePolicyHistory {
        try ManagedReleaseRules.safeDirectory(root)
        try ManagedInstallRules.authorizeWrite(repositoryRoot: root)
        let lock = root.appendingPathComponent(".video-advanced-policy.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw VideoError.unavailable("无法锁定高级策略历史") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw VideoError.unavailable("另一进程正在更新高级策略历史，请沿原任务重试")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try withRepositoryLock {
            // Installation holds the same SQLite write lock while snapshotting and switching
            // generations. Recheck after acquiring it, so a waiting old host cannot write a
            // newly inactive generation or lose a new observation during an install snapshot.
            try ManagedInstallRules.authorizeWrite(repositoryRoot: root)
            let result = try read(legacyVersions: legacyVersions, additionalHistory: additionalHistory).observing(policies)
            try result.encoded().write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
            return result
        }
    }
    private func withRepositoryLock<T>(_ action: () throws -> T) throws -> T {
        let databaseURL = root.appendingPathComponent("workspace.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return try action() }
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 0) == 1 else {
            throw VideoError.permission("策略历史所绑定的工程数据库不是普通文件")
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            if handle != nil { sqlite3_close(handle) }
            throw VideoError.unavailable("无法锁定策略历史所绑定的工程；未修改记录")
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 1000)
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw VideoError.unavailable("工程正在更新或迁移，请沿原任务重试；策略记录未变")
        }
        defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) }
        return try action()
    }
}
