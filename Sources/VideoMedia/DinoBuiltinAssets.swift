import Foundation
import AVFoundation
import ImageIO
import VideoCore

public struct DinoImportedPack: Sendable {
    public var artwork: ClassicArtwork
    public var audioAssets: [Asset]
}

/// Passive, pinned Chromium media only. Import never installs code or grants renderer rights.
public enum DinoBuiltinAssets {
    private static let upstream = "https://github.com/chromium/chromium/blob/c6eb3c50851cd50898ff511fa2fe07b6446d8138/"
    private static let sprite = "components/neterror/resources/images/default_200_percent/offline/200-offline-sprite.png"
    private static let owner = "The Chromium Authors"
    private struct File {
        let name: String; let hash: String; let type: String; let source: String
    }
    private static let files: [File] = [
        File(name:"dino-offline-sprite-original.png",hash:"e4222715b556e7d99622c83e620d2f8e090047e56adb07923047f95828d561f2",type:"image",source:upstream+sprite),
        File(name:"dino-hero-q-v1.png",hash:"6c65ae3d80eab79c5e2c2799fe228fd39d6c1a8b4ab37ada80ae805b706c8071",type:"image",source:upstream+sprite+"；同小恐龙实际Q版派生v1，2026-10-23"),
        File(name:"dino-actions-q-v1.png",hash:"dc126cac1e9115848cf820019a198502e3b70743cd139869e3396a87049ccd56",type:"image",source:upstream+sprite+"；同小恐龙六动作实际Q版派生v1，2026-10-24，完整过程见dino-actions-q-v1.md"),
        File(name:"dino-backdrop-q-v2.png",hash:"30b2b721d6ecf8e8e1435911d5085ff5377dd6c955a7a044ead7ecc9681a5917",type:"image",source:upstream+sprite+"；同仙人掌/云/地面实际Q版宽幅派生v2，2026-10-23"),
        File(name:"dino-button-press-original.mp3",hash:"c29ea1bb6353a9bd16753d3f46957f0c80fb08769cc945d83b20d3c48470236e",type:"source_audio",source:upstream+"components/neterror/resources/sounds/button-press.mp3"),
        File(name:"dino-hit-original.mp3",hash:"4a618da307a0e5807de7782693113328bf0bd2bcdedc1029a7ed5c545354f4a1",type:"source_audio",source:upstream+"components/neterror/resources/sounds/hit.mp3"),
        File(name:"dino-score-reached-original.mp3",hash:"cfd198edb6d6adb02456074d7617eec1c745cd00b5b912840cda2b8fbd1aa4fc",type:"source_audio",source:upstream+"components/neterror/resources/sounds/score-reached.mp3"),
        File(name:"dino-button-press.wav",hash:"ce902c8c9c5958035a7f572ad2df81198b47766763f13d3d98279a9be343d4e5",type:"audio",source:upstream+"components/neterror/resources/sounds/button-press.mp3；保留原Ogg/Vorbis字节，仅转PCM16 mono 48kHz WAV"),
        File(name:"dino-hit.wav",hash:"685c485ce291daacaf3c28e506f027ac5d6b0d82219ebb300327b5f5ead9cc89",type:"audio",source:upstream+"components/neterror/resources/sounds/hit.mp3；保留原Ogg/Vorbis字节，仅转PCM16 mono 48kHz WAV"),
        File(name:"dino-score-reached.wav",hash:"13696676b675f97e44fcb1ea805312bc3ad8847236fa3b5c092f73e276b6c6a2",type:"audio",source:upstream+"components/neterror/resources/sounds/score-reached.mp3；保留原Ogg/Vorbis字节，仅转PCM16 mono 48kHz WAV")
    ]
    private static let documents: [(String,String)] = [
        ("LICENSE","368cca1106be99d39ecd32a38d8305585d802a475effb66380b91ffc9bcf709b"),
        ("AUTHORS","846216f8ce44bcb56148603c2f0bdac18c06cff564aa7d4a72c50ad6619da310"),
        ("dino-sources.md","e78cdd18e6d1fb5cb83d7e04812e08e3e7f87f8abd9be72c42d66e5dd0146ba6"),
        ("dino-actions-q-v1.md","8ca912ef5f75193eb80b75754078c3c27a50819d4e3715f24278f7e7d31e4891")
    ]
    public static func importPack(bundle: Bundle = .main, workspaceID: String, repository: Repository) async throws -> DinoImportedPack {
        try await importPack(workspaceID:workspaceID,repository:repository) { name in
            let part=name as NSString
            guard let url=bundle.url(forResource:part.deletingPathExtension,withExtension:part.pathExtension.isEmpty ? nil:part.pathExtension,subdirectory:"Dino") else { throw VideoError.notFound("小恐龙原件素材包未安装："+name) }
            return url
        }
    }
    public static func importPack(from directory: URL, workspaceID: String, repository: Repository) async throws -> DinoImportedPack {
        try await importPack(workspaceID:workspaceID,repository:repository) { directory.appendingPathComponent($0) }
    }
    private static func read(_ url: URL, hash: String) throws -> Data {
        let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile==true,values.isSymbolicLink != true,let size=values.fileSize,(1...2*1024*1024).contains(size) else { throw VideoError.invalid("小恐龙素材只接受有界的原件普通文件") }
        let data=try Data(contentsOf:url)
        guard data.count==size,Codec.hash(data)==hash else { throw VideoError.review("小恐龙原件、派生或许可版本摘要不符："+url.lastPathComponent) }
        return data
    }
    private static func importPack(workspaceID: String, repository: Repository, url: (String) throws -> URL) async throws -> DinoImportedPack {
        guard try repository.read().workspaces.contains(where:{$0.id==workspaceID}) else { throw VideoError.permission("请先选择已有工作区再导入小恐龙素材") }
        // Freeze and validate every input before any CAS or database write.
        var rightsData=Data("Chromium小恐龙原版权、完整作者及具体派生来源\n\n".utf8)
        for (name,hash) in documents { rightsData.append(try read(url(name),hash:hash));rightsData.append(Data("\n\n".utf8)) }
        let snapshots=try files.map { ($0,try read(url($0.name),hash:$0.hash)) }
        for (file,data) in snapshots where file.type=="image" {
            guard let source=CGImageSourceCreateWithData(data as CFData,nil),CGImageSourceGetCount(source)==1,CGImageSourceCreateImageAtIndex(source,0,nil) != nil else { throw VideoError.invalid("小恐龙实际图片不能解码") }
        }
        let rightsAsset=try repository.ingest(rightsData,name:"dino-rights-v1.txt",workspaceID:workspaceID,mediaType:"text")
        var prepared:[(File,Asset)]=[]
        for (file,data) in snapshots {
            var asset=try repository.ingest(data,name:file.name,workspaceID:workspaceID,mediaType:file.type)
            if file.type=="audio" {
                let audio=try AVAudioFile(forReading:repository.assetURL(asset))
                let seconds=Double(audio.length)/audio.processingFormat.sampleRate
                guard seconds.isFinite,seconds>0,seconds<10,audio.processingFormat.sampleRate==48000 else { throw VideoError.invalid("小恐龙原音实际时长或格式无效") }
                asset.durationFrames=Int(ceil(seconds*30));asset.warnings=["下载原音格式转换，未试听；非课程旁白"]
            }
            prepared.append((file,asset))
        }
        return try repository.transaction { database in
            guard database.workspaces.contains(where:{$0.id==workspaceID}) else { throw VideoError.conflict("导入期间目标工作区已变化") }
            var rights=rightsAsset
            if let old=database.assets.first(where:{$0.workspaceID==workspaceID && $0.name==rights.name && $0.hash==rights.hash}) { rights=old }
            else {
                let proof=Evidence(workspaceID:workspaceID,title:"Chromium BSD-3-Clause原许可与来源",source:upstream+"LICENSE",claim:"原版权、作者表及各文件来源/派生/转换记录完整保留；不自动批准具体商业传播用途或作者背书。",owner:owner,commercialAllowed:false,verified:true,assetID:rights.id)
                rights.evidenceID=proof.id;database.assets.append(rights);database.evidence.append(proof)
            }
            var byName:[String:Asset]=[:],sources:[ClassicSource]=[]
            for (file,var asset) in prepared {
                if let old=database.assets.first(where:{$0.workspaceID==workspaceID && $0.name==file.name && $0.hash==file.hash}) {
                    guard let id=old.evidenceID,let proof=database.evidence.first(where:{$0.id==id && $0.workspaceID==workspaceID}),proof.source==file.source,proof.owner==owner else { throw VideoError.conflict("小恐龙具体素材来源已变化，请先核对资料库："+file.name) }
                    asset=old // Re-import cannot silently reapprove a user's revoked source record.
                } else {
                    let proof=Evidence(workspaceID:workspaceID,title:"Chrome小恐龙 · "+file.name,source:file.source,claim:"固定Chromium版本的具体原件或其实际Q派生/PCM格式转换；BSD原文和作者完整关联，短音效不充当课程配音，具体商业用途另审。",owner:owner,commercialAllowed:false,verified:true,assetID:rights.id)
                    asset.evidenceID=proof.id;asset.tags=["Chrome离线小恐龙","实际Q版素材v1","BSD-3-Clause"]
                    database.assets.append(asset);database.evidence.append(proof)
                }
                byName[file.name]=asset
                sources.append(ClassicSource(assetID:asset.id,hash:asset.hash,source:file.source,owner:owner,license:"BSD-3-Clause；原件/实际派生/格式转换分别留存，具体用途另审",evidenceID:asset.evidenceID!))
            }
            let original=byName["dino-offline-sprite-original.png"]!,hero=byName["dino-hero-q-v1.png"]!,background=byName["dino-backdrop-q-v2.png"]!,actions=byName["dino-actions-q-v1.png"]!
            var sprites=[ClassicSprite(role:"hero",assetID:hero.id,x:347.0/1536,y:162.0/1024,width:845.0/1536,height:742.0/1024),ClassicSprite(role:"floor",assetID:background.id,x:0,y:0.80,width:0.70,height:0.12),ClassicSprite(role:"backdrop",assetID:background.id),ClassicSprite(role:"knowledge_backdrop",assetID:background.id,x:0,y:0,width:0.80,height:1),ClassicSprite(role:"obstacle",assetID:background.id,x:1740.0/2048,y:397.0/683,width:260.0/2048,height:170.0/683)]
            // Actual alpha silhouettes, including a six-pixel edge margin. No cell crosses
            // another pose and no missing crate/wall is invented for the legacy model.
            let poses:[(String,Double,Double,Double,Double)]=[
                ("hero_idle",87,137,349,332),("hero_walk",586,143,367,330),
                ("hero_walk_alt",1067,137,399,333),("hero_contribute",75,647,402,300),
                ("hero_success",587,562,368,324),("hero_blocked",1075,602,389,345)
            ]
            sprites += poses.map { ClassicSprite(role:$0.0,assetID:actions.id,x:$0.1/1536,y:$0.2/1024,width:$0.3/1536,height:$0.4/1024) }
            let artwork=ClassicArtwork(gameplay:.platformer,sprites:sprites,sources:sources,derivation:.qStyle,transformation:"基于官方Chrome小恐龙sprite的同角色Q派生、六动作图集及同仙人掌/云/地面宽幅Q场景；具体两次派生提示词与版本随来源原件保留。已有像素实际裁切，未创造箱子/墙或冒充原游戏规则；知识因果由明确教学模型驱动。",originalAssetIDs:[original.id])
            return DinoImportedPack(artwork:artwork,audioAssets:files.filter{$0.type=="audio"}.map{byName[$0.name]!})
        }
    }
}
