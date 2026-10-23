import Foundation

public enum ClassicSceneEditing {
    public static func binding(_ artwork:ClassicArtwork,character:String,to original:Scene,assets:[Asset],evidence:[Evidence],workspaceID:String,requireQStyle:Bool=false)throws->Scene {
        guard !original.locked,[SceneKind.simulation,.cartoon].contains(original.kind),!character.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw VideoError.permission("请先解锁实际规则/角色镜头并选择已知角色")}
        guard !requireQStyle || artwork.derivation == .qStyle else{throw VideoError.review("下载原件尚未完成实际Q版派生，不能用于新高级成片；请保留原件并绑定真实处理产物")}
        var scene=original;scene.classicArtwork=artwork;scene.classicArtworkRequired=true;scene.character=character
        scene.characterProfile=CharacterProfile(name:character,expressions:scene.characterProfile?.expressions ?? ["好奇","思考","开心"],actions:scene.characterProfile?.actions ?? ["讲解","指向","点头"],evidenceIDs:artwork.evidenceIDs.sorted(),original:false)
        try ClassicArtworkRules.validate(scene:scene,assets:assets.filter{$0.workspaceID==workspaceID})
        for source in artwork.sources {
            guard evidence.contains(where:{$0.id==source.evidenceID && $0.workspaceID==workspaceID && $0.source==source.source && $0.owner==source.owner})else{throw VideoError.permission("绑定图集的来源证据缺失或越出工作区")}
        }
        return scene
    }
    public static func source(assetID:String,assets:[Asset],evidence:[Evidence],workspaceID:String)throws->ClassicSource {
        guard let asset=assets.first(where:{$0.id==assetID && $0.workspaceID==workspaceID}),
              let e=evidence.first(where:{$0.id==asset.evidenceID && $0.workspaceID==workspaceID}),
              !e.source.isEmpty,!e.owner.isEmpty else{throw VideoError.review("请先为此具体原件保存来源、权利人和适用授权；不会由公开下载推断商用许可")}
        return ClassicSource(assetID:asset.id,hash:asset.hash,source:e.source,owner:e.owner,license:"以关联来源原件与权利凭据为准；使用范围、期限和商用需逐项核对",evidenceID:e.id)
    }
    /// The caller must supply an actual edited atlas and different original bytes.
    /// This binds existing files; it does not relabel an unedited image as a generated output.
    public static func derivedAtlas(assetID:String,originalAssetIDs:[String],gameplay:ClassicGameplay,transformation:String,assets:[Asset],evidence:[Evidence],workspaceID:String)throws->ClassicArtwork {
        guard !originalAssetIDs.isEmpty,Set(originalAssetIDs).count==originalAssetIDs.count,
              let image=assets.first(where:{$0.id==assetID && $0.workspaceID==workspaceID && $0.mediaType.hasPrefix("image")}),
              originalAssetIDs.allSatisfy({id in assets.contains{$0.id==id && $0.workspaceID==workspaceID && $0.mediaType.hasPrefix("image") && $0.hash != image.hash}}),
              !transformation.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw VideoError.review("须选择实际编辑后的Q版图集、不同原件和明确处理过程；不能仅给原件改标签")}
        let sources=try ([assetID]+originalAssetIDs).map{try source(assetID:$0,assets:assets,evidence:evidence,workspaceID:workspaceID)}
        return .quadrants(assetID:assetID,gameplay:gameplay,sources:sources,derivation:.qStyle,transformation:transformation,originalAssetIDs:originalAssetIDs)
    }
    public static func addingCue(assetID:String,startFrame:Int,gain:Double,use:ClassicAudioCue.Use,extendScene:Bool,to original:Scene,assets:[Asset],evidence:[Evidence],workspaceID:String)throws->Scene {
        guard !original.locked,var artwork=original.classicArtwork,
              let asset=assets.first(where:{$0.id==assetID && $0.workspaceID==workspaceID && $0.mediaType=="audio"}),
              let frames=asset.durationFrames,frames>0,startFrame>=0,startFrame<=54000-frames else{throw VideoError.invalid("请选择真实录音、非负起点和有效时长")}
        let record=try source(assetID:assetID,assets:assets,evidence:evidence,workspaceID:workspaceID)
        let end=startFrame+frames
        guard end<=original.durationFrames || extendScene else{throw VideoError.review("下载录音超出镜头，请明确延长后再绑定；不会截断原音句尾")}
        var scene=original
        if end>scene.durationFrames {scene.durationFrames=end;scene.simulationRecordingConfirmed=false}
        artwork.sources.removeAll{$0.assetID==assetID};artwork.sources.append(record)
        artwork.audioCues.append(ClassicAudioCue(assetID:assetID,startFrame:startFrame,durationFrames:frames,gain:gain,use:use,listened:false))
        scene.classicArtwork=artwork
        try ClassicArtworkRules.validate(scene:scene,assets:assets.filter{$0.workspaceID==workspaceID})
        return scene
    }
}
