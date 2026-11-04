import Foundation
import ImageIO
import VideoCore

/// Immutable original bytes only. This value grants neither filesystem access
/// nor rights: the Host creates it after normal workspace/CAS/rights checks;
/// the service creates it from its invocation-bound, committed Core snapshot.
public struct RenderModelBank: Sendable {
    public let manifest: PluginModelBankManifest
    public let assets: [String: Data]
    public let inspections: [String: DAEInspection]

    init(scene: ModelScene3D, durationFrames: Int, assets original: [String: Data]) throws {
        let manifest = try PluginModelBankManifest(scene: scene, durationFrames: durationFrames)
        guard Set(original.keys) == Set(manifest.assets.map(\.assetID)) else {
            throw VideoError.permission("三维冻结字节库与当前场景的完整资源集合不符")
        }
        var assets: [String: Data] = [:], total = 0
        for reference in manifest.assets {
            guard let source = original[reference.assetID], source.count == reference.bytes,
                  Codec.hash(source) == reference.sha256 else {
                throw VideoError.review("三维冻结字节库的实际大小或原件摘要不符")
            }
            total += source.count
            guard total <= PluginModelBankRules.maximumTotalBytes else { throw VideoError.invalid("三维RPC字节库超过64MiB") }
            // Do not retain a mapped or externally mutable backing store.
            assets[reference.assetID] = source.withUnsafeBytes { bytes in
                Data(bytes: bytes.baseAddress!, count: bytes.count)
            }
        }
        var inspections: [String: DAEInspection] = [:]
        for instance in scene.instances {
            let resource = instance.resource
            guard let model = assets[resource.model.assetID] else { throw VideoError.notFound("三维原模型不在冻结字节库") }
            let textures = Dictionary(uniqueKeysWithValues: resource.assetIDs.filter { $0 != resource.model.assetID }.map { ($0, assets[$0]!) })
            try resource.verify(modelData: model, textureDataByAssetID: textures)
            inspections[resource.model.assetID] = try DAEInspector.inspect(model)
        }
        var pixels = 0
        for reference in manifest.assets where reference.fileExtension == "png" {
            let data = assets[reference.assetID]!
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString:Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...8192).contains(width), (1...8192).contains(height), width * height <= PluginProtocolRules.maximumImagePixels else {
                throw VideoError.invalid("三维RPC原纹理的展开尺寸不合法")
            }
            pixels += width * height
            guard pixels <= PluginProtocolRules.maximumTotalImagePixels else { throw VideoError.invalid("三维RPC纹理总展开像素超过48M") }
            try ModelPackageMedia.validatePNG(data)
        }
        self.manifest = manifest; self.assets = assets; self.inspections = inspections
    }

    init(snapshot: PluginModelBankSnapshot) {
        manifest = snapshot.manifest; assets = snapshot.assets; inspections = snapshot.inspections
    }

    static func load(scene: VideoCore.Scene, workspaceID: String, repository: Repository,
                     database: Database, commercial: Bool, now: Date) throws -> RenderModelBank? {
        guard let model = scene.modelScene3D else { return nil }
        try ModelScene3DRules.validate(scene: scene, assets: database.assets.filter { $0.workspaceID == workspaceID })
        _ = try PluginModelBankManifest(scene: model, durationFrames: scene.durationFrames)
        var assets: [String: Data] = [:], checked: [ModelDAEResource] = []
        for instance in model.instances {
            if checked.contains(instance.resource) { continue }
            let verified = try ModelPackageMedia.verifiedByteClosure(instance.resource, workspaceID: workspaceID,
                repository: repository, database: database, commercial: commercial, now: now)
            for (id, bytes) in verified {
                guard assets[id] == nil || assets[id] == bytes else { throw VideoError.conflict("同一三维素材在冻结期间发生变化") }
                assets[id] = bytes
            }
            checked.append(instance.resource)
        }
        return try RenderModelBank(scene: model, durationFrames: scene.durationFrames, assets: assets)
    }
}

/// One invocation's bounded upload receipts, not an authorization cache. Every
/// frame still checks its live Host invocation and the service's scene closure.
struct PluginModelBankTransfer {
    private var accepted: [(reference: PluginModelBankReference, bytes: Int)] = []

    mutating func reference(bank: RenderModelBank, scene: ModelScene3D, durationFrames: Int,
                            invocation: PluginInvocation, check: () throws -> Void,
                            exchange: (PluginModelBankOperation) throws -> PluginRPCResponse) throws -> PluginModelBankReference {
        try check()
        let expected = try PluginModelBankManifest(scene: scene, durationFrames: durationFrames)
        guard expected == bank.manifest else { throw VideoError.permission("三维上传字节库不属于当前场景资源闭包") }
        let digest = try expected.contentDigest(), invocationDigest = try Codec.digest(invocation)
        guard accepted.allSatisfy({ $0.reference.invocationDigest == invocationDigest }) else {
            throw VideoError.permission("三维上传回执不能跨完整调用复用")
        }
        if let previous = accepted.first(where: { $0.reference.manifestDigest == digest }) {
            try check(); return previous.reference
        }
        // Preserve the existing two-bank service bound. The old value is no
        // longer needed by this serial Host frame; a running service task owns
        // an independent immutable snapshot and cannot be changed by release.
        while accepted.count == PluginModelBankRules.maximumBanks || expected.totalBytes > PluginModelBankRules.maximumTotalBytes - accepted.reduce(0, { $0 + $1.bytes }) {
            let oldest = accepted.removeFirst()
            try check()
            let response = try exchange(.init(kind: .release, invocation: invocation, bankID: oldest.reference.bankID))
            guard response.ok, response.error == nil, let receipt = response.modelBankReceipt, receipt.reference == oldest.reference,
                  receipt.state == .released, receipt.receivedBytes == oldest.bytes, receipt.totalBytes == oldest.bytes,
                  response.task == nil, response.cost?.actual == Money(0, invocation.currency), response.cost?.budgetReference == invocation.budgetReference else {
                throw VideoError.permission("三维字节库释放回执不属于原冻结调用")
            }
        }
        let reference = PluginModelBankReference(bankID: Codec.id(), manifestDigest: digest, invocationDigest: invocationDigest)
        let total = expected.totalBytes
        var received = 0
        func verify(_ response: PluginRPCResponse, state: PluginModelBankState, bytes: Int) throws {
            guard response.ok, response.error == nil, response.task == nil,
                  let receipt = response.modelBankReceipt, receipt.reference == reference,
                  receipt.state == state, receipt.receivedBytes == bytes, receipt.totalBytes == total,
                  response.cost?.actual == Money(0, invocation.currency), response.cost?.budgetReference == invocation.budgetReference else {
                throw VideoError.permission("三维分块字节库回执的原件、调用或字节计数不符")
            }
        }
        try check()
        try verify(exchange(.init(kind: .begin, invocation: invocation, bankID: reference.bankID, manifest: expected)), state: .receiving, bytes: 0)
        for asset in expected.assets {
            guard let data = bank.assets[asset.assetID], data.count == asset.bytes, Codec.hash(data) == asset.sha256 else {
                throw VideoError.review("三维上传原件与冻结清单不符")
            }
            var offset = 0
            while offset < data.count {
                try check()
                let end = min(data.count, offset + PluginModelBankRules.maximumChunkBytes), chunk = data.subdata(in: offset..<end)
                received += chunk.count
                try verify(exchange(.init(kind: .append, invocation: invocation, bankID: reference.bankID,
                    assetID: asset.assetID, offset: offset, data: chunk, sha256: Codec.hash(chunk))), state: .receiving, bytes: received)
                offset = end
            }
        }
        try check()
        try verify(exchange(.init(kind: .commit, invocation: invocation, bankID: reference.bankID)), state: .ready, bytes: total)
        try check()
        accepted.append((reference, total))
        return reference
    }
}
