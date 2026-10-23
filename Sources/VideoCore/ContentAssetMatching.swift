import Foundation

public struct ContentAssetMatch: Sendable, Identifiable {
    public var id:String{asset.id}
    public var asset:Asset
    public var matchedTerms:[String]
    public var fields:[String]
    public var score:Int
}

/// Transparent local semantic hints. A score is a textual relevance hint, not a factual or rights verdict.
public enum ContentAssetMatching {
    private static func terms(_ value:String)->Set<String>{
        let parts=value.lowercased().components(separatedBy:CharacterSet.alphanumerics.inverted).filter{!$0.isEmpty}
        var result=Set(parts)
        for part in parts{
            let characters=Array(part)
            if characters.count>2,characters.contains(where:{$0.unicodeScalars.contains{($0.value>=0x3400 && $0.value<=0x9fff)}}){
                for index in 0..<(characters.count-1){result.insert(String(characters[index...index+1]))}
            }
        }
        return result
    }
    public static func search(query:String,workspaceID:String,assets:[Asset],evidence:[Evidence],mediaType:String?=nil)->[ContentAssetMatch]{
        let wanted=terms(query)
        return assets.filter{$0.workspaceID==workspaceID && (mediaType==nil || $0.mediaType==mediaType)}.compactMap{asset in
            let rights=evidence.first{$0.id==asset.evidenceID && $0.workspaceID==workspaceID}
            let fields:[(String,String,Int)]=[
                ("名称",asset.name,5),("标签",asset.tags.joined(separator:" "),6),
                ("材料文本",asset.pages.map{$0.text+" "+$0.notes}.joined(separator:" "),2),
                ("来源与允许用途",(rights?.title ?? "")+" "+(rights?.claim ?? ""),3)]
            var score=0,hits:Set<String>=[],matchedFields:[String]=[]
            for (name,text,weight) in fields{
                let lower=text.lowercased(),found=wanted.filter{lower.contains($0)}
                if !found.isEmpty{score += found.count*weight;hits.formUnion(found);matchedFields.append(name)}
            }
            guard wanted.isEmpty || score>0 else{return nil}
            return ContentAssetMatch(asset:asset,matchedTerms:hits.sorted(),fields:matchedFields,score:score)
        }.sorted{$0.score == $1.score ? ($0.asset.name == $1.asset.name ? $0.id<$1.id:$0.asset.name<$1.asset.name):$0.score>$1.score}
    }
    /// Replaces exactly one caller-selected scene. Existing text, other scenes and source provenance are retained.
    public static func replacing(scene:Scene,asset:Asset,workspaceID:String,startFrame:Int?=nil,endFrame:Int?=nil,lockAfter:Bool,assets:[Asset])throws->Scene{
        guard !scene.locked else{throw VideoError.permission("该场景已锁定，请先明确解锁")}
        guard asset.workspaceID==workspaceID,assets.contains(where:{$0.id==asset.id && $0.workspaceID==workspaceID && $0.hash==asset.hash}),["image","video"].contains(asset.mediaType) else{throw VideoError.permission("替换只接受当前工作区的真实图片或视频")}
        var next=scene
        next.kind=asset.mediaType=="image" ? .image:.video;next.assetID=asset.id
        next.sourceStartFrame=0;next.sourceEndFrame=nil
        if asset.mediaType=="video"{
            guard let total=asset.durationFrames,let start=startFrame,let end=endFrame,start>=0,end>start,end<=total else{throw VideoError.invalid("请选择实际媒体以内的源帧范围")}
            next.sourceStartFrame=start;next.sourceEndFrame=end;next.durationFrames=end-start
            next.captions=next.captions.filter{$0.startFrame<next.durationFrames}.map{caption in var c=caption;c.endFrame=min(c.endFrame,next.durationFrames);c.confirmed=false;return c}
            next.keyframes=next.keyframes.filter{$0.frame<next.durationFrames}
            if let voice=next.voice,voice.durationFrames>next.durationFrames{throw VideoError.review("替换片段短于当前旁白，先重排或重新配音，不截断句尾")}
            if (next.layers ?? []).contains(where:{$0.endFrame>next.durationFrames}){throw VideoError.review("替换片段短于当前图层范围，请先调整图层或选择更长片段")}
        }
        next.locked=lockAfter
        try next.validate(assets:assets.filter{$0.workspaceID==workspaceID})
        return next
    }
}
