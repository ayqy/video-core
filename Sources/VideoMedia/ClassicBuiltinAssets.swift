import Foundation
import AVFoundation
import VideoCore

public struct ClassicImportedPack: Sendable {
    public var platformer:ClassicArtwork;public var match3:ClassicArtwork;public var audioAssets:[Asset]
}
public enum ClassicBuiltinAssets {
    private struct File {
        var name:String;var hash:String;var source:String;var owner:String="Kenney";var type:String
    }
    private static let platformSource="https://github.com/ar-bh/basic-2d-platformer/tree/26f66456b325e5161f39138abbfbed7935f62ec0/addons/basic_2d_platformer/assets/kenney_pixel-platformer"
    private static let matchSource="https://github.com/KenneyNL/Starter-Kit-Match-3/tree/4ddb3d2a50cbf247c79cafe9e7884d7d8f99c012"
    private static let voiceSource="https://kenney.nl/assets/voiceover-pack"
    private static let files:[File] = [
        File(name:"classic-platformer-q-v1.png",hash:"021048ddcd37c1d61b68815542ddb5e101a14d9e35f32e878723987a70d04f65",source:platformSource+"；实际Q版派生v1（2026-10-22）",type:"image"),
        File(name:"classic-platformer-character-source.png",hash:"b4f63a99b228021c7c8106a09af47b1c9635e1a20b9dd9e6e666c9b36cc7d259",source:platformSource+"/Tilemap/tilemap-characters.png",type:"image"),
        File(name:"classic-platformer-tiles-source.png",hash:"75c4eb86e8ceba008cd73bfd839609e91de1ab32686ccd34dff904cfd39883ed",source:platformSource+"/Tilemap/tilemap.png",type:"image"),
        File(name:"classic-match3-q-v1.png",hash:"d4bd7fa21e03753dee2e06d9b3dcceec92a447ef52dabbb0bc344da898ee3bfe",source:matchSource+"；实际Q版宝石派生v1（2026-10-22）",type:"image"),
        File(name:"classic-match3-source-gem.png",hash:"40e70dd7fd6a0a951d309bdf6a2063e6593f52e753195bde3799dce3d1e74e30",source:matchSource+"/sprites/tiles/tile-gem.png",type:"image"),
        File(name:"classic-match3-background.png",hash:"20ef58767f26203237acd487211801dc13cdeddcd93bb452af4bde841b64f8db",source:matchSource+"/sprites/backgrounds/background.png",type:"image"),
        File(name:"classic-tile-land.wav",hash:"71538a1f166ee4f57d2af84de1a00e20c8a6ec836e39a885fa88d1ceaab7cccc",source:matchSource+"/sounds/tile-land.ogg；只转PCM WAV",type:"audio"),
        File(name:"classic-tile-match.wav",hash:"41eb3fec496d4f63e3594579c30eac12d58094a5103644eb628852bb77971a80",source:matchSource+"/sounds/tile-match.ogg；只转PCM WAV",type:"audio"),
        File(name:"classic-tile-swap.wav",hash:"2b9d45863208fb04eef53bcbdc30b7f6f9d5a6a623698b2344bc2c4c3858dac7",source:matchSource+"/sounds/tile-swap.ogg；只转PCM WAV",type:"audio"),
        File(name:"classic-voice-ready.wav",hash:"4d242db0067641d742d0a3f27172ffb4e259a0efad6d65fc714fa58abb296511",source:voiceSource+"；Female/ready.ogg，仅转PCM WAV，英文提示",type:"audio"),
        File(name:"classic-voice-go.wav",hash:"0087e174960ccd79e87eff71bd008cf474dc30c9610061cf2bc59216177fba7f",source:voiceSource+"；Female/go.ogg，仅转PCM WAV，英文提示",type:"audio"),
        File(name:"classic-voice-you-win.wav",hash:"533af68a42da1e94784d997dbb58c87cc2b3f83d94aa7aa0952d62d1ce37e138",source:voiceSource+"；Female/you_win.ogg，仅转PCM WAV，英文提示",type:"audio")
    ]
    public static func importPack(bundle:Bundle = .main,workspaceID:String,repository:Repository) async throws -> ClassicImportedPack {
        try await importPack(workspaceID:workspaceID,repository:repository) { name in
            let file=name as NSString
            guard let url=bundle.url(forResource:file.deletingPathExtension,withExtension:file.pathExtension) ?? bundle.url(forResource:file.deletingPathExtension,withExtension:file.pathExtension,subdirectory:"Classic") else{throw VideoError.notFound("内置经典游戏素材未安装："+name)}
            return url
        }
    }
    /// Only the published, hash-pinned passive media files are accepted. No code or arbitrary manifest is executed.
    public static func importPack(from directory:URL,workspaceID:String,repository:Repository) async throws -> ClassicImportedPack {
        try await importPack(workspaceID:workspaceID,repository:repository) {name in directory.appendingPathComponent(name)}
    }
    private static func boundedData(_ url:URL)throws->Data {
        let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile==true,values.isSymbolicLink != true,let size=values.fileSize,size>0,size<=8*1024*1024 else{throw VideoError.invalid("素材包只接受有界的普通媒体和许可文件")}
        let data=try Data(contentsOf:url,options:.mappedIfSafe)
        guard data.count==size else{throw VideoError.conflict("素材包读取时文件发生变化，请重新选择稳定的副本")};return data
    }
    private static func importPack(workspaceID:String,repository:Repository,url:(String)throws->URL) async throws -> ClassicImportedPack {
        let initial=try repository.read()
        guard initial.workspaces.contains(where:{$0.id==workspaceID}) else{throw VideoError.permission("素材包必须导入当前已有工作区")}
        let licenseData=try boundedData(url("classic-licenses.txt")),sourceData=try boundedData(url("classic-sources.md"))
        guard Codec.hash(licenseData)=="2be156e6cae148d0e2bda4ad9060e7bc37d2def770233fc83a9d1401c50ff42f",Codec.hash(sourceData)=="a43659d75e414392c993158d22fef15ff19aa61708b27a6a6e08fdf8eee6339d" else{throw VideoError.review("内置来源或许可文本摘要不符，请重新安装相符版本素材包")}
        var rightsData=Data("内置Kenney素材原许可与具体来源记录\n\n".utf8);rightsData.append(licenseData);rightsData.append(Data("\n\n具体来源核对记录\n\n".utf8));rightsData.append(sourceData)
        let rightsAsset=try repository.ingest(rightsData,name:"classic-rights-v1.txt",workspaceID:workspaceID,mediaType:"text")
        var prepared:[(File,Asset)]=[]
        // Validate the whole bounded allowlist before mutating database records.
        for file in files {
            let location=try url(file.name),data=try boundedData(location)
            guard data.count<=8*1024*1024,Codec.hash(data)==file.hash else{throw VideoError.review("内置素材版本或摘要不符："+file.name)}
            let asset=try await MaterialImporter.importFile(location,workspaceID:workspaceID,repository:repository)
            prepared.append((file,asset))
        }
        var result:ClassicImportedPack?
        try repository.transaction { database in
            var rights=rightsAsset
            if let existing=database.assets.first(where:{$0.workspaceID==workspaceID && $0.name==rights.name && $0.hash==rights.hash}) {rights=existing}
            else {
                let proof=Evidence(workspaceID:workspaceID,title:"内置原许可与来源记录",source:"https://kenney.nl/assets；逐文件固定提交与原件比对记录见附件文本",claim:"包含Kenney公开CC0许可原文与本产品独立整理的来源核对记录，许可不扩张至第三方商标或其它IP。",owner:"Kenney（许可原文）；方方（来源核对记录）",commercialAllowed:true,verified:true,assetID:rights.id)
                rights.evidenceID=proof.id;database.evidence.append(proof);database.assets.append(rights)
            }
            var byName:[String:Asset]=[:],sourceByID:[String:ClassicSource]=[:]
            for (file,var asset) in prepared {
                if let existing=database.assets.first(where:{$0.workspaceID==workspaceID && $0.name==file.name && $0.hash==file.hash}) {
                    guard let id=existing.evidenceID,let proof=database.evidence.first(where:{$0.id==id && $0.workspaceID==workspaceID}),proof.source==file.source,proof.owner==file.owner else{throw VideoError.conflict("内置素材来源记录已修改，请先在资料库核对："+file.name)}
                    asset=existing
                } else {
                    let proof=Evidence(workspaceID:workspaceID,title:"Kenney CC0 · "+file.name,source:file.source,claim:"该具体素材的原作者明确以CC0发布；原件经固定SHA核对。Q图为上述CC0原件的视觉派生，声音为下载原录音的格式转换。不是知名游戏商标/角色或中文课程旁白的授权。",owner:file.owner,commercialAllowed:true,verified:true,assetID:rights.id)
                    asset.evidenceID=proof.id;asset.tags=["内置经典游戏素材v1","CC0-1.0"];database.evidence.append(proof);database.assets.append(asset)
                }
                byName[file.name]=asset
                sourceByID[asset.id]=ClassicSource(assetID:asset.id,hash:asset.hash,source:file.source,owner:file.owner,license:"CC0-1.0；原件与真实视觉派生/音频格式转换分别留存",evidenceID:asset.evidenceID!)
            }
            let q=byName["classic-platformer-q-v1.png"]!,characters=byName["classic-platformer-character-source.png"]!,tiles=byName["classic-platformer-tiles-source.png"]!
            let gem=byName["classic-match3-source-gem.png"]!,match=byName["classic-match3-q-v1.png"]!,background=byName["classic-match3-background.png"]!
            let hero=ClassicSprite(role:"hero",assetID:q.id,width:0.5,height:0.5)
            let platformSprites=[hero,ClassicSprite(role:"crate",assetID:q.id,x:0.5,width:0.5,height:0.5),ClassicSprite(role:"floor",assetID:q.id,y:0.5,width:0.5,height:0.5),ClassicSprite(role:"wall",assetID:q.id,y:0.5,width:0.5,height:0.5),ClassicSprite(role:"coin",assetID:q.id,x:0.5,y:0.5,width:0.5,height:0.5)]
            let platform=ClassicArtwork(gameplay:.platformer,sprites:platformSprites,sources:[q,characters,tiles].map{sourceByID[$0.id]!},derivation:.qStyle,transformation:"基于Kenney Pixel Platformer已下载原件的实际图像编辑输出；四格顺序角色/箱子/草地/金币；原角色保持可辨，不是知名原版IP。",originalAssetIDs:[characters.id,tiles.id])
            let matchSprites=[hero,ClassicSprite(role:"crate",assetID:match.id,width:0.5,height:0.5),ClassicSprite(role:"floor",assetID:background.id),ClassicSprite(role:"wall",assetID:q.id,y:0.5,width:0.5,height:0.5)]
            let matching=ClassicArtwork(gameplay:.match3,sprites:matchSprites,sources:[q,characters,tiles,match,gem,background].map{sourceByID[$0.id]!},derivation:.qStyle,transformation:"基于Kenney普通宝石真实Q版图像编辑输出；紫/绿/蓝/金四格，无品牌logo。外部探险员复用同包已授权角色。",originalAssetIDs:[gem.id,characters.id,tiles.id])
            result=ClassicImportedPack(platformer:platform,match3:matching,audioAssets:files.filter{$0.type=="audio"}.compactMap{byName[$0.name]})
        }
        guard let result else{throw VideoError.unavailable("素材包导入未完成")};return result
    }
}
