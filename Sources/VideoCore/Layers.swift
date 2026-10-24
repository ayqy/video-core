import Foundation

public struct SceneLayer: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case text="文字", image="图片", rectangle="色块", chart="数据图表", code="代码演示" }
    public var id=Codec.id(); public var kind:Kind; public var text:String; public var assetID:String?
    public var x:Double=0.5; public var y:Double=0.5; public var width:Double=0.5; public var height:Double=0.2
    public var color="FFFFFF"; public var opacity:Double=1; public var startFrame:Int=0; public var endFrame:Int
    public var locked=false; public var keyframes:[Keyframe]=[]
    /// Nil remains absent in old encodings and therefore preserves old digests.
    public var dataPresentation: DataPresentation?
    /// Optional source-timed entrance; nil preserves the original layer encoding.
    public var entrance: LayerEntrance?
    public init(kind:Kind,text:String="",assetID:String?=nil,endFrame:Int) { self.kind=kind;self.text=text;self.assetID=assetID;self.endFrame=endFrame }
    public func layout(at frame:Int)->(x:Double,y:Double,scale:Double) { var s=Scene(title:"layer",body:"");s.x=x;s.y=y;s.keyframes=keyframes;return s.layout(at:frame) }
}
public enum LayerRules {
    public static func validate(scene:Scene,assets:[Asset]) throws {
        let layers=scene.layers ?? []
        guard layers.count<=32,Set(layers.map(\.id)).count==layers.count else { throw VideoError.invalid("单镜头最多32个元素，元素ID不能重复") }
        for l in layers {
            guard (0...1).contains(l.x),(0...1).contains(l.y),(0.01...1).contains(l.width),(0.01...1).contains(l.height),(0...1).contains(l.opacity),l.startFrame>=0,l.endFrame>l.startFrame,l.endFrame<=scene.durationFrames,l.color.range(of:"^[A-Fa-f0-9]{6}$",options:.regularExpression) != nil else { throw VideoError.invalid("元素尺寸、位置、颜色、透明度或时间区间无效") }
            guard Set(l.keyframes.map(\.frame)).count==l.keyframes.count,l.keyframes.allSatisfy({$0.frame>=l.startFrame && $0.frame<l.endFrame && (0...1).contains($0.x) && (0...1).contains($0.y) && (0.1...4).contains($0.scale)}) else { throw VideoError.invalid("元素关键帧越界或重复") }
            try l.entrance?.validate(endFrame:l.endFrame)
            if l.kind == .text { guard !l.text.isEmpty,l.text.count<=180 else { throw VideoError.invalid("文字元素内容为空或过密") } }
            if l.kind == .image { guard let id=l.assetID,assets.contains(where:{$0.id==id && $0.mediaType.hasPrefix("image")}) else { throw VideoError.invalid("图片元素缺少实际图片") } }
            if l.kind == .chart || l.kind == .code {
                guard let data=l.dataPresentation,l.assetID == nil,l.text.isEmpty else { throw VideoError.invalid("图表/代码元素须绑定数据展示，不能隐藏图片引用或重复文字") }
                try data.validate(kind:l.kind,endFrame:l.endFrame)
            } else if l.dataPresentation != nil { throw VideoError.invalid("普通文字、图片、色块不接受隐藏数据展示") }
        }
    }
    public static func protectLocked(old:Scene,new:Scene) throws {
        for layer in old.layers ?? [] where layer.locked { guard new.layers?.first(where:{$0.id==layer.id})==layer else { throw VideoError.permission("元素已锁定，请先解锁此元素再修改/删除") } }
    }
}
public enum CommentRules {
    public static func validate(_ comment:Comment,project:Project) throws {
        guard let revision=project.revisions.first(where:{$0.id==comment.revisionID}),comment.frame>=0,comment.frame<revision.frames,!comment.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!comment.author.isEmpty else { throw VideoError.invalid("批注须绑定实际版本、有效帧、作者和非空内容") }
        if let id=comment.sceneID {
            guard let scene=revision.scenes.first(where:{$0.id==id}) else { throw VideoError.notFound("批注场景不属于该版本") }
            var start=0
            for s in revision.scenes { if s.id==id { break };start+=s.timelineFrames }
            guard (start..<start+scene.timelineFrames).contains(comment.frame),["画面","标题","正文","旁白","字幕","价格","CTA"].contains(comment.element) || scene.layers?.contains(where:{$0.id==comment.element})==true else { throw VideoError.invalid("批注时间或元素不属于所选场景") }
        } else { guard comment.element=="整片" else { throw VideoError.invalid("元素批注须指定场景") } }
    }
}
public struct RevisionDifference: Identifiable, Sendable {
    public var id:String;public var scope:String;public var before:String;public var after:String
    public static func compare(_ old:Revision,_ new:Revision)->[RevisionDifference] {
        var rows:[RevisionDifference]=[]
        func add(_ id:String,_ label:String,_ a:String,_ b:String) { if a != b { rows.append(.init(id:id,scope:label,before:a,after:b)) } }
        func paper(_ value:PaperPresentation?)->String {guard let value else{return "原版式"};return (value.layout == .cover ? "封面":"纸面讲解")+" · v\(value.version) · 纸色 #"+value.paperColor+" · 墨色 #"+value.inkColor}
        add("product","产品事实",old.product.map{$0.name+" · "+$0.prices.map{$0.money.display}.joined(separator:",")} ?? old.contentName,new.product.map{$0.name+" · "+$0.prices.map{$0.money.display}.joined(separator:",")} ?? new.contentName)
        func briefText(_ value:ProductionBrief?)->String {guard let value else{return "未设置"};return [value.objective,value.intendedUse,value.modifications,value.aiDisclosure,value.commercialDisclosure,value.restrictions,value.permittedUntil.map(BeijingTime.string) ?? "按原授权期限",value.approvalRequired ? "需指定版审稿":"作者审核"].joined(separator:" · ")}
        add("purpose","用途",old.purpose.rawValue,new.purpose.rawValue);add("brief","制作Brief",briefText(old.productionBrief),briefText(new.productionBrief))
        add("aspect","画幅",old.aspect.rawValue,new.aspect.rawValue);add("cta","CTA",old.cta,new.cta);add("music","配乐",old.musicAssetID ?? "无",new.musicAssetID ?? "无")
        for id in Set(old.scenes.map(\.id)+new.scenes.map(\.id)).sorted() {
            let a=old.scenes.first{$0.id==id},b=new.scenes.first{$0.id==id}
            guard let a,let b else { rows.append(.init(id:id,scope:"场景",before:a?.title ?? "未存在",after:b?.title ?? "已移除"));continue }
            add(id+"order","场景位置",String(old.scenes.firstIndex{$0.id==id}!),String(new.scenes.firstIndex{$0.id==id}!))
            add(id+"title","标题",a.title,b.title);add(id+"body","正文",a.body,b.body);add(id+"speech","旁白",a.narration,b.narration)
            add(id+"paper","纸面呈现",paper(a.paperPresentation),paper(b.paperPresentation))
            add(id+"time","时长/速度","\(a.durationFrames)帧 / \(a.speed)×","\(b.durationFrames)帧 / \(b.speed)×")
            add(id+"asset","素材",a.assetID ?? "无",b.assetID ?? "无")
            if a.layers != b.layers { rows.append(.init(id:id+"layers",scope:"元素层",before:(a.layers ?? []).map{$0.kind.rawValue+":"+$0.text}.joined(separator:"\n"),after:(b.layers ?? []).map{$0.kind.rawValue+":"+$0.text}.joined(separator:"\n"))) }
            if a.voice != b.voice || a.speechPlan != b.speechPlan { rows.append(.init(id:id+"voice",scope:"发音/声音",before:a.voice?.assetID ?? "未绑定",after:b.voice?.assetID ?? "未绑定，待重做")) }
        }
        return rows
    }
}
