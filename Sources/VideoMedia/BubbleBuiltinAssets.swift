import Foundation
import AVFoundation
import ImageIO
import VideoCore

public struct BubbleCharacterArtwork: Identifiable, Sendable {
    /// Stable upstream character filename, independent of repository-generated asset IDs.
    public var id: String
    public var name: String
    public var artwork: ClassicArtwork
}

public struct BubbleImportedPack: Sendable {
    public var characters: [BubbleCharacterArtwork]
    public var audioAssets: [Asset]
}

/// Preserves downloaded originals and imports separately pinned, actually edited Q-style atlases.
public enum BubbleBuiltinAssets {
    public static let upstreamCommit = "5c108e8ad3ea07684d4666f60e6eec6c2f3e569e"
    private static let upstream = "https://raw.githubusercontent.com/tpoisonooo/BnB/" + upstreamCommit + "/"
    private static let owner = "盛趣游戏 / Nexon（原作素材版权由上游声明，权利待核）；tpoisonooo（仓库发布来源）"
    private static let pendingLicense = "上游仅声明学习研究用途，未见LICENSE；泡泡堂角色、场景及声音的商用与传播权利待核"
    private static let verifiedClaim = "已核验固定GitHub提交的具体文件、原件字节数及SHA-256；图像为上游已Q版原件，统一使用同源画风，无新改绘。来源已核不等于版权授权，商用与传播权利仍待核。教学画面使用已有推箱子规则演绎，并非泡泡堂原作游戏逻辑。"
    private static let styleTag = "上游已Q版，统一使用同源画风；无新改绘"
    private static let teachingTag = "推箱子教学演绎，非泡泡堂原作规则"
    private static let audioWarning = "下载的泡泡堂短音效原件；未试听，非课程旁白；商用与传播权利待核。"

    private struct File {
        let name: String
        let path: String
        let bytes: Int
        let hash: String
        let type: String
        var source: String {
            // Only fixed, developer-owned allowlist paths are encoded here.
            BubbleBuiltinAssets.upstream + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        }
    }

    private static let files: [File] = [
        File(name: "bubble-pidan.png", path: "client/assets/chars/pidan.png", bytes: 129693, hash: "e76de1b91e7a74643a694424b9458d72240a319dc6e88a4fa025e22f12fca878", type: "image"),
        File(name: "bubble-pangdun.png", path: "client/assets/chars/pangdun.png", bytes: 136858, hash: "8d775be76fba4242d2b1254b3c2307f32c5dd2ef27fdc294390c9da907beba54", type: "image"),
        File(name: "bubble-lanlan.png", path: "client/assets/chars/lanlan.png", bytes: 118135, hash: "b5009b4f85ca21ec5a69275a98087a5080e78eac6d49d931db206ba7be8c687e", type: "image"),
        File(name: "bubble-congtou.png", path: "client/assets/chars/congtou.png", bytes: 120403, hash: "e3971ad78ee4c166d76d33daf5293895a000dbf3e1fd6a4dbecb9b653206ed88", type: "image"),
        File(name: "bubble-box.png", path: "client/assets/box.png", bytes: 22281, hash: "cf314b37b76cc4fd588bd0348ad01237bdc6e9cc4bb0a6a9580c8b684d458e0b", type: "image"),
        File(name: "bubble-crate.png", path: "client/assets/crate.png", bytes: 32868, hash: "06a5fd88d56d8e44750407a6a7e7dff656da8cdb464615da30c3191cb6ea1c68", type: "image"),
        File(name: "bubble-floor.png", path: "client/assets/floor.png", bytes: 9469, hash: "d551b118e2e127703f6884c0ed21113be2ef71c8c2cc3d2c8e5dedce242a7310", type: "image"),
        File(name: "bubble-cannon.png", path: "client/assets/cannon.png", bytes: 64482, hash: "a3e8dd2836fcf77d9919f8bdc64b1bee95a3a21c090390039dfbad17728864be", type: "image"),
        File(name: "bubble-mast.png", path: "client/assets/mast.png", bytes: 447974, hash: "fffdc555e210e9cae804a07527baed49aa615dae4db1c410e24710bc740aa863", type: "image"),
        File(name: "bubble-explode.wav", path: "client/assets/snd/explode.wav", bytes: 88512, hash: "ada98c952b4b86cb6f1a59a7702de6ea78b8261cf4f2a7d39a83329b6cc7b3a9", type: "audio"),
        File(name: "bubble-start.wav", path: "client/assets/snd/start.wav", bytes: 96712, hash: "57643896da500d5e71eaee4b1809b83e73b0257f5abfe869dd826f5d0c7a7e99", type: "audio"),
        File(name: "bubble-bomb-set.mp3", path: "client/assets/snd/放置泡泡_bomb_set.mp3", bytes: 1961, hash: "68cf46e457bd8e3b9f0b3de4981446be0ecd8186d5fac5d6aa1da92663908be3", type: "audio")
    ]
    private static let texts: [File] = [
        File(name: "bnb-upstream-readme.txt", path: "README.md", bytes: 13032, hash: "9ca9aaccc4a976113e5dd2b44728fdcd2bb3e98eb5faa3618d43630bec0fecbf", type: "text"),
        File(name: "bubble-sources.md", path: "", bytes: 3629, hash: "3a2fc49a320f6b02a77fb8169fdef00ba1182567de6f78f0a29e85dda15fefbd", type: "text")
    ]
    private static let derivedImages: [File] = [
        File(name: "bubble-q-characters-v1.png", path: "", bytes: 1422129, hash: "aee8de5a207ead0c8a0131c189bed09f874532c480fa747c17e382429ef9b86d", type: "image"),
        File(name: "bubble-q-scenery-v1.png", path: "", bytes: 1393083, hash: "bbcef1f2477fb39413432f04e17e70035213e7c88fcf0e0af0541cc1e59cb56f", type: "image")
    ]
    private static let derivedDocument = File(name: "bubble-q-provenance-v1.md", path: "", bytes: 5579, hash: "24520b81de929480fa838d87a9bc7526796421a2b564cd3f3b6ad39b7612050c", type: "text")
    private static let derivedOwner = owner + "；方方（实际视觉派生整理）"
    private static let derivedClaim = "九份已下载原件分别作为图像编辑目标，实际输出四角色和五场景统一Q版图集；原件、具体SHA、提示及实际裁切合同保留。视觉派生不授予原IP商用或传播权，商业权利仍待核；声音仍为下载原音效，默认未听审。"
    private static func derivedSource(_ name: String) -> String {
        "泡泡堂统一Q版视觉派生v1 · " + name + "；原件 " + upstream + "；过程记录 " + derivedDocument.name + "（SHA-256 " + derivedDocument.hash + "）"
    }
    private static var derivedTags: [String] { ["熟悉游戏素材", "泡泡堂", "统一Q版派生v1", "商业权利待核", teachingTag] }

    public static func importPack(bundle: Bundle = .main, workspaceID: String, repository: Repository) throws -> BubbleImportedPack {
        try importPack(workspaceID: workspaceID, repository: repository) { name in
            let file = name as NSString
            guard let location = bundle.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension, subdirectory: "Bubble")
                ?? bundle.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension) else {
                throw VideoError.notFound("泡泡堂原件或统一Q版派生未安装：" + name)
            }
            return location
        }
    }

    /// Accepts only this pack's exact, bounded allowlist. Never executes upstream code or manifests.
    public static func importPack(from directory: URL, workspaceID: String, repository: Repository) throws -> BubbleImportedPack {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw VideoError.invalid("请选择包含完整泡泡堂原件的普通文件夹")
        }
        return try importPack(workspaceID: workspaceID, repository: repository) { directory.appendingPathComponent($0) }
    }

    private static func checkedData(_ location: URL, file: File) throws -> Data {
        let values = try location.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == file.bytes,
              file.bytes > 0, file.bytes <= 2 * 1024 * 1024 else {
            throw VideoError.invalid("泡泡堂原件须为大小相符的普通文件：" + file.name)
        }
        let data = try Data(contentsOf: location)
        guard data.count == file.bytes, Codec.hash(data) == file.hash else {
            throw VideoError.review("泡泡堂素材或来源文本SHA-256不符：" + file.name)
        }
        if file.type == "image" {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 24_000_000,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw VideoError.invalid("泡泡堂图片无法解码或超出安全尺寸：" + file.name)
            }
        } else if file.type == "text", String(data: data, encoding: .utf8) == nil {
            throw VideoError.invalid("泡泡堂来源文本不是UTF-8：" + file.name)
        }
        return data
    }

    /// Decode captured, hash-checked bytes before writing CAS or database records.
    private static func audioDurations(checked: [String: Data]) throws -> [String: Int] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-audio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var durations: [String: Int] = [:]
        for file in files where file.type == "audio" {
            let location = directory.appendingPathComponent(file.name)
            try checked[file.name]!.write(to: location, options: .atomic)
            let audio = try AVAudioFile(forReading: location)
            let rate = audio.processingFormat.sampleRate
            let seconds = Double(audio.length) / rate
            guard rate.isFinite, rate > 0, seconds.isFinite, seconds > 0, seconds <= 30,
                  (1...8).contains(audio.processingFormat.channelCount) else {
                throw VideoError.invalid("泡泡堂声音无法解码或无有效实长：" + file.name)
            }
            durations[file.name] = Int(ceil(seconds * 30))
        }
        return durations
    }

    private static func importPack(workspaceID: String, repository: Repository, url: (String) throws -> URL) throws -> BubbleImportedPack {
        guard try repository.read().workspaces.contains(where: { $0.id == workspaceID }) else {
            throw VideoError.permission("泡泡堂原件只能导入当前已有工作区")
        }
        return try importPrepared(preparePack(url: url), workspaceID: workspaceID, repository: repository)
    }

    /// Captured, fully checked input lets an additional real asset pack finish
    /// its own preflight before this legacy pack performs any CAS/DB write.
    /// This is not a new public import mode and does not alter its 16 assets.
    struct PreparedPack {
        let checked: [String: Data]
        let durations: [String: Int]
    }

    static func preparePack(bundle: Bundle) throws -> PreparedPack {
        try preparePack { name in
            let file = name as NSString
            guard let location = bundle.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension, subdirectory: "Bubble")
                ?? bundle.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension) else {
                throw VideoError.notFound("泡泡堂原件或统一Q版派生未安装：" + name)
            }
            return location
        }
    }

    static func preparePack(from directory: URL) throws -> PreparedPack {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw VideoError.invalid("请选择包含完整泡泡堂原件的普通文件夹")
        }
        return try preparePack { directory.appendingPathComponent($0) }
    }

    private static func preparePack(url: (String) throws -> URL) throws -> PreparedPack {
        // Validate every image, audio and provenance document before the first CAS/DB write.
        var checked: [String: Data] = [:]
        for file in texts + files { checked[file.name] = try checkedData(url(file.name), file: file) }
        for file in derivedImages + [derivedDocument] { checked[file.name] = try checkedData(url(file.name), file: file) }
        let durations = try audioDurations(checked: checked)
        return PreparedPack(checked: checked, durations: durations)
    }

    static func importPrepared(_ prepared: PreparedPack, workspaceID: String, repository: Repository) throws -> BubbleImportedPack {
        guard try repository.read().workspaces.contains(where: { $0.id == workspaceID }) else {
            throw VideoError.permission("泡泡堂原件只能导入当前已有工作区")
        }
        let checked = prepared.checked, durations = prepared.durations
        var rightsData = Data("泡泡堂上游Q版原件来源核对；商用与传播权利待核\n\n".utf8)
        for file in texts {
            rightsData.append(Data(("\n===== " + file.name + " =====\n").utf8))
            rightsData.append(checked[file.name]!)
        }
        let rightsAsset = try repository.ingest(rightsData, name: "bubble-rights-v1.txt", workspaceID: workspaceID, mediaType: "text")
        var prepared: [(File, Asset)] = []
        for file in files {
            var asset = try repository.ingest(checked[file.name]!, name: file.name, workspaceID: workspaceID, mediaType: file.type,
                                              durationFrames: durations[file.name])
            asset.tags = tags(for: file.type)
            if file.type == "audio" { asset.warnings = [audioWarning] }
            prepared.append((file, asset))
        }
        var preparedDerived: [(File, Asset)] = []
        for file in derivedImages {
            var asset = try repository.ingest(checked[file.name]!, name: file.name, workspaceID: workspaceID, mediaType: "image")
            asset.tags = derivedTags
            preparedDerived.append((file, asset))
        }
        var derivativeRights = try repository.ingest(checked[derivedDocument.name]!, name: "bubble-q-rights-v1.md", workspaceID: workspaceID, mediaType: "text")
        derivativeRights.tags = derivedTags
        return try repository.transaction { database in
            guard database.workspaces.contains(where: { $0.id == workspaceID }) else {
                throw VideoError.permission("工作区已撤销，未登记泡泡堂原件")
            }
            var rights = rightsAsset
            rights.tags = ["熟悉游戏素材", "泡泡堂", "商业权利待核", styleTag, teachingTag]
            if let existing = try existingAsset(matching: rights, database: database) {
                try checkExisting(existing, source: upstream, database: database)
                rights = existing
            } else {
                let proof = Evidence(workspaceID: workspaceID, title: "泡泡堂上游来源原文（商用与传播权利待核）", source: upstream,
                                     claim: verifiedClaim, owner: owner, commercialAllowed: false, verified: true, assetID: rights.id)
                rights.evidenceID = proof.id
                database.evidence.append(proof)
                database.assets.append(rights)
            }
            var byName: [String: Asset] = [:]
            var sources: [ClassicSource] = []
            for (file, imported) in prepared {
                var asset = imported
                if let existing = try existingAsset(matching: imported, database: database) {
                    try checkExisting(existing, source: file.source, database: database, rightsAssetID: rights.id)
                    asset = existing
                } else {
                    let proof = Evidence(workspaceID: workspaceID, title: "泡泡堂下载原件 · " + file.name + "（商业权利待核）",
                                         source: file.source, claim: verifiedClaim, owner: owner,
                                         commercialAllowed: false, verified: true, assetID: rights.id)
                    asset.evidenceID = proof.id
                    database.evidence.append(proof)
                    database.assets.append(asset)
                }
                byName[file.name] = asset
                sources.append(ClassicSource(assetID: asset.id, hash: asset.hash, source: file.source, owner: owner,
                                             license: pendingLicense, evidenceID: asset.evidenceID!))
            }
            var qRights = derivativeRights
            if let existing = try existingAsset(matching: qRights, database: database) {
                try checkDerived(existing, source: derivedSource(derivedDocument.name), rightsAssetID: rights.id, database: database)
                qRights = existing
            } else {
                let proof = Evidence(workspaceID: workspaceID, title: "泡泡堂统一Q版实际派生过程（商业权利待核）", source: derivedSource(derivedDocument.name), claim: derivedClaim, owner: derivedOwner, commercialAllowed: false, verified: true, assetID: rights.id)
                qRights.evidenceID = proof.id; database.evidence.append(proof); database.assets.append(qRights)
            }
            for (file, imported) in preparedDerived {
                var asset = imported
                if let existing = try existingAsset(matching: imported, database: database) {
                    try checkDerived(existing, source: derivedSource(file.name), rightsAssetID: qRights.id, database: database)
                    asset = existing
                } else {
                    let proof = Evidence(workspaceID: workspaceID, title: "泡泡堂统一Q版实际派生 · " + file.name, source: derivedSource(file.name), claim: derivedClaim, owner: derivedOwner, commercialAllowed: false, verified: true, assetID: qRights.id)
                    asset.evidenceID = proof.id; database.evidence.append(proof); database.assets.append(asset)
                }
                byName[file.name] = asset
                sources.append(ClassicSource(assetID: asset.id, hash: asset.hash, source: derivedSource(file.name), owner: derivedOwner, license: pendingLicense + "；实际视觉派生不扩张上游权利", evidenceID: asset.evidenceID!))
            }
            let originalIDs = files.filter { $0.type == "image" }.compactMap { byName[$0.name]?.id }
            let characters = [("pidan.png", "皮蛋"), ("pangdun.png", "胖墩"), ("lanlan.png", "蓝蓝"), ("congtou.png", "葱头")].enumerated().map { index, entry in
                let (filename, name) = entry
                let hero = byName["bubble-q-characters-v1.png"]!, scenery = byName["bubble-q-scenery-v1.png"]!
                // Use the measured transparent gap in the actual delivered atlas.
                let top = index < 2 ? 0.0 : 620.0 / 1254.0
                let height = index < 2 ? 620.0 / 1254.0 : 634.0 / 1254.0
                func prop(_ role: String, _ cell: Int) -> ClassicSprite {
                    ClassicSprite(role: role, assetID: scenery.id, x: Double(cell % 3) / 3, y: Double(cell / 3) / 2, width: 1.0 / 3, height: 0.5)
                }
                let sprites = [
                    ClassicSprite(role: "hero", assetID: hero.id, x: Double(index % 2) / 2, y: top, width: 0.5, height: height),
                    prop("crate", 0), prop("wall", 1), prop("floor", 2), prop("cannon", 3), prop("mast", 4)
                ]
                // Existing sokoban rules illustrate the lesson; this does not implement Bubble's original gameplay.
                let artwork = ClassicArtwork(gameplay: .sokoban, sprites: sprites, sources: sources, derivation: .qStyle,
                                             transformation: "基于九份固定下载原件实际图像编辑的统一Q版派生v1；四角色图集1254×1254按实测透明间隙分区，场景图集1536×1024按3×2裁切。原件与完整提示/SHA留存；商业和传播权利未扩张。", originalAssetIDs: originalIDs)
                return BubbleCharacterArtwork(id: filename, name: name, artwork: artwork)
            }
            return BubbleImportedPack(characters: characters, audioAssets: files.filter { $0.type == "audio" }.compactMap { byName[$0.name] })
        }
    }

    private static func tags(for type: String) -> [String] {
        ["熟悉游戏素材", "泡泡堂", "商业权利待核", type == "image" ? styleTag : "下载短音效原件，未试听", teachingTag]
    }

    private static func existingAsset(matching imported: Asset, database: Database) throws -> Asset? {
        let matches = database.assets.filter { $0.workspaceID == imported.workspaceID && $0.name == imported.name }
        guard matches.count <= 1 else { throw VideoError.conflict("泡泡堂素材有重复记录，请先核对：" + imported.name) }
        guard let existing = matches.first else { return nil }
        guard existing.hash == imported.hash, existing.bytes == imported.bytes, existing.ext == imported.ext,
              existing.mediaType == imported.mediaType, existing.durationFrames == imported.durationFrames,
              existing.warnings == imported.warnings, existing.tags == imported.tags else {
            throw VideoError.conflict("泡泡堂素材的摘要、媒体属性或来源标签已修改：" + imported.name)
        }
        return existing
    }

    private static func checkExisting(_ asset: Asset, source: String, database: Database, rightsAssetID: String? = nil) throws {
        guard let id = asset.evidenceID,
              let proof = database.evidence.first(where: { $0.id == id && $0.workspaceID == asset.workspaceID }),
              proof.source == source, proof.owner == owner, proof.claim == verifiedClaim,
              proof.verified, !proof.commercialAllowed, proof.assetID == (rightsAssetID ?? asset.id) else {
            throw VideoError.conflict("泡泡堂来源或商业权利记录已修改，请先核对原记录：" + asset.name)
        }
    }
    private static func checkDerived(_ asset: Asset, source: String, rightsAssetID: String, database: Database) throws {
        guard let id = asset.evidenceID,
              let proof = database.evidence.first(where: { $0.id == id && $0.workspaceID == asset.workspaceID }),
              proof.source == source, proof.owner == derivedOwner, proof.claim == derivedClaim,
              proof.verified, !proof.commercialAllowed, proof.assetID == rightsAssetID else {
            throw VideoError.conflict("泡泡堂实际派生或上游权利关联已修改，请先核对：" + asset.name)
        }
    }
}
