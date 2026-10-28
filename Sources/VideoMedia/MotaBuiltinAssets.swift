import Foundation
import AVFoundation
import ImageIO
import VideoCore

public struct MotaCharacterArtwork: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let artwork: ClassicArtwork
}

public struct MotaImportedPack: Sendable {
    public let characters: [MotaCharacterArtwork]
    public let actors: [CartoonActor]
    public let audioAssets: [Asset]
}

/// Imports the existing, actually generated Mota art through the ordinary CAS
/// and source ledger. It executes no upstream code and grants no module rights,
/// commercial permission, listening approval, rule confirmation or film review.
public enum MotaBuiltinAssets {
    private static let upstream = "https://raw.githubusercontent.com/ckcz123/mota-js/3efb548e407ad2b8007b498cb98401e2012a0b55/"
    private static let derivedOwner = "ckcz123（原件）；FF-1480项目素材整理及模型派生"
    private static let licence = "BSD 3-Clause原件及本任务实际模型派生；随附具体许可、来源和改动说明；仅当前非商业教学草稿"
    private static let audioWarning = "下载的魔塔原音效；未试听，非课程旁白；实际用途、声音位置和完整听审须另行确认。"

    private struct File {
        let path: String
        let bytes: Int
        let hash: String
        let type: String
        let width: Int?
        let height: Int?
        init(_ path: String, _ bytes: Int, _ hash: String, _ type: String = "text", _ width: Int? = nil, _ height: Int? = nil) {
            self.path=path; self.bytes=bytes; self.hash=hash; self.type=type; self.width=width; self.height=height
        }
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
        var isOriginal: Bool { path.hasPrefix("mota/") && path != "mota/README.md" }
        var source: String {
            if isOriginal {
                let relative=String(path.dropFirst("mota/".count))
                return MotaBuiltinAssets.upstream + (relative == "upstream/README.md" ? "README.md" : relative)
            }
            return MotaBuiltinAssets.upstream + "LICENSE.md#FF-1480-imagegen-" + hash
        }
        var owner: String { isOriginal ? "ckcz123" : MotaBuiltinAssets.derivedOwner }
        var claim: String {
            "固定上游BSD3许可及完整原文已保留。" +
            (isOriginal ? "本次为固定上游下载原件。" : "本次为实际image_gen派生或其提示/许可文档；原件、四图SHA及过程见本组README/prompts。") +
            "仅登记来源与本任务非商业教学用途；不授高级权益、试听、字幕或整片审核。当前文件SHA256 " + hash
        }
    }

    // Both BSD copies are checked. Their identical bytes have one CAS/source
    // identity, as in the original ordinary-CLI Mota project. JS is not an input.
    private static let files: [File] = [
        File("mota-q70/LICENSE.mota.md", 1507, "70440d45a4b311814f59845d60ac747e4f0a90202f9ea1e4b43330b3b057d49f"),
        File("mota/README.md", 6767, "9cf7d310531ebb484fda8313215a34d3e1153a960564606541ec00960ca97eb0"),
        File("mota/upstream/README.md", 40236, "ec7d95af440285bfc53389323d5a3ec3e6230f480983bb6d91a3a0e6f9a70aa6"),
        File("mota-q70/README.md", 9560, "18494ce594bac152920fcaa37e3c1bda58cef12fabb8d1f69f09272e4b8c7e9f"),
        File("mota-q70/prompts.md", 11443, "2e5a92487db97166569b5e501f6bb82c74b507dbe70f80cd918427456aa3f62f"),
        File("mota/project/images/hero.png", 5393, "07f2035a5f1c2321e974b234720db9872fe7cd7fd97e9e932ab4d53abd5d886f", "image", 128, 192),
        File("mota/project/materials/npc48.png", 22189, "e4cca94e94dba40aaf8d50bd5baea64e8bed3351aece0a5405a76b29dc72acd1", "image", 128, 480),
        File("mota/project/materials/npcs.png", 12971, "a664d6551a8ddbde58535f8787851baa66913b170338c222d1c1ac7c4bd514f1", "image", 64, 448),
        File("mota/project/materials/terrains.png", 9272, "82ae3d5ceeaffa89117c2376efde8f741e4bb552f9b4f37a9d5846b29f8ea4de", "image", 32, 1120),
        File("mota/project/materials/animates.png", 35724, "03f6e3eb92249b7303cf196f3ff7d3846398a87ad24f40086e8c2929fcf436d4", "image", 128, 928),
        File("mota/project/sounds/door.mp3", 8508, "b3717f25e2dc8d053529f8160cdead15ee8f1c8497de11b5a82a99893ece5c38", "audio"),
        File("mota/project/sounds/item.mp3", 8508, "843d05ea4924db78b9a2c5e1bd23110ac7813d17f9a08b2423ce35f5ae673ee6", "audio"),
        File("mota/project/sounds/shop.mp3", 21568, "c5e3be06f29808e3b1f21b2e5e48f18b269a48407c758b821a5aa432201cfe4a", "audio"),
        File("mota-q70/hero-poses.png", 2177004, "2a65b6a78ba41b5ea90daa178d243c3e48cc387e0cba640292e9f124ed0f5059", "image", 1536, 1024),
        File("mota-q70/trader-poses.png", 2276045, "9ada1d9cb892cff1e0aed18ea45ee67e9a352411047970b06e7d59c0a71bd6a6", "image", 1536, 1024),
        File("mota-q70/dungeon-objects.png", 2133045, "228e10899e3288dd08c522b5f570e5abd69a117fb68820e72515859c976467fa", "image", 1536, 1024),
        File("mota-q70/dungeon-shop-room.png", 2742454, "2027e6a410efa7ba98119145486e33240d2c2aabd50c64c068553f8489a5d02b", "image", 1536, 1024),
        File("mota/LICENSE.md", 1507, "70440d45a4b311814f59845d60ac747e4f0a90202f9ea1e4b43330b3b057d49f")
    ]
    private static var uniqueFiles: [File] {
        var hashes=Set<String>()
        return files.filter { hashes.insert($0.hash).inserted }
    }

    public static func importPack(bundle: Bundle = .main, workspaceID: String, repository: Repository) async throws -> MotaImportedPack {
        guard let resources=bundle.resourceURL else { throw VideoError.notFound("魔塔固定素材未安装") }
        return try await importPack(from: resources.appendingPathComponent("Mota", isDirectory: true), workspaceID: workspaceID, repository: repository)
    }

    /// The directory contains mota/ and mota-q70/. Only the fixed passive
    /// allowlist is read; no sibling directory, loose manifest or code is used.
    public static func importPack(from directory: URL, workspaceID: String, repository: Repository) async throws -> MotaImportedPack {
        try authorize(workspaceID, repository: repository)
        let prepared=try await prepare(directory: directory)
        let original=try repository.read()
        let before=try checkExisting(workspaceID: workspaceID, prepared: prepared, database: original, repository: repository)
        if before.count == uniqueFiles.count { return try pack(before, database: original) }
        // Every original, derived image, source text and original sound has
        // passed its frozen-byte preflight before the first CAS write.
        try Task.checkCancellation()
        var staged: [String: Asset] = [:]
        for file in uniqueFiles where before[file.path] == nil {
            var asset=try repository.ingest(prepared.bytes[file.path]!, name: file.name, workspaceID: workspaceID,
                                            mediaType: file.type, durationFrames: prepared.durations[file.path])
            if file.type == "text" { asset.pages=[CoursePage(number: 1, text: String(data: prepared.bytes[file.path]!, encoding: .utf8)!)] }
            if file.type == "audio" { asset.warnings=[audioWarning] }
            staged[file.path]=asset
        }
        return try repository.transaction { database in
            let current=try checkExisting(workspaceID: workspaceID, prepared: prepared, database: database, repository: repository)
            var byPath=current
            for file in uniqueFiles where byPath[file.path] == nil {
                guard var asset=staged[file.path] else { throw VideoError.conflict("魔塔来源在导入期间变化，请刷新重试") }
                let proof=Evidence(workspaceID: workspaceID, title: "魔塔具体原件或Q派生来源：" + asset.name,
                                   source: file.source, claim: file.claim, owner: file.owner,
                                   commercialAllowed: false, uploadConsent: false, verified: true, assetID: asset.id)
                asset.evidenceID=proof.id
                database.evidence.append(proof); database.assets.append(asset); byPath[file.path]=asset
            }
            return try pack(byPath, database: database)
        }
    }

    private struct Prepared {
        let bytes: [String: Data]
        let durations: [String: Int]
    }
    private static func authorize(_ workspaceID: String, repository: Repository) throws {
        guard try repository.read().workspaces.contains(where: { $0.id == workspaceID }) else {
            throw VideoError.permission("魔塔原件只能导入当前已有工作区")
        }
    }
    private static func directory(_ url: URL) throws {
        let values=try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw VideoError.invalid("魔塔固定输入须位于普通文件夹，拒绝链接")
        }
    }
    private static func prepare(directory root: URL) async throws -> Prepared {
        try directory(root)
        var checked: [String: Data]=[:]
        for file in files {
            try Task.checkCancellation()
            var parent=root
            for component in file.path.split(separator: "/").dropLast() {
                parent.appendPathComponent(String(component), isDirectory: true); try directory(parent)
            }
            let location=root.appendingPathComponent(file.path)
            let values=try location.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == file.bytes,
                  file.bytes > 0, file.bytes <= 8 * 1024 * 1024 else {
                throw VideoError.invalid("魔塔固定输入须为大小相符的普通文件：" + file.path)
            }
            let data=try Data(contentsOf: location)
            guard data.count == file.bytes, Codec.hash(data) == file.hash else {
                throw VideoError.review("魔塔原件、派生图或来源文本SHA-256不符：" + file.path)
            }
            if file.type == "image" {
                guard let source=CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetType(source) as String? == "public.png", CGImageSourceGetCount(source) == 1,
                      let properties=CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width=properties[kCGImagePropertyPixelWidth] as? Int,
                      let height=properties[kCGImagePropertyPixelHeight] as? Int,
                      width == file.width, height == file.height, (1...8192).contains(width), (1...8192).contains(height),
                      width * height <= 24_000_000,
                      CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
                    throw VideoError.invalid("魔塔PNG实际格式、尺寸或解码无效：" + file.path)
                }
            } else if file.type == "text", String(data: data, encoding: .utf8) == nil {
                throw VideoError.invalid("魔塔来源文本不是UTF-8：" + file.path)
            }
            checked[file.path]=data
        }
        let durations=try await audioDurations(checked)
        return Prepared(bytes: checked, durations: durations)
    }

    /// AVFoundation reads temporary copies of captured bytes, never a mutable
    /// input path or a CAS that was already written. Decode the complete track;
    /// container duration uses the same native API as ordinary assets import.
    private static func audioDurations(_ checked: [String: Data]) async throws -> [String: Int] {
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("mota-audio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        var durations: [String: Int]=[:]
        for file in uniqueFiles where file.type == "audio" {
            try Task.checkCancellation()
            let location=temporary.appendingPathComponent(file.name)
            try checked[file.path]!.write(to: location, options: .withoutOverwriting)
            let media=AVURLAsset(url: location), duration=try await media.load(.duration)
            let tracks=try await media.loadTracks(withMediaType: .audio)
            guard duration.seconds.isFinite, duration.seconds > 0, duration.seconds <= 30, !tracks.isEmpty else {
                throw VideoError.invalid("魔塔原声没有有效音轨或有界实长：" + file.path)
            }
            let audio=try AVAudioFile(forReading: location)
            let rate=audio.processingFormat.sampleRate
            guard rate.isFinite, (8000...192000).contains(rate), (1...8).contains(audio.processingFormat.channelCount),
                  audio.length > 0, Double(audio.length) / rate <= 30,
                  let buffer=AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else {
                throw VideoError.invalid("魔塔原声解码格式或实际帧数无效：" + file.path)
            }
            let totalFrames=audio.length
            var decoded: Int64=0
            // ExtAudioFile's MP3 reader can return NO with a nil NSError for
            // a read after the native end. Read every actual frame exactly to
            // that boundary instead of probing EOF with another empty read.
            while audio.framePosition < totalFrames {
                let position=audio.framePosition
                let requested=AVAudioFrameCount(min(Int64(4096), totalFrames - position))
                try audio.read(into: buffer, frameCount: requested)
                guard buffer.frameLength > 0, buffer.frameLength <= requested,
                      audio.framePosition == position + Int64(buffer.frameLength) else {
                    throw VideoError.invalid("魔塔原声未完整解码到实际帧数：" + file.path)
                }
                decoded += Int64(buffer.frameLength)
                guard Double(decoded) / rate <= 30 else { throw VideoError.invalid("魔塔原声解码超出30秒") }
            }
            guard decoded == totalFrames, audio.framePosition == totalFrames else {
                throw VideoError.invalid("魔塔原声不能完整解码：" + file.path)
            }
            durations[file.path]=Int(ceil(duration.seconds * 30))
        }
        return durations
    }

    private static func checkExisting(workspaceID: String, prepared: Prepared, database: Database, repository: Repository) throws -> [String: Asset] {
        guard database.workspaces.contains(where: { $0.id == workspaceID }) else {
            throw VideoError.permission("工作区已撤销，未登记魔塔素材")
        }
        var result: [String: Asset]=[:]
        for file in uniqueFiles {
            let matches=database.assets.filter { $0.workspaceID == workspaceID && $0.hash == file.hash }
            guard matches.count <= 1 else { throw VideoError.conflict("相同魔塔输入有重复素材记录，请先核对：" + file.path) }
            guard let asset=matches.first else { continue }
            let aliases=files.filter { $0.hash == file.hash && $0.name == asset.name }
            guard !aliases.isEmpty, asset.bytes == file.bytes, asset.ext == URL(fileURLWithPath: file.path).pathExtension,
                  asset.mediaType == file.type, asset.durationFrames == prepared.durations[file.path], asset.generatedSource == nil,
                  (file.type == "audio" ? (asset.warnings.isEmpty || asset.warnings == [audioWarning]) : asset.warnings.isEmpty),
                  let id=asset.evidenceID, let proof=database.evidence.first(where: { $0.id == id && $0.workspaceID == workspaceID }),
                  proof.title == "魔塔具体原件或Q派生来源：" + asset.name, proof.assetID == asset.id,
                  proof.usable(commercial: false), !proof.commercialAllowed, !proof.uploadConsent,
                  aliases.contains(where: { proof.source == $0.source && proof.owner == $0.owner && proof.claim == $0.claim }) else {
                throw VideoError.conflict("魔塔相同原件的来源、用途或媒体记录已修改，请先核对：" + file.path)
            }
            if file.type == "text" {
                guard asset.pages.count == 1, asset.pages[0].number == 1, !asset.pages[0].requiresOCR,
                      asset.pages[0].text == String(data: prepared.bytes[file.path]!, encoding: .utf8) else {
                    throw VideoError.conflict("魔塔来源原文的已登记解析内容不符：" + file.path)
                }
            } else if !asset.pages.isEmpty {
                throw VideoError.conflict("魔塔图片或原声的媒体记录不符：" + file.path)
            }
            let data=try Data(contentsOf: repository.assetURL(asset))
            guard data.count == file.bytes, Codec.hash(data) == file.hash else {
                throw VideoError.review("已登记魔塔源文件损坏或缺失：" + file.path)
            }
            result[file.path]=asset
        }
        return result
    }

    private static func pack(_ byPath: [String: Asset], database: Database) throws -> MotaImportedPack {
        let sources=try uniqueFiles.map { file -> ClassicSource in
            guard let asset=byPath[file.path], let id=asset.evidenceID,
                  let proof=database.evidence.first(where: { $0.id == id }) else { throw VideoError.notFound("魔塔素材或具体来源缺失") }
            return ClassicSource(assetID: asset.id, hash: asset.hash, source: proof.source, owner: proof.owner, license: licence, evidenceID: id)
        }
        let poses=["listen", "walk", "walkAlternate", "speak", "object", "celebrate"]
        let hero=[(155,47,287,458), (637,46,292,459), (1127,46,292,461), (132,528,336,454), (581,524,373,457), (1121,534,345,447)]
        let merchant=[(136,31,293,478), (597,33,345,474), (1135,29,320,480), (99,521,407,469), (615,521,349,468), (1135,525,290,465)]
        let cast=[("hero", "勇士", "hero-poses.png", hero), ("merchant", "商人", "trader-poses.png", merchant)]
        func sprite(_ role: String, _ name: String, _ rect: (Int, Int, Int, Int)) -> ClassicSprite {
            ClassicSprite(role: role, assetID: byPath["mota-q70/" + name]!.id,
                          x: Double(rect.0) / 1536, y: Double(rect.1) / 1024,
                          width: Double(rect.2) / 1536, height: Double(rect.3) / 1024)
        }
        let named=cast.flatMap { member in poses.enumerated().map { sprite("cast_" + member.0 + "_" + $0.element, member.2, member.3[$0.offset]) } }
        let originalPaths=["project/images/hero.png", "project/materials/npc48.png", "project/materials/npcs.png", "project/materials/terrains.png", "project/materials/animates.png"]
        let originals=originalPaths.map { byPath["mota/" + $0]!.id }
        let scenery=[("floor", (32,608,320,352)), ("obstacle", (16,108,352,376)), ("door_narrow", (400,108,352,376)),
                     ("door_opening", (784,108,352,376)), ("door_open", (1168,108,352,376)), ("wall", (384,608,336,352)),
                     ("shop", (736,608,448,352)), ("stairs", (1184,608,352,352))].map { sprite($0.0, "dungeon-objects.png", $0.1) }
        let backdrops=["knowledge_backdrop", "backdrop"].map { sprite($0, "dungeon-shop-room.png", (0,0,1536,1024)) }
        let aliases=[("hero",0), ("hero_idle",0), ("hero_walk",1), ("hero_walk_alt",2), ("hero_contribute",3), ("hero_blocked",4), ("hero_success",5)]
        let characters=cast.map { member in
            MotaCharacterArtwork(id: member.0, name: member.1, artwork: ClassicArtwork(gameplay: .sokoban,
                sprites: named + aliases.map { sprite($0.0, member.2, member.3[$0.1]) } + scenery + backdrops,
                sources: sources, derivation: .qStyle,
                transformation: "基于固定mota-js 3efb548原件，经内置image_gen实际生成四张Q插画；完整提示、原件与派生SHA、实际区域和alpha边界见已导入mota-q70来源原文。六姿态及完整四态门保持实际原区域，商店与楼梯为视觉构件，两步态不冒完整交替周期。gameplay仅旧IR兼容，知识分支不冒推箱子或完整魔塔玩法。",
                originalAssetIDs: originals))
        }
        let actors=cast.map { member in
            CartoonActor(id: member.0, name: member.1, poseRoles: Dictionary(uniqueKeysWithValues: poses.map { ($0, "cast_" + member.0 + "_" + $0) }))
        }
        let audio=uniqueFiles.filter { $0.type == "audio" }.map { byPath[$0.path]! }
        return MotaImportedPack(characters: characters, actors: actors, audioAssets: audio)
    }
}
