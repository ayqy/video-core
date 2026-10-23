import Foundation
import AVFoundation
import VideoCore

public struct VoicePromptImportedPack: Sendable {
    public var audioAssets: [Asset]
}

/// Existing Kenney recordings only; no voice generation or renderer entitlement.
public enum VoicePromptBuiltinAssets {
    private static let upstream = "https://github.com/Mcamento8/open-game-sfx-index/blob/34bbe8b525b5ceff3804915ea745532af11f6055/audio/voiceover-pack/Female/"
    private static let owner = "Kenney Vleugels（Kenney.nl）"
    private struct File {
        let name: String; let hash: String; let original: String; let phrase: String; let rawName: String?
        var source: String { upstream+original+(rawName == nil ? "":"；完整原录音仅转PCM16 mono 48kHz WAV") }
    }
    private static let files: [File] = [
        File(name:"voice-prompt-ready-original.ogg",hash:"4a49258fab1f84b00d0060e1535218b22a3b4bba61ef4d989b82e4cab15d69b3",original:"ready.ogg",phrase:"Ready（准备好）",rawName:nil),
        File(name:"voice-prompt-go-original.ogg",hash:"1ba6aa2cb3710fd7c6e021622b4ef0428a0107c8f2db2e0dda8de8bcbdb56fd3",original:"go.ogg",phrase:"Go（开始）",rawName:nil),
        File(name:"voice-prompt-you-win-original.ogg",hash:"18907e24f8cbd0751831eed8d2dd1c2501ed587da6a7451404edf0876aa56150",original:"you_win.ogg",phrase:"You win（你赢了）",rawName:nil),
        File(name:"voice-prompt-ready.wav",hash:"4d242db0067641d742d0a3f27172ffb4e259a0efad6d65fc714fa58abb296511",original:"ready.ogg",phrase:"Ready（准备好）",rawName:"voice-prompt-ready-original.ogg"),
        File(name:"voice-prompt-go.wav",hash:"0087e174960ccd79e87eff71bd008cf474dc30c9610061cf2bc59216177fba7f",original:"go.ogg",phrase:"Go（开始）",rawName:"voice-prompt-go-original.ogg"),
        File(name:"voice-prompt-you-win.wav",hash:"533af68a42da1e94784d997dbb58c87cc2b3f83d94aa7aa0952d62d1ce37e138",original:"you_win.ogg",phrase:"You win（你赢了）",rawName:"voice-prompt-you-win-original.ogg")
    ]
    private static let documents = [
        ("AUTHOR-LICENSE.txt","57d021b53ab176ba287ee0e32abe3a31df86a2449715bf437789cf9779cc1d4e"),
        ("SOURCES.md","bc3d4beba8ea1ad941928331250a5c96b5fc512c977bca0621fa583f1917bccb")
    ]
    public static func importPack(bundle: Bundle = .main, workspaceID: String, repository: Repository) async throws -> VoicePromptImportedPack {
        try await importPack(workspaceID:workspaceID,repository:repository) { name in
            let part=name as NSString
            guard let url=bundle.url(forResource:part.deletingPathExtension,withExtension:part.pathExtension,subdirectory:"VoicePrompt") else { throw VideoError.notFound("已核权英文提示配音包未安装："+name) }
            return url
        }
    }
    public static func importPack(from directory: URL, workspaceID: String, repository: Repository) async throws -> VoicePromptImportedPack {
        try await importPack(workspaceID:workspaceID,repository:repository) { directory.appendingPathComponent($0) }
    }
    private static func read(_ url: URL, hash: String) throws -> Data {
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              let size=(attributes[.size] as? NSNumber)?.intValue,(1...2*1024*1024).contains(size) else { throw VideoError.invalid("提示配音只接受有界的普通单链接原件") }
        let data=try Data(contentsOf:url)
        guard data.count==size,Codec.hash(data)==hash else { throw VideoError.review("提示配音原件、转换或许可版本摘要不符："+url.lastPathComponent) }
        return data
    }
    private static func importPack(workspaceID: String, repository: Repository, url: (String) throws -> URL) async throws -> VoicePromptImportedPack {
        try Task.checkCancellation()
        guard try repository.read().workspaces.contains(where:{$0.id==workspaceID}) else { throw VideoError.permission("请先选择已有工作区再导入提示配音") }
        var rightsData=Data("Kenney英文原录音提示：完整原作者CC0与具体原件/PCM关系\n\n".utf8)
        for (name,hash) in documents { rightsData.append(try read(url(name),hash:hash));rightsData.append(Data("\n\n".utf8)) }
        let snapshots=try files.map { ($0,try read(url($0.name),hash:$0.hash)) }
        var durations:[String:Int]=[:]
        // Decode every native recording, then verify the input again, before any CAS write.
        for (file,data) in snapshots where file.rawName != nil {
            let location=try url(file.name),audio=try AVAudioFile(forReading:location)
            let seconds=Double(audio.length)/audio.processingFormat.sampleRate
            guard seconds.isFinite,seconds>0,seconds<10,audio.processingFormat.sampleRate==48000,audio.processingFormat.channelCount==1,
                  let buffer=AVAudioPCMBuffer(pcmFormat:audio.processingFormat,frameCapacity:AVAudioFrameCount(audio.length)) else { throw VideoError.invalid("提示配音实际格式或完整时长无效") }
            try audio.read(into:buffer)
            guard AVAudioFramePosition(buffer.frameLength)==audio.length,try read(location,hash:file.hash)==data else { throw VideoError.conflict("提示配音解码不完整或读取期间原件变化") }
            durations[file.name]=Int(ceil(seconds*30))
        }
        try Task.checkCancellation()
        let rightsAsset=try repository.ingest(rightsData,name:"voice-prompt-rights-v1.txt",workspaceID:workspaceID,mediaType:"text")
        let prepared=try snapshots.map { file,data -> (File,Asset) in
            var asset=try repository.ingest(data,name:file.name,workspaceID:workspaceID,mediaType:file.rawName == nil ? "source_audio":"audio")
            if let frames=durations[file.name] { asset.durationFrames=frames;asset.warnings=[file.phrase+"；英文原录音提示，未试听；非游戏角色原配音或中文课程旁白"] }
            return(file,asset)
        }
        return try repository.transaction { database in
            try Task.checkCancellation()
            guard database.workspaces.contains(where:{$0.id==workspaceID}) else { throw VideoError.conflict("导入期间目标工作区已变化") }
            func save(_ candidate:Asset,source:String,title:String,claim:String,proofAssetID:String,tags:[String]) throws -> Asset {
                if let old=database.assets.first(where:{$0.workspaceID==workspaceID && $0.name==candidate.name && $0.hash==candidate.hash}) {
                    guard let id=old.evidenceID,let proof=database.evidence.first(where:{$0.id==id && $0.workspaceID==workspaceID}),proof.source==source,proof.owner==owner,proof.assetID==proofAssetID else { throw VideoError.conflict("提示配音具体来源关联已变化，请先核对资料库："+candidate.name) }
                    return old // Preserve the user's revocation, expiry and approval decisions.
                }
                var asset=candidate
                let proof=Evidence(workspaceID:workspaceID,title:title,source:source,claim:claim,owner:owner,commercialAllowed:false,verified:true,assetID:proofAssetID)
                asset.evidenceID=proof.id;asset.tags=tags;database.assets.append(asset);database.evidence.append(proof)
                return asset
            }
            let rights=try save(rightsAsset,source:"https://kenney.nl/assets/voiceover-pack",title:"Kenney Voiceover Pack #1完整原作者CC0与固定来源",claim:"CC0原文和三段实际下载/格式转换关系完整保留；不自动批准具体商业用途、上传或听审。",proofAssetID:database.assets.first(where:{$0.workspaceID==workspaceID && $0.name==rightsAsset.name && $0.hash==rightsAsset.hash})?.id ?? rightsAsset.id,tags:["英文提示配音来源","CC0原文"])
            var byName:[String:Asset]=[:]
            for (file,asset) in prepared {
                let parent=file.rawName.map{byName[$0]!.id} ?? rights.id
                byName[file.name]=try save(asset,source:file.source,title:"Kenney英文原录音提示 · "+file.phrase,claim:"完整原提示录音或其PCM格式转换；台词为 "+file.phrase+"，非Dino原配音、非中文课程旁白，尚未试听及批准具体商业用途。",proofAssetID:parent,tags:["英文提示配音v1",file.phrase,"CC0来源；具体用途另审"])
            }
            return VoicePromptImportedPack(audioAssets:files.filter{$0.rawName != nil}.map{byName[$0.name]!})
        }
    }
}
