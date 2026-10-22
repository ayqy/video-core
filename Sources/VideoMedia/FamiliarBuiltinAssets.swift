import Foundation
import AVFoundation
import ImageIO
import VideoCore

/// This importer verifies fixed upstream files. It does not grant commercial IP rights.
public struct FamiliarImportedSources: Sendable {
    public var assetsByName: [String: Asset]
    public var sources: [ClassicSource]
    public var audioAssets: [Asset]
}

public struct FamiliarImportedPack: Sendable {
    public var mario: ClassicArtwork
    public var audioAssets: [Asset]
}

public enum FamiliarBuiltinAssets {
    public static let upstreamCommit = "1dcf623d5b3829e6a2efea93c387e81b1a3c6864"
    private static let upstream = "https://raw.githubusercontent.com/robertkleffner/mariohtml5/" + upstreamCommit + "/"
    private static let owner = "Nintendo（游戏形象及声音权利待核）；robertkleffner（仓库发布来源）"
    private static let pendingLicense = "仓库软件为Unlicense；Nintendo角色、场景、声音及其Q版派生的商业权利待核"
    private static let verifiedClaim = "仅已核验具体文件来自固定GitHub提交且SHA-256相符；软件Unlicense不证明Nintendo角色、场景或声音的商用权利，当前未获商用确认。"
    private struct File {
        let name: String
        let path: String
        let bytes: Int
        let hash: String
        let type: String
        var source: String { FamiliarBuiltinAssets.upstream + path }
    }
    private static let files: [File] = [
        File(name: "smallmariosheet.png", path: "images/smallmariosheet.png", bytes: 1464, hash: "0412e72195d4cc2533a6830676f867f74cbb265ab05b6a58794dde05be9d31a8", type: "image"),
        File(name: "mariosheet.png", path: "images/mariosheet.png", bytes: 5746, hash: "cf38841927c063a9afc3b82769368bfff0c794eb81fabfba9b195e274f7e8438", type: "image"),
        File(name: "mapsheet.png", path: "images/mapsheet.png", bytes: 13436, hash: "48f0c21c49e853fc952cfc29f85b52601698b420eb796336515d094ffd742461", type: "image"),
        File(name: "bgsheet.png", path: "images/bgsheet.png", bytes: 15103, hash: "f47e33f87ab545c2f21ddac67b8cffe5e4ceec9af360b5be1bb86c049445d917", type: "image"),
        File(name: "jump.wav", path: "sounds/jump.wav", bytes: 2725, hash: "81979d1da763c20985abdb996851c205603f28eed6ab0fd6f96c543c65dbcbb5", type: "audio"),
        File(name: "coin.wav", path: "sounds/coin.wav", bytes: 4314, hash: "56e5dcf57892733282d35af689c973b7e91e46f3d08d5617fee9679bc2017ff7", type: "audio")
    ]
    private static let texts: [File] = [
        File(name: "LICENSE.md", path: "LICENSE.md", bytes: 1221, hash: "30005f79f9251ef6b0ee3c6d87d73532371c526159d099dc84f45d21966bda25", type: "text"),
        File(name: "README", path: "README", bytes: 370, hash: "8d4b4873ec86fe973f8171125ced19b25414477d203991edf68f9510c8929c42", type: "text"),
        File(name: "mario-sources.md", path: "", bytes: 3931, hash: "2fa20640e1da3417613149cedb394161dbe9c0158b8b23986f7f3cb459078283", type: "text")
    ]

    public static func importPack(bundle: Bundle = .main, workspaceID: String, repository: Repository) throws -> FamiliarImportedPack {
        pack(from: try importSources(bundle: bundle, workspaceID: workspaceID, repository: repository))
    }

    public static func importPack(from directory: URL, workspaceID: String, repository: Repository) throws -> FamiliarImportedPack {
        pack(from: try importSources(from: directory, workspaceID: workspaceID, repository: repository))
    }

    private static func pack(from imported: FamiliarImportedSources) -> FamiliarImportedPack {
        // Only downloaded originals are present in this version. No Q-style transformation is claimed.
        let hero = imported.assetsByName["smallmariosheet.png"]!
        let tiles = imported.assetsByName["mapsheet.png"]!
        let background = imported.assetsByName["bgsheet.png"]!
        let sprites = [
            ClassicSprite(role: "hero", assetID: hero.id, width: 16.0 / 176.0),
            ClassicSprite(role: "crate", assetID: tiles.id, x: 80.0 / 256.0, y: 16.0 / 256.0, width: 16.0 / 256.0, height: 16.0 / 256.0),
            ClassicSprite(role: "wall", assetID: tiles.id, y: 16.0 / 256.0, width: 16.0 / 256.0, height: 16.0 / 256.0),
            ClassicSprite(role: "floor", assetID: tiles.id, y: 128.0 / 256.0, width: 48.0 / 256.0, height: 48.0 / 256.0),
            ClassicSprite(role: "coin", assetID: tiles.id, y: 32.0 / 256.0, width: 16.0 / 256.0, height: 16.0 / 256.0),
            ClassicSprite(role: "backdrop", assetID: background.id, width: 128.0 / 256.0, height: 128.0 / 320.0)
        ]
        let originalIDs = files.filter { $0.type == "image" }.compactMap { imported.assetsByName[$0.name]?.id }
        let artwork = ClassicArtwork(gameplay: .platformer, sprites: sprites, sources: imported.sources,
                                     derivation: .original, transformation: "", originalAssetIDs: originalIDs)
        return FamiliarImportedPack(mario: artwork, audioAssets: imported.audioAssets)
    }

    public static func importSources(bundle: Bundle = .main, workspaceID: String, repository: Repository) throws -> FamiliarImportedSources {
        try importSources(workspaceID: workspaceID, repository: repository) { name in
            let file = name as NSString
            guard let url = bundle.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension.isEmpty ? nil : file.pathExtension, subdirectory: "Familiar")
                ?? bundle.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension.isEmpty ? nil : file.pathExtension) else {
                throw VideoError.notFound("熟悉游戏素材未安装：" + name)
            }
            return url
        }
    }

    /// This accepts only this source pack's exact, bounded allowlist, never an arbitrary manifest or executable.
    public static func importSources(from directory: URL, workspaceID: String, repository: Repository) throws -> FamiliarImportedSources {
        try importSources(workspaceID: workspaceID, repository: repository) { directory.appendingPathComponent($0) }
    }

    private static func checkedData(_ url: URL, file: File) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == file.bytes,
              file.bytes > 0, file.bytes <= 8 * 1024 * 1024 else {
            throw VideoError.invalid("熟悉游戏素材须为相符大小的普通文件：" + file.name)
        }
        let data = try Data(contentsOf: url)
        guard data.count == file.bytes, Codec.hash(data) == file.hash else {
            throw VideoError.review("熟悉游戏素材或来源文本摘要不符：" + file.name)
        }
        if file.type == "image" {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 24_000_000 else {
                throw VideoError.invalid("熟悉游戏图像损坏或超出安全尺寸：" + file.name)
            }
        } else if file.type == "text", String(data: data, encoding: .utf8) == nil {
            throw VideoError.invalid("熟悉游戏来源文本不是UTF-8：" + file.name)
        }
        return data
    }

    private static func importSources(workspaceID: String, repository: Repository, url: (String) throws -> URL) throws -> FamiliarImportedSources {
        guard try repository.read().workspaces.contains(where: { $0.id == workspaceID }) else {
            throw VideoError.permission("熟悉游戏素材只能导入当前已有工作区")
        }
        // Capture and verify the entire allowlist before writing CAS or database records.
        var checked: [String: Data] = [:]
        for file in texts + files { checked[file.name] = try checkedData(url(file.name), file: file) }
        var rightsData = Data("熟悉游戏原件来源核对；商业权利待核\n\n".utf8)
        for file in texts {
            rightsData.append(Data(("\n===== " + file.name + " =====\n").utf8))
            rightsData.append(checked[file.name]!)
        }
        let rightsAsset = try repository.ingest(rightsData, name: "familiar-mario-rights-v1.txt", workspaceID: workspaceID, mediaType: "text")
        var prepared: [(File, Asset)] = []
        for file in files {
            var asset = try repository.ingest(checked[file.name]!, name: file.name, workspaceID: workspaceID, mediaType: file.type)
            if file.type == "audio" {
                // Decode the checked CAS bytes, not a source file that may have changed after verification.
                let audio = try AVAudioFile(forReading: repository.assetURL(asset))
                let seconds = Double(audio.length) / audio.processingFormat.sampleRate
                guard seconds.isFinite, seconds > 0, seconds <= 30,
                      audio.processingFormat.channelCount > 0 else {
                    throw VideoError.invalid("熟悉游戏声音无有效实长：" + file.name)
                }
                asset.durationFrames = Int(ceil(seconds * 30))
                asset.warnings = ["下载的现成游戏音效；不代表课程旁白；商业权利待核，须实际试听。"]
            }
            prepared.append((file, asset))
        }
        return try repository.transaction { database in
            guard database.workspaces.contains(where: { $0.id == workspaceID }) else {
                throw VideoError.permission("工作区已撤销，未登记熟悉游戏素材")
            }
            var rights = rightsAsset
            if let existing = database.assets.first(where: { $0.workspaceID == workspaceID && $0.name == rights.name && $0.hash == rights.hash }) {
                try checkExisting(existing, source: upstream, database: database, workspaceID: workspaceID)
                rights = existing
            } else {
                let proof = Evidence(workspaceID: workspaceID, title: "马里奥来源与软件许可原文（商业权利待核）", source: upstream,
                                     claim: verifiedClaim, owner: owner, commercialAllowed: false, verified: true, assetID: rights.id)
                rights.evidenceID = proof.id
                rights.tags = ["熟悉游戏素材", "马里奥", "商业权利待核"]
                database.evidence.append(proof)
                database.assets.append(rights)
            }
            var byName: [String: Asset] = [:]
            var sources: [ClassicSource] = []
            for (file, imported) in prepared {
                var asset = imported
                if let existing = database.assets.first(where: { $0.workspaceID == workspaceID && $0.name == file.name && $0.hash == file.hash }) {
                    try checkExisting(existing, source: file.source, database: database, workspaceID: workspaceID, rightsAssetID: rights.id)
                    guard existing.mediaType == imported.mediaType, existing.durationFrames == imported.durationFrames else {
                        throw VideoError.conflict("熟悉游戏媒体记录已修改：" + file.name)
                    }
                    asset = existing
                } else {
                    let proof = Evidence(workspaceID: workspaceID, title: "马里奥原件 · " + file.name + "（商业权利待核）",
                                         source: file.source, claim: verifiedClaim, owner: owner,
                                         commercialAllowed: false, verified: true, assetID: rights.id)
                    asset.evidenceID = proof.id
                    asset.tags = ["熟悉游戏素材", "马里奥", "商业权利待核"]
                    database.evidence.append(proof)
                    database.assets.append(asset)
                }
                byName[file.name] = asset
                sources.append(ClassicSource(assetID: asset.id, hash: asset.hash, source: file.source, owner: owner,
                                             license: pendingLicense, evidenceID: asset.evidenceID!))
            }
            return FamiliarImportedSources(assetsByName: byName, sources: sources,
                                           audioAssets: files.filter { $0.type == "audio" }.compactMap { byName[$0.name] })
        }
    }

    private static func checkExisting(_ asset: Asset, source: String, database: Database, workspaceID: String, rightsAssetID: String? = nil) throws {
        guard let id = asset.evidenceID,
              let proof = database.evidence.first(where: { $0.id == id && $0.workspaceID == workspaceID }),
              proof.source == source, proof.owner == owner, proof.claim == verifiedClaim,
              proof.verified, !proof.commercialAllowed,
              proof.assetID == (rightsAssetID ?? asset.id) else {
            throw VideoError.conflict("熟悉游戏来源或权利记录已修改，请先核对原记录：" + asset.name)
        }
    }
}
