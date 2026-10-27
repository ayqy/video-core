import Foundation
import ImageIO
import VideoCore

public struct BubbleKnowledgeCharacterArtwork: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let artwork: ClassicArtwork
}

public struct BubbleKnowledgeImportedPack: Sendable {
    public let characters: [BubbleKnowledgeCharacterArtwork]
    /// Existing choreography selects each character's actual, separate poses.
    /// This does not add actor-to-artwork semantics to knowledge model inputs.
    public let actors: [CartoonActor]
    public let audioAssets: [Asset]
}

/// Imports a fixed, actually edited pose pack through the ordinary repository.
/// No network, code execution, licence issuance, listening or video approval.
public enum BubbleKnowledgeBuiltinAssets {
    private static let upstream = "https://raw.githubusercontent.com/tpoisonooo/BnB/5c108e8ad3ea07684d4666f60e6eec6c2f3e569e/"
    private static let owner = "盛趣游戏 / Nexon（原作权利待核）；tpoisonooo（仓库发布来源）"
    private static let derivedOwner = owner + "；方方（实际知识动作视觉派生整理）"
    private static let licence = "上游仅声明学习研究用途，未见覆盖商业和传播的明确许可；实际派生不扩张原作权利"
    private static let documentName = "bubble-knowledge-sources-v1.md"
    private static let documentHash = "05ac0e8051f28812aea3eadd3c85ef06ebde961c8aa7b6e69fcdb0f034b61bf6"
    private static let documentSource = "泡泡堂知识动作v1固定原件及实际生成来源原文"
    private static let originalClaim = "已核固定GitHub提交的具体动画原件字节、SHA-256和完整来源记录；原件未改像素，不以行走帧充作贡献、表情或口型。来源核验不授予商用与传播许可。"
    private static let derivedClaim = "以宝宝、小海盗真实动画原件及既有同源Q版场景为编辑输入，实际生成、逐张核对并分别修订六姿态和背景；保持原始PNG与实际裁切，完整提示和原件摘要见来源原文。不是骨骼、3D驱动或音素口型，不授予商用、传播、声音听审或模块权益。"
    private static let tags = ["熟悉游戏素材", "泡泡堂", "知识动作实际Q版派生", "商用与传播权利待核"]

    private struct File {
        let name: String
        let bytes: Int
        let hash: String
        let width: Int?
        let height: Int?
        let originalPath: String?
        var isDocument: Bool { width == nil }
        var mediaType: String { isDocument ? "text" : "image" }
        var source: String {
            if isDocument { return BubbleKnowledgeBuiltinAssets.documentSource }
            if let originalPath { return BubbleKnowledgeBuiltinAssets.upstream + originalPath }
            return "泡泡堂知识动作实际Q版派生 · " + name + "；完整来源 " + BubbleKnowledgeBuiltinAssets.documentName + "（SHA-256 " + BubbleKnowledgeBuiltinAssets.documentHash + "）"
        }
        var sourceOwner: String { originalPath == nil ? BubbleKnowledgeBuiltinAssets.derivedOwner : BubbleKnowledgeBuiltinAssets.owner }
        var claim: String { originalPath == nil ? BubbleKnowledgeBuiltinAssets.derivedClaim : BubbleKnowledgeBuiltinAssets.originalClaim }
    }
    private static let files: [File] = [
        File(name: documentName, bytes: 13272, hash: documentHash, width: nil, height: nil, originalPath: nil),
        File(name: "baobao_blue.png", bytes: 1373940, hash: "1327f86e185d43962224e7709638c6b5a232f3e64d829d9dd626f1e08c189a16", width: 1152, height: 1024, originalPath: "client/assets/anim/baobao_blue.png"),
        File(name: "haidao_red.png", bytes: 1747912, hash: "401f7ffa22696fae94348563e8bd55b9c4d705c1472e1f077e355d16c5b317a8", width: 1344, height: 1072, originalPath: "client/assets/anim/haidao_red.png"),
        File(name: "baobao-q-poses-v1.png", bytes: 1889317, hash: "2df1e3ea90b38065cc0656e1118641ade236db5efc6c001d0e322465f0583232", width: 1536, height: 1024, originalPath: nil),
        File(name: "haidao-q-poses-v2.png", bytes: 1805873, hash: "40b7afe046e114a7684530e935506cd550e2de17785907720af106c3f02d1780", width: 1536, height: 1024, originalPath: nil),
        File(name: "bubble-knowledge-backdrop-v1.png", bytes: 1624898, hash: "60634d199031203aa4e613aeeabe1cb007097568d2dcc78da0143e27818e7b47", width: 1672, height: 941, originalPath: nil)
    ]

    public static func importPack(bundle: Bundle = .main, workspaceID: String, repository: Repository) throws -> BubbleKnowledgeImportedPack {
        try authorize(workspaceID, repository: repository)
        let prepared = try prepare { name in
            let file = name as NSString
            guard let url = bundle.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension, subdirectory: "BubbleKnowledge")
                ?? bundle.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension) else {
                throw VideoError.notFound("知识动作原件、实际图集或来源原文未安装：" + name)
            }
            return url
        }
        let scenery = try BubbleBuiltinAssets.preparePack(bundle: bundle)
        return try importPrepared(prepared, scenery: scenery, workspaceID: workspaceID, repository: repository)
    }

    /// Both directories are explicit normal inputs; no upstream code or loose
    /// manifest is interpreted and there is no inferred sibling-folder access.
    public static func importPack(from directory: URL, sceneryDirectory: URL, workspaceID: String, repository: Repository) throws -> BubbleKnowledgeImportedPack {
        try authorize(workspaceID, repository: repository)
        for folder in [directory, sceneryDirectory] {
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw VideoError.invalid("知识动作与同源场景须使用普通素材文件夹，拒绝链接")
            }
        }
        let prepared = try prepare { directory.appendingPathComponent($0) }
        let scenery = try BubbleBuiltinAssets.preparePack(from: sceneryDirectory)
        return try importPrepared(prepared, scenery: scenery, workspaceID: workspaceID, repository: repository)
    }

    private static func authorize(_ workspaceID: String, repository: Repository) throws {
        guard try repository.read().workspaces.contains(where: { $0.id == workspaceID }) else {
            throw VideoError.permission("知识动作原件只能导入当前已有工作区")
        }
    }

    private static func prepare(url: (String) throws -> URL) throws -> [String: Data] {
        var checked: [String: Data] = [:]
        for file in files {
            let location = try url(file.name)
            let values = try location.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == file.bytes,
                  file.bytes > 0, file.bytes <= 8 * 1024 * 1024 else {
                throw VideoError.invalid("知识动作输入须为大小相符的普通文件：" + file.name)
            }
            let data = try Data(contentsOf: location)
            guard data.count == file.bytes, Codec.hash(data) == file.hash else {
                throw VideoError.review("知识动作原件、图集或来源原文摘要不符：" + file.name)
            }
            if file.isDocument {
                guard String(data: data, encoding: .utf8) != nil else { throw VideoError.invalid("知识动作来源原文不是UTF-8") }
            } else {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(source) as String? == "public.png",
                      CGImageSourceGetCount(source) == 1,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width == file.width, height == file.height, (1...8192).contains(width), (1...8192).contains(height), width * height <= 24_000_000,
                      CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
                    throw VideoError.invalid("知识动作PNG的实际尺寸、格式或解码无效：" + file.name)
                }
            }
            checked[file.name] = data
        }
        return checked
    }

    private static func matching(_ file: File, workspaceID: String, documentID: String?, database: Database) throws -> Asset? {
        let matches = database.assets.filter { $0.workspaceID == workspaceID && $0.name == file.name }
        guard matches.count <= 1 else { throw VideoError.conflict("知识动作素材有重复记录，请先核对：" + file.name) }
        guard let asset = matches.first else { return nil }
        guard asset.hash == file.hash, asset.bytes == file.bytes, asset.mediaType == file.mediaType,
              asset.ext == (file.isDocument ? "md" : "png"), asset.durationFrames == nil, asset.tags == tags, asset.warnings.isEmpty,
              let id = asset.evidenceID,
              let proof = database.evidence.first(where: { $0.id == id && $0.workspaceID == workspaceID }),
              proof.source == file.source, proof.owner == file.sourceOwner, proof.claim == file.claim,
              proof.verified, !proof.commercialAllowed,
              proof.assetID == (file.isDocument ? asset.id : documentID) else {
            throw VideoError.conflict("知识动作原件、派生或用途来源已修改，请先核对：" + file.name)
        }
        return asset
    }

    /// This semantic preflight also precedes the legacy pack's first CAS write.
    private static func checkExisting(workspaceID: String, database: Database) throws {
        let document = try matching(files[0], workspaceID: workspaceID, documentID: nil, database: database)
        for file in files.dropFirst() {
            _ = try matching(file, workspaceID: workspaceID, documentID: document?.id, database: database)
        }
    }

    private static func importPrepared(_ checked: [String: Data], scenery: BubbleBuiltinAssets.PreparedPack, workspaceID: String, repository: Repository) throws -> BubbleKnowledgeImportedPack {
        try authorize(workspaceID, repository: repository)
        try checkExisting(workspaceID: workspaceID, database: repository.read())
        // All six new inputs and every original legacy input are now captured,
        // decoded and pinned. No file is read again after the first write.
        let legacy = try BubbleBuiltinAssets.importPrepared(scenery, workspaceID: workspaceID, repository: repository)
        guard let legacyArtwork = legacy.characters.first?.artwork,
              let floor = legacyArtwork.sprites.first(where: { $0.role == "floor" }),
              var obstacle = legacyArtwork.sprites.first(where: { $0.role == "crate" }) else {
            throw VideoError.invalid("已核同源场景缺少实际地面或箱子")
        }
        obstacle.role = "obstacle"
        var staged: [String: Asset] = [:]
        for file in files {
            var asset = try repository.ingest(checked[file.name]!, name: file.name, workspaceID: workspaceID, mediaType: file.mediaType)
            asset.tags = tags; staged[file.name] = asset
        }
        return try repository.transaction { database in
            guard database.workspaces.contains(where: { $0.id == workspaceID }) else {
                throw VideoError.permission("工作区已撤销，未登记知识动作")
            }
            try checkExisting(workspaceID: workspaceID, database: database)
            var byName: [String: Asset] = [:], sources = legacyArtwork.sources
            for file in files {
                var asset: Asset
                if let existing = try matching(file, workspaceID: workspaceID, documentID: byName[documentName]?.id, database: database) {
                    asset = existing
                } else {
                    asset = staged[file.name]!
                    let proof = Evidence(workspaceID: workspaceID, title: (file.isDocument ? "知识动作完整来源原文" : file.originalPath == nil ? "实际知识动作派生 · " : "真实动画原件 · ") + (file.isDocument ? "" : file.name),
                                         source: file.source, claim: file.claim, owner: file.sourceOwner, commercialAllowed: false, verified: true,
                                         assetID: file.isDocument ? asset.id : byName[documentName]!.id)
                    asset.evidenceID = proof.id; database.evidence.append(proof); database.assets.append(asset)
                }
                byName[file.name] = asset
                if !file.isDocument {
                    sources.append(ClassicSource(assetID: asset.id, hash: asset.hash, source: file.source, owner: file.sourceOwner, license: licence, evidenceID: asset.evidenceID!))
                }
            }
            let originals = legacyArtwork.originalAssetIDs + [byName["baobao_blue.png"]!.id, byName["haidao_red.png"]!.id]
            let poseNames = ["idle", "walk", "walk_alt", "contribute", "success", "blocked"]
            let cast = [("baobao", "宝宝", "baobao-q-poses-v1.png"), ("haidao", "小海盗", "haidao-q-poses-v2.png")]
            func pose(_ role: String, _ name: String, _ index: Int) -> ClassicSprite {
                ClassicSprite(role: role, assetID: byName[name]!.id, x: Double(index % 3) / 3, y: Double(index / 3) / 2, width: 1.0 / 3, height: 0.5)
            }
            let namedPoses = cast.flatMap { member in poseNames.enumerated().map { pose(member.0 + "_" + $0.element, member.2, $0.offset) } }
            let background = ClassicSprite(role: "knowledge_backdrop", assetID: byName["bubble-knowledge-backdrop-v1.png"]!.id)
            let characters = cast.map { member -> BubbleKnowledgeCharacterArtwork in
                let standard = [pose("hero", member.2, 0)] + poseNames.enumerated().map { pose("hero_" + $0.element, member.2, $0.offset) }
                let artwork = ClassicArtwork(gameplay: .sokoban, sprites: standard + namedPoses + [background, floor, obstacle, ClassicSprite(role: "backdrop", assetID: background.assetID)],
                                             sources: sources, derivation: .qStyle,
                                             transformation: "宝宝与小海盗真实动画原件经内置图像编辑生成各六个独立姿态；3×2原序为idle、walk、walk_alt、contribute、success、blocked，每格512×512。海盗采用独立v2留白修订。场景背景为实际同源派生，木地面与箱子保旧Q图集；完整原文、原件SHA和提示见 " + documentName + "，不扩张原IP权利或高级模块权益。",
                                             originalAssetIDs: originals)
                return BubbleKnowledgeCharacterArtwork(id: member.0, name: member.1, artwork: artwork)
            }
            let actors = cast.map { member in CartoonActor(id: member.0, name: member.1, poseRoles: ["listen": member.0 + "_idle", "speak": member.0 + "_contribute", "walk": member.0 + "_walk", "walkAlternate": member.0 + "_walk_alt", "object": member.0 + "_blocked", "celebrate": member.0 + "_success"]) }
            return BubbleKnowledgeImportedPack(characters: characters, actors: actors, audioAssets: legacy.audioAssets)
        }
    }
}
