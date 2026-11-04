import Foundation
import ImageIO
import SceneKit
import VideoCore

public struct ImportedModelPackage {
    public let resource: ModelDAEResource
    public let assets: [Asset]
}

/// Imports the original model and its exact texture closure. The caller saves
/// these returned assets in its normal database transaction and records rights.
public enum ModelPackageMedia {
    public static func importPackage(modelURL: URL, sourceRoot: URL, workspaceID: String, repository: Repository) throws -> ImportedModelPackage {
        let root = sourceRoot.standardizedFileURL
        guard !workspaceID.isEmpty, modelURL.pathExtension.lowercased() == "dae" else { throw VideoError.invalid("模型导入需要实际 DAE 与工作区") }
        let original = try bytes(modelURL, within: root, maximum: DAEInspector.maximumBytes)
        let inspection = try DAEInspector.inspect(original)
        var textures: [String: Data] = [:]
        var total = original.count
        for image in inspection.images {
            let alias = try DAEInspector.relativeTexturePath(image.relativePath)
            if textures[alias] != nil { continue }
            let data = try bytes(modelURL.deletingLastPathComponent().appendingPathComponent(alias), within: root, maximum: 32 * 1024 * 1024)
            try validatePNG(data)
            total += data.count
            guard total <= 128 * 1024 * 1024 else { throw VideoError.invalid("单个模型及其纹理超过128MiB") }
            textures[alias] = data
        }
        // All external bytes are checked before adding any content-addressed file.
        let model = try repository.ingest(original, name: modelURL.lastPathComponent, workspaceID: workspaceID, mediaType: "model3d")
        var assets = [model], references: [String: ModelAssetReference] = [:]
        for alias in textures.keys.sorted() {
            let asset = try repository.ingest(textures[alias]!, name: URL(fileURLWithPath: alias).lastPathComponent, workspaceID: workspaceID, mediaType: "image")
            assets.append(asset); references[alias] = ModelAssetReference(asset: asset)
        }
        let resource = ModelDAEResource(model: ModelAssetReference(asset: model), inspection: inspection, textures: references)
        try resource.validate(assets: assets)
        return ImportedModelPackage(resource: resource, assets: assets)
    }

    public static func load(_ resource: ModelDAEResource, workspaceID: String, repository: Repository, database: Database, commercial: Bool, now: Date = Date()) throws -> LoadedDAEModel {
        let assets = database.assets.filter { $0.workspaceID == workspaceID }
        try resource.validate(assets: assets)
        var bank: [String: Data] = [:]
        for id in resource.assetIDs {
            guard let asset = assets.first(where: { $0.id == id }), let proofID = asset.evidenceID,
                  let proof = database.evidence.first(where: { $0.id == proofID && $0.workspaceID == workspaceID }),
                  proof.assetID == id, proof.usable(commercial: commercial, now: now) else {
                throw VideoError.review("模型或纹理缺少本工作区有效来源确认")
            }
            let data = try Data(contentsOf: repository.assetURL(asset), options: .mappedIfSafe)
            guard data.count == asset.bytes, Codec.hash(data) == asset.hash else { throw VideoError.review("三维模型或纹理实际字节已变化") }
            bank[id] = data
        }
        let modelData = bank.removeValue(forKey: resource.model.assetID)!
        try resource.verify(modelData: modelData, textureDataByAssetID: bank)
        for data in bank.values { try validatePNG(data) }
        return try LoadedDAEModel(resource: resource, modelData: modelData, textureData: bank)
    }

    static func bytes(_ url: URL, within root: URL, maximum: Int) throws -> Data {
        let file = url.standardizedFileURL
        guard root.resolvingSymlinksInPath() == root, file.resolvingSymlinksInPath() == file,
              file.path.hasPrefix(root.path + "/"),
              (try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])).isRegularFile == true else {
            throw VideoError.permission("三维素材必须是所选来源目录内的普通文件")
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximum else { throw VideoError.invalid("模型或纹理文件为空或超出大小上限") }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count == size else { throw VideoError.conflict("模型导入期间源文件变化") }
        return data
    }

    static func validatePNG(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png", CGImageSourceGetCount(source) == 1,
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(w), (1...8192).contains(h), w * h <= 24_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
            throw VideoError.invalid("模型纹理不是可解码的有界单帧 PNG")
        }
    }
}

/// Keeps the private material directory alive for SceneKit's deferred textures.
/// It never receives arbitrary original filesystem URLs or a network grant.
public final class LoadedDAEModel {
    public let scene: SCNScene
    public let resource: ModelDAEResource
    private let directory: URL
    fileprivate init(resource: ModelDAEResource, modelData: Data, textureData: [String: Data]) throws {
        self.resource = resource
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("video-model-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for (alias, reference) in resource.textures {
                let target = directory.appendingPathComponent(alias)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try textureData[reference.assetID]!.write(to: target, options: .atomic)
            }
            let file = directory.appendingPathComponent("model.dae")
            try modelData.write(to: file, options: .atomic)
            guard let source = SCNSceneSource(data: modelData, options: nil) else { throw VideoError.invalid("SceneKit无法读取实际DAE") }
            scene = try source.scene(options: [.checkConsistency: true, .assetDirectoryURLs: [directory], .overrideAssetURLs: true,
                .convertToYUp: true, .convertUnitsToMeters: 1.0, .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.doNotPlay])
            var geometries = 0
            scene.rootNode.enumerateChildNodes { node, _ in if node.geometry != nil { geometries += 1 } }
            guard geometries > 0 else { throw VideoError.invalid("DAE未加载出实际网格，不能用占位模型替代") }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
