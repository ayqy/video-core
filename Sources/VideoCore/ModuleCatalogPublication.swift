import Foundation

/// Already signature-verified publisher declarations. This type grants no execution rights.
public struct ModuleCatalogPublication: Sendable {
    public var manifest: PluginManifest
    public var policy: CommercialPolicy
    public init(manifest: PluginManifest, policy: CommercialPolicy) {
        self.manifest = manifest; self.policy = policy
    }
}

/// Deterministic publication checks shared by catalog generation and its read-only verifier.
/// Signing, persistent state and executable inspection remain publisher adapters.
public enum ModuleCatalogPublicationRules {
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
