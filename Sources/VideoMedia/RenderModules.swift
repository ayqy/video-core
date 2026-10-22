import Foundation
import CoreGraphics
import StoreKit
import VideoCore

/// The public SDK has no dependency on either premium implementation target.
/// Only modules statically linked by the signed iOS/CLI build are registered here.
public protocol SceneRenderModule: Sendable {
    var manifest: PluginManifest { get }
    func draw(scene: VideoCore.Scene, localFrame: Int, fps: Int, rect: CGRect, context: CGContext) throws
    func draw(scene: VideoCore.Scene, localFrame: Int, fps: Int, rect: CGRect, context: CGContext, resources: RenderResources) throws
}
public extension SceneRenderModule {
    func draw(scene: VideoCore.Scene, localFrame: Int, fps: Int, rect: CGRect, context: CGContext, resources: RenderResources) throws { try draw(scene:scene,localFrame:localFrame,fps:fps,rect:rect,context:context) }
}

public struct ModuleLicense: Codable, Equatable, Sendable {
    public var id: String
    public var subject: String
    public var pluginIDs: Set<String>
    public var issuedAt: Date
    public var expiresAt: Date?
    public var revoked: Bool
    public init(id: String, subject: String, pluginIDs: Set<String>, issuedAt: Date, expiresAt: Date? = nil, revoked: Bool = false) {
        self.id = id; self.subject = subject; self.pluginIDs = pluginIDs; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.revoked = revoked
    }
    public func validate(now: Date) throws {
        guard !id.isEmpty, !subject.isEmpty, !pluginIDs.isEmpty, issuedAt <= now.addingTimeInterval(300),
              !revoked, expiresAt == nil || expiresAt! > now,
              expiresAt == nil || expiresAt! > issuedAt else { throw VideoError.permission("独立高级模块许可证未生效、已过期或已撤销；原素材和历史工程仍可取回") }
    }
}

/// Stable digest of the executable's actual __TEXT,__text section, independently of module claims.
/// Omitting the code-signature blob avoids a manifest/resource sealing self-reference.
public struct BuiltinExecutableIdentity: Sendable {
    public let artifactPath: String
    public let digest: String
    private init(path: String, digest: String) { artifactPath = path; self.digest = digest }
    public static func current() throws -> BuiltinExecutableIdentity {
        guard let url = Bundle.main.executableURL else { throw VideoError.unavailable("无法定位当前签名程序的真实可执行文件，禁止登记高级模块") }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard !FileManager.default.fileExists(atPath:resolved.deletingLastPathComponent().appendingPathComponent(resolved.lastPathComponent+".debug.dylib").path) else {throw VideoError.unavailable("此调试构建把实现放入动态调试库，不能只校验入口摘要；请关闭ENABLE_DEBUG_DYLIB重建后使用签名目录")}
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= 1024 * 1024 * 1024 else { throw VideoError.permission("当前可执行文件不合法或超过校验上限") }
        return BuiltinExecutableIdentity(path: resolved.path, digest: try MachOCodeIdentity.digest(Data(contentsOf: resolved, options: .mappedIfSafe)))
    }
}

/// Bounded on-disk Mach-O parsing. No executable is loaded or run to inspect its identity.
public enum MachOCodeIdentity {
    public static var currentCPU: UInt32 {
        #if arch(arm64)
        return 0x0100000c
        #elseif arch(x86_64)
        return 0x01000007
        #else
        return 0
        #endif
    }
    public static func digest(_ data: Data, cpuType: UInt32 = currentCPU) throws -> String {
        guard data.count >= 32, [UInt32(0x0100000c), 0x01000007].contains(cpuType) else { throw VideoError.unavailable("仅支持arm64/x86_64 Mach-O高级模块") }
        let bytes = [UInt8](data)
        func u32(_ offset: Int, little: Bool) throws -> UInt32 {
            guard offset >= 0, offset <= bytes.count - 4 else { throw VideoError.invalid("Mach-O字段越界") }
            let values = Array(bytes[offset..<offset + 4]); return values.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32((little ? $1.offset : 3 - $1.offset) * 8) }
        }
        func u64(_ offset: Int, little: Bool) throws -> UInt64 {
            guard offset >= 0, offset <= bytes.count - 8 else { throw VideoError.invalid("Mach-O字段越界") }
            let values = Array(bytes[offset..<offset + 8]); return values.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64((little ? $1.offset : 7 - $1.offset) * 8) }
        }
        let magic = try u32(0, little: false)
        var base = 0, length = data.count
        if [UInt32(0xcafebabe), 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) {
            let little = magic == 0xbebafeca || magic == 0xbfbafeca
            let fat64 = magic == 0xcafebabf || magic == 0xbfbafeca
            let count = Int(try u32(4, little: little)), stride = fat64 ? 32 : 20
            guard (1...32).contains(count), 8 + count * stride <= data.count else { throw VideoError.invalid("Mach-O fat架构表不合法") }
            var selected: (Int, Int)?
            for index in 0..<count {
                let offset = 8 + index * stride
                let cpu = try u32(offset, little: little)
                let sliceOffset = fat64 ? try u64(offset + 8, little: little) : UInt64(try u32(offset + 8, little: little))
                let sliceSize = fat64 ? try u64(offset + 16, little: little) : UInt64(try u32(offset + 12, little: little))
                guard sliceOffset >= UInt64(8 + count * stride), sliceOffset <= UInt64(data.count), sliceSize >= 32, sliceSize <= UInt64(data.count) - sliceOffset else { throw VideoError.invalid("Mach-O fat切片越界") }
                if cpu == cpuType {
                    guard selected == nil else { throw VideoError.invalid("Mach-O含重复当前架构，无法确定实现身份") }
                    selected = (Int(sliceOffset), Int(sliceSize))
                }
            }
            guard let selected else { throw VideoError.unavailable("Mach-O不含当前运行架构") }
            base = selected.0; length = selected.1
        }
        let thinMagic = try u32(base, little: true)
        guard thinMagic == 0xfeedfacf || thinMagic == 0xcffaedfe else { throw VideoError.invalid("高级模块身份要求64位Mach-O") }
        let little = thinMagic == 0xfeedfacf
        guard try u32(base + 4, little: little) == cpuType else { throw VideoError.permission("Mach-O架构与当前进程不一致") }
        let count = Int(try u32(base + 16, little: little)), commandBytes = Int(try u32(base + 20, little: little))
        guard count > 0, count <= 65536, commandBytes >= 8, commandBytes <= length - 32 else { throw VideoError.invalid("Mach-O加载命令表越界") }
        let commandEnd = base + 32 + commandBytes
        func name(_ offset: Int) throws -> String {
            guard offset >= base, offset + 16 <= base + length else { throw VideoError.invalid("Mach-O段名称越界") }
            return String(decoding: bytes[offset..<offset + 16].prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        var cursor = base + 32, text: Range<Int>?
        for _ in 0..<count {
            guard cursor + 8 <= commandEnd else { throw VideoError.invalid("Mach-O命令头越界") }
            let command = try u32(cursor, little: little), size = Int(try u32(cursor + 4, little: little))
            guard size >= 8, size % 8 == 0, size <= commandEnd - cursor else { throw VideoError.invalid("Mach-O命令长度不合法") }
            if command == 0x19 { // LC_SEGMENT_64
                guard size >= 72 else { throw VideoError.invalid("Mach-O段命令损坏") }
                let sections = Int(try u32(cursor + 64, little: little))
                guard sections <= 65536, 72 + sections * 80 <= size else { throw VideoError.invalid("Mach-O节表越界") }
                if try name(cursor + 8) == "__TEXT" {
                    for section in 0..<sections {
                        let start = cursor + 72 + section * 80
                        if try name(start) == "__text", try name(start + 16) == "__TEXT" {
                            let bytesCount = try u64(start + 40, little: little), fileOffset = UInt64(try u32(start + 48, little: little))
                            guard text == nil, bytesCount > 0, fileOffset >= UInt64(32 + commandBytes), fileOffset <= UInt64(length), bytesCount <= UInt64(length) - fileOffset else { throw VideoError.invalid("Mach-O代码节重复、为空或越界") }
                            text = (base + Int(fileOffset))..<(base + Int(fileOffset + bytesCount))
                        }
                    }
                }
            }
            cursor += size
        }
        guard cursor == commandEnd, let text else { throw VideoError.invalid("Mach-O缺少唯一__TEXT,__text代码节") }
        return Codec.hash(data.subdata(in: text))
    }
}

public struct RenderModuleStatus: Codable, Equatable, Sendable {
    public var pluginID: String; public var version: String; public var capabilities: [String]
    public var access: String; public var sourceVisibility: String; public var expiresAt: Date?
    public var policyVersion: Int; public var implementationDigest: String
}

public struct RenderModuleCatalogEntry: Codable, Sendable {
    public var manifest: SignedDocument; public var policy: SignedDocument
    public init(manifest: SignedDocument, policy: SignedDocument) { self.manifest = manifest; self.policy = policy }
}
public struct RenderModuleCatalog: Codable, Sendable {
    public var format = 1
    public var entries: [RenderModuleCatalogEntry]
    public init(entries: [RenderModuleCatalogEntry]) { self.entries = entries }
}
public struct VerifiedRenderCatalogEntry: Sendable {
    public var signed: RenderModuleCatalogEntry
    public var manifest: PluginManifest
    public var policy: CommercialPolicy
}
public struct RenderCatalogSelection: Sendable {
    public enum Source: String, Sendable { case imported, bundled }
    public var source: Source
    public var entries: [VerifiedRenderCatalogEntry]
    public var diagnostics: [String]
}
/// A stale imported catalog never masks a valid catalog delivered with an App update.
/// Each candidate independently passes the same pinned-key, current-code and policy checks.
public enum RenderCatalogResolver {
    public static func verify(_ data: Data, publicKey: Data, implementationDigest: String, minimumPolicyVersions: [String: Int], supportedCapabilities: [String: String], policyHistory: ModulePolicyHistory? = nil, now: Date = Date()) throws -> [VerifiedRenderCatalogEntry] {
        guard data.count <= 2 * 1024 * 1024, data.starts(with: Data("bplist00".utf8)) else { throw VideoError.invalid("目录须为不超过2MiB的二进制PropertyList封套") }
        let catalog: RenderModuleCatalog
        do { catalog = try PropertyListDecoder().decode(RenderModuleCatalog.self, from: data) }
        catch { throw VideoError.invalid("高级模块目录格式损坏") }
        guard catalog.format == 1, !supportedCapabilities.isEmpty,
              catalog.entries.count == supportedCapabilities.count, catalog.entries.count <= 16 else { throw VideoError.invalid("高级模块目录须完整包含本Host支持的模块集合") }
        var seen: Set<String> = []
        let verified = try catalog.entries.map { entry in
            let manifest = try entry.manifest.verified(as: PluginManifest.self, publicKey: publicKey)
            let policy = try entry.policy.verified(as: CommercialPolicy.self, publicKey: publicKey)
            guard let capability = supportedCapabilities[manifest.id], seen.insert(manifest.id).inserted,
                  manifest.abi == 1, manifest.minimumCore <= 1, manifest.inputSchema == 1, manifest.outputSchema == 1,
                  manifest.permissions.isEmpty, manifest.capabilities == [capability], ["open", "closed"].contains(manifest.sourceVisibility),
                  policy.pluginID == manifest.id, ["free", "paid", "disabled"].contains(policy.access),
                  ["open", "closed"].contains(policy.sourceVisibility), policy.updatedAt <= now.addingTimeInterval(300) else {
                throw VideoError.permission("模块目录的ABI、能力、权限或策略声明不合法")
            }
            guard policy.version >= max(1, minimumPolicyVersions[manifest.id] ?? 1) else { throw VideoError.permission("目录策略版本低于已知最高版本，拒绝回退") }
            guard manifest.implementationDigest == implementationDigest, !implementationDigest.isEmpty else { throw VideoError.conflict("目录不匹配当前构建或架构的代码身份") }
            return VerifiedRenderCatalogEntry(signed: entry, manifest: manifest, policy: policy)
        }
        if let policyHistory { _ = try policyHistory.observing(verified.map(\.policy), now: now) }
        return verified
    }
    public static func select(imported: Data?, bundled: Data?, publicKey: Data, implementationDigest: String, minimumPolicyVersions: [String: Int], supportedCapabilities: [String: String], policyHistory: ModulePolicyHistory? = nil, now: Date = Date()) throws -> RenderCatalogSelection {
        var diagnostics: [String] = []
        for (source, data) in [(RenderCatalogSelection.Source.imported, imported), (.bundled, bundled)] {
            guard let data else { continue }
            do {
                let entries = try verify(data, publicKey: publicKey, implementationDigest: implementationDigest, minimumPolicyVersions: minimumPolicyVersions, supportedCapabilities: supportedCapabilities, policyHistory: policyHistory, now: now)
                return RenderCatalogSelection(source: source, entries: entries, diagnostics: diagnostics)
            } catch {
                let reason = (error as? VideoError)?.localizedDescription ?? "签名或格式校验失败"
                diagnostics.append((source == .imported ? "导入目录" : "包内目录") + "未启用：" + reason)
            }
        }
        throw VideoError.unavailable(diagnostics.isEmpty ? "尚未安装与本构建匹配的签名高级目录；免费基础继续可用" : diagnostics.joined(separator: "；"))
    }
}

/// Local policy enforcement is not a claim of unbreakable DRM in a user-modifiable open Host.
/// No dynamic loader, executable download or third-party credential access is provided.
public final class RenderModuleRegistry: @unchecked Sendable {
    private struct StoreAccess: Sendable {
        var pluginID: String; var productID: String; var purchaseDate: Date; var expiresAt: Date?
        var revokedAt: Date?; var upgraded: Bool
        func validate(now: Date) throws {
            guard revokedAt == nil, !upgraded, purchaseDate <= now.addingTimeInterval(300), expiresAt == nil || expiresAt! > now else { throw VideoError.permission("商店高级模块权益已撤销、被替代、过期或尚未生效") }
        }
    }
    private struct Entry: Sendable {
        var module: any SceneRenderModule
        var policy: CommercialPolicy
        var license: ModuleLicense?
        var storeAccess: StoreAccess?
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var highestPolicy: [String: Int] = [:]
    // Persistent hosts keep version floors separately. This semantic history also survives
    // unregister within this registry; it does not claim cross-process content persistence.
    private var highestPolicyDeclarations: [String: CommercialPolicy] = [:]
    public init() {}
    public static func capability(for kind: SceneKind) -> String? {
        switch kind { case .simulation: return "game.simulate"; case .cartoon: return "cartoon.animate"; default: return nil }
    }
    /// Signature -> independent executable hash -> ABI/permissions -> commercial access.
    /// The caller persists the highest policy version to retain rollback protection across launches.
    public func register(_ module: any SceneRenderModule, signedManifest: SignedDocument, signedPolicy: SignedDocument, signedLicense: SignedDocument? = nil, publicKey: Data, grantedPermissions: Set<String> = [], minimumPolicyVersion: Int = 1, now: Date = Date()) throws {
        try registerVerified(module, signedManifest: signedManifest, signedPolicy: signedPolicy, signedLicense: signedLicense, storeAccess: nil, publicKey: publicKey, grantedPermissions: grantedPermissions, minimumPolicyVersion: minimumPolicyVersion, now: now)
    }
    public static func storeProduct(for pluginID: String) -> String? {
        switch pluginID { case "video.game": return "com.ayqy.video.game"; case "video.cartoon": return "com.ayqy.video.cartoon"; default: return nil }
    }
    /// No string/Bool entitlement constructor exists. StoreKit must supply a verified Transaction.
    public func registerStoreKit(_ module: any SceneRenderModule, signedManifest: SignedDocument, signedPolicy: SignedDocument, transaction: VerificationResult<StoreKit.Transaction>, publicKey: Data, grantedPermissions: Set<String> = [], minimumPolicyVersion: Int = 1, now: Date = Date()) throws {
        guard case .verified(let verified) = transaction,
              let expected = Self.storeProduct(for: module.manifest.id), verified.productID == expected,
              verified.appBundleID == Bundle.main.bundleIdentifier,
              verified.productType == .nonConsumable || verified.productType == .autoRenewable else {
            throw VideoError.permission("商店交易未验证、商品/应用不匹配；编辑器权益不替代独立高级模块")
        }
        let access = StoreAccess(pluginID: module.manifest.id, productID: verified.productID, purchaseDate: verified.purchaseDate, expiresAt: verified.expirationDate, revokedAt: verified.revocationDate, upgraded: verified.isUpgraded)
        try access.validate(now: now)
        try registerVerified(module, signedManifest: signedManifest, signedPolicy: signedPolicy, signedLicense: nil, storeAccess: access, publicKey: publicKey, grantedPermissions: grantedPermissions, minimumPolicyVersion: minimumPolicyVersion, now: now)
    }
    private func registerVerified(_ module: any SceneRenderModule, signedManifest: SignedDocument, signedPolicy: SignedDocument, signedLicense: SignedDocument?, storeAccess: StoreAccess?, publicKey: Data, grantedPermissions: Set<String>, minimumPolicyVersion: Int, now: Date) throws {
        let manifest = try signedManifest.verified(as: PluginManifest.self, publicKey: publicKey)
        let policy = try signedPolicy.verified(as: CommercialPolicy.self, publicKey: publicKey)
        guard manifest == module.manifest, manifest.id.range(of: "^[a-z0-9][a-z0-9.-]{1,95}$", options: .regularExpression) != nil,
              !manifest.version.isEmpty, !manifest.capabilities.isEmpty,
              Set(manifest.capabilities).count == manifest.capabilities.count,
              ["open", "closed"].contains(manifest.sourceVisibility),
              policy.version >= max(1, minimumPolicyVersion), policy.updatedAt <= now.addingTimeInterval(300) else {
            throw VideoError.permission("模块manifest、发布策略版本或声明与可信目录不一致")
        }
        let identity = try BuiltinExecutableIdentity.current()
        var license: ModuleLicense?
        if policy.access == "paid" {
            if let storeAccess { guard storeAccess.pluginID == manifest.id else { throw VideoError.permission("商店模块权益不匹配") }; try storeAccess.validate(now: now) }
            else {
                guard let signedLicense else { throw VideoError.permission("需要此高级模块的独立许可证；App编辑器权益不能代替CLI插件权益") }
                let verified = try signedLicense.verified(as: ModuleLicense.self, publicKey: publicKey)
                try verified.validate(now: now); license = verified
            }
        }
        let entitlementIDs = storeAccess.map { Set([$0.pluginID]) } ?? license?.pluginIDs ?? []
        try PluginHost.validate(manifest: manifest, policy: policy, installedDigest: identity.digest, entitlements: entitlementIDs, grantedPermissions: grantedPermissions)
        lock.lock(); defer { lock.unlock() }
        guard policy.version >= (highestPolicy[manifest.id] ?? minimumPolicyVersion) else { throw VideoError.permission("拒绝回退到较旧的商业策略，请刷新签名目录") }
        if let previous = highestPolicyDeclarations[manifest.id], previous.version == policy.version {
            guard ModuleCatalogPublicationRules.samePolicySemantics(previous, policy) else { throw VideoError.permission("同一高级模块的同版本发布策略内容冲突，请刷新签名目录") }
        }
        for (id, entry) in entries where id != manifest.id {
            guard Set(entry.module.manifest.capabilities).isDisjoint(with: manifest.capabilities) else { throw VideoError.conflict("同一能力不能被多个模块静默覆盖") }
        }
        highestPolicy[manifest.id] = policy.version
        highestPolicyDeclarations[manifest.id] = policy
        entries[manifest.id] = Entry(module: module, policy: policy, license: license, storeAccess: storeAccess)
    }
    public func unregister(_ pluginID: String) { lock.lock(); defer { lock.unlock() }; entries.removeValue(forKey: pluginID) }
    public func status(now: Date = Date()) -> [RenderModuleStatus] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.sorted { $0.module.manifest.id < $1.module.manifest.id }.map { entry in
            let manifest = entry.module.manifest
            let active = (try? validateEntry(entry, now: now)) != nil
            return RenderModuleStatus(pluginID: manifest.id, version: manifest.version, capabilities: manifest.capabilities, access: active ? entry.policy.access : "expired", sourceVisibility: entry.policy.sourceVisibility, expiresAt: entry.license?.expiresAt ?? entry.storeAccess?.expiresAt, policyVersion: entry.policy.version, implementationDigest: manifest.implementationDigest)
        }
    }
    public func policyVersions() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return highestPolicy }
    private func validateEntry(_ entry: Entry, now: Date) throws {
        if entry.policy.access == "free" { return }
        guard entry.policy.access == "paid" else { throw VideoError.permission("此高级模块已禁用") }
        if let store = entry.storeAccess { try store.validate(now: now) }
        else if let license = entry.license { try license.validate(now: now) }
        else { throw VideoError.permission("高级模块授权缺失") }
    }
    @discardableResult public func validate(kind: SceneKind, now: Date = Date()) throws -> RenderModuleStatus {
        guard let capability = Self.capability(for: kind) else { throw VideoError.invalid("普通图文/素材镜头不需要高级模块") }
        lock.lock(); let entry = entries.values.first { $0.module.manifest.capabilities.contains(capability) }; lock.unlock()
        guard let entry else { throw VideoError.unavailable("缺少已校验的独立能力：\(capability)。请核对模块目录与独立权益，或使用免费图文/真实素材。") }
        try validateEntry(entry, now: now)
        let manifest = entry.module.manifest
        return RenderModuleStatus(pluginID: manifest.id, version: manifest.version, capabilities: manifest.capabilities, access: entry.policy.access, sourceVisibility: entry.policy.sourceVisibility, expiresAt: entry.license?.expiresAt ?? entry.storeAccess?.expiresAt, policyVersion: entry.policy.version, implementationDigest: manifest.implementationDigest)
    }
    public func draw(scene: VideoCore.Scene, localFrame: Int, fps: Int, rect: CGRect, context: CGContext, resources: RenderResources = .empty, now: Date = Date()) throws {
        guard let capability = Self.capability(for: scene.kind) else { throw VideoError.invalid("普通图文/素材镜头不需要高级模块") }
        guard localFrame >= 0, fps > 0, fps <= 120, rect.width.isFinite, rect.height.isFinite, rect.minX.isFinite, rect.minY.isFinite, rect.width > 0, rect.height > 0 else { throw VideoError.invalid("高级模块绘制的时间或画布无效") }
        lock.lock(); let entry = entries.values.first { $0.module.manifest.capabilities.contains(capability) }; lock.unlock()
        guard let entry else { throw VideoError.unavailable("缺少已校验的独立能力：\(capability)。请安装此构建对应的签名模块目录并核对权益，或改用免费图文/真实素材镜头。") }
        try validateEntry(entry, now: now)
        context.saveGState(); defer { context.restoreGState() }; context.clip(to: rect)
        try entry.module.draw(scene: scene, localFrame: localFrame, fps: fps, rect: rect, context: context, resources: resources)
    }
}
