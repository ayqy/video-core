import Foundation

/// The exported cover is an editable composition. It does not insert a title
/// into the movie or change the movie's first-second narration.
public enum CoverStyle: String, Codable, CaseIterable, Sendable {
    case automatic, explanation, pencil, presenter, game, cartoon, media, chart, code
}
public enum CoverTemplate: String, Codable, CaseIterable, Sendable {
    case automatic, spotlight, editorial, contrast
}
/// Direction of the actual source gesture, before layout mirroring. This is
/// author-checked image metadata, not inferred from expression names.
public enum CoverPointing: String, Codable, CaseIterable, Sendable { case left, right }
public struct CoverImage: Codable, Equatable, Sendable {
    public var assetID: String
    public var sourceRect: MediaFraming?
    public var pointing: CoverPointing?
    public init(assetID: String, sourceRect: MediaFraming? = nil, pointing: CoverPointing? = nil) {
        self.assetID=assetID;self.sourceRect=sourceRect;self.pointing=pointing
    }
    private enum CodingKeys:String,CodingKey {case assetID,sourceRect,pointing}
    public init(from decoder:Decoder)throws {
        try CoverRules.keys(decoder,required:["assetID"],optional:["sourceRect","pointing"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        assetID=try c.decode(String.self,forKey:.assetID);sourceRect=try c.decodeIfPresent(MediaFraming.self,forKey:.sourceRect)
        pointing=try c.decodeIfPresent(CoverPointing.self,forKey:.pointing)
        guard CoverRules.text(assetID,maximum:200) else{throw VideoError.invalid("封面图片引用无效")}
        try sourceRect?.validate()
    }
}
/// Poses remain imported source images with normal CAS provenance. Keywords
/// choose between actual expressions/actions; code never draws a replacement IP.
public struct CoverPose: Codable, Equatable, Sendable {
    public var id: String
    public var image: CoverImage
    public var expression: String
    public var action: String
    public var keywords: [String]
    public init(id: String, image: CoverImage, expression: String, action: String, keywords: [String] = []) {
        self.id=id;self.image=image;self.expression=expression;self.action=action;self.keywords=keywords
    }
    private enum CodingKeys:String,CodingKey {case id,image,expression,action,keywords}
    public init(from decoder:Decoder)throws {
        try CoverRules.keys(decoder,required:["id","image","expression","action","keywords"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id);image=try c.decode(CoverImage.self,forKey:.image)
        expression=try c.decode(String.self,forKey:.expression);action=try c.decode(String.self,forKey:.action)
        keywords=try c.decode([String].self,forKey:.keywords)
    }
}
public struct CoverPresentation: Codable, Equatable, Sendable {
    public var version = 1
    public var style: CoverStyle
    public var template: CoverTemplate
    public var title: String?
    public var subtitle: String?
    /// Exact title substrings, never extra cover copy. Missing in legacy JSON.
    public var emphasis: [String]?
    public var hero: CoverImage?
    public var background: CoverImage?
    public var poses: [CoverPose]?
    public init(style: CoverStyle = .automatic, template: CoverTemplate = .automatic, title: String? = nil,
                subtitle: String? = nil, hero: CoverImage? = nil, background: CoverImage? = nil, poses: [CoverPose]? = nil,
                emphasis: [String]? = nil) {
        self.style=style;self.template=template;self.title=title;self.subtitle=subtitle
        self.hero=hero;self.background=background;self.poses=poses;self.emphasis=emphasis
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case version,style,template,title,subtitle,hero,background,poses,emphasis }
    public init(from decoder: Decoder) throws {
        let actual=Set(try decoder.container(keyedBy: CoverKey.self).allKeys.map(\.stringValue))
        guard actual.isSubset(of:Set(CodingKeys.allCases.map(\.rawValue))) else { throw VideoError.invalid("封面设置包含未知字段") }
        let c=try decoder.container(keyedBy:CodingKeys.self)
        version=try c.decode(Int.self,forKey:.version);style=try c.decode(CoverStyle.self,forKey:.style)
        template=try c.decode(CoverTemplate.self,forKey:.template);title=try c.decodeIfPresent(String.self,forKey:.title)
        subtitle=try c.decodeIfPresent(String.self,forKey:.subtitle);hero=try c.decodeIfPresent(CoverImage.self,forKey:.hero)
        background=try c.decodeIfPresent(CoverImage.self,forKey:.background);poses=try c.decodeIfPresent([CoverPose].self,forKey:.poses)
        emphasis=try c.decodeIfPresent([String].self,forKey:.emphasis)
        try validate()
    }
    public var images: [CoverImage] { [hero,background].compactMap{$0}+(poses ?? []).map(\.image) }
    public func validate() throws {
        guard version==1,title.map({CoverRules.text($0,maximum:160)}) ?? true,
              subtitle.map({CoverRules.text($0,maximum:100)}) ?? true,
              poses.map({(1...24).contains($0.count) && Set($0.map(\.id)).count==$0.count}) ?? true else {
            throw VideoError.invalid("封面版本、标题、副标题或姿态列表无效")
        }
        for image in images {
            guard CoverRules.text(image.assetID,maximum:200) else {throw VideoError.invalid("封面图片须引用已导入素材")}
            try image.sourceRect?.validate()
        }
        if let emphasis {
            guard (1...3).contains(emphasis.count),Set(emphasis).count==emphasis.count,
                  emphasis.allSatisfy({CoverRules.text($0,maximum:40) && !$0.contains("\n")}) else {
                throw VideoError.invalid("封面主题词须为一至三个不重复的标题片段")
            }
            if let title {try CoverRules.validateEmphasis(emphasis,title:title)}
        }
        for pose in poses ?? [] {
            guard CoverRules.text(pose.id,maximum:100),CoverRules.text(pose.expression,maximum:80),
                  CoverRules.text(pose.action,maximum:80),pose.keywords.count<=16,
                  Set(pose.keywords).count==pose.keywords.count,
                  pose.keywords.allSatisfy({CoverRules.text($0,maximum:40)}) else {
                throw VideoError.invalid("封面姿态须有唯一身份、表情、动作及有限主题词")
            }
        }
    }
}
public struct ResolvedCover: Equatable, Sendable {
    public var style: CoverStyle
    public var template: CoverTemplate
    public var title: String
    public var subtitle: String
    public var hero: CoverImage?
    public var background: CoverImage?
    public var poseID: String?
    public var emphasis: [String]
}
public enum CoverRules {
    static func keys(_ decoder:Decoder,required:Set<String>,optional:Set<String> = [])throws {
        let actual=Set(try decoder.container(keyedBy:CoverKey.self).allKeys.map(\.stringValue))
        guard required.isSubset(of:actual),actual.isSubset(of:required.union(optional)) else{throw VideoError.invalid("封面图片或姿态包含未知字段或缺少必填字段")}
    }
    static func text(_ value:String,maximum:Int)->Bool {
        !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.count<=maximum &&
        !value.unicodeScalars.contains{CharacterSet.controlCharacters.contains($0) && $0 != "\n"}
    }
    static func validateEmphasis(_ emphasis:[String],title:String)throws {
        var occupied=Set<Int>()
        let string=title as NSString
        for keyword in emphasis {
            var search=NSRange(location:0,length:string.length),found=false
            while search.length>0 {
                let range=string.range(of:keyword,options:[],range:search)
                if range.location==NSNotFound {break}
                let indices=Set(range.location..<(range.location+range.length))
                guard occupied.isDisjoint(with:indices) else {throw VideoError.invalid("封面主题词不可互相覆盖")}
                occupied.formUnion(indices);found=true
                search=NSRange(location:range.location+range.length,length:string.length-range.location-range.length)
            }
            guard found else {throw VideoError.invalid("封面主题词必须是实际标题中的文字")}
        }
    }
    public static func inferredStyle(revision:Revision)->CoverStyle {
        let scenes=revision.scenes
        if scenes.contains(where:{$0.cartoonPresenter != nil}) {return .presenter}
        if scenes.contains(where:{$0.kind == .simulation || $0.gameWorld != nil || $0.modelScene3D != nil}) {return .game}
        if scenes.contains(where:{$0.kind == .cartoon}) {return .cartoon}
        if scenes.contains(where:{($0.layers ?? []).contains{$0.kind == .code}}) {return .code}
        if scenes.contains(where:{($0.layers ?? []).contains{$0.kind == .chart}}) {return .chart}
        if scenes.contains(where:{$0.paperPresentation != nil || ($0.layers ?? []).contains{$0.kind == .image}}) {return .pencil}
        if scenes.contains(where:{$0.kind == .image || $0.kind == .video}) {return .media}
        return .explanation
    }
    public static func resolved(revision:Revision)throws->ResolvedCover {
        let value=revision.coverPresentation ?? CoverPresentation()
        try value.validate()
        let style=value.style == .automatic ? inferredStyle(revision:revision):value.style
        // A stable title-based choice gives new topics three layouts without
        // randomness, wall-clock dependencies or a paid image-generation call.
        let topic=revision.contentName.trimmingCharacters(in:.whitespacesAndNewlines)
        let isDouzijie=revision.scenes.contains {scene in
            scene.cartoonPresenter != nil && (scene.id.lowercased().contains("doubao") ||
            (scene.cartoonPresenter?.masterRole.lowercased().contains("doubao") ?? false) ||
            (scene.classicArtwork?.sources.contains{$0.license.contains("豆包")} ?? false))
        }
        let title=value.title ?? (style == .presenter && isDouzijie ? "豆子姐讲「"+topic+"」":topic)
        let templates:[CoverTemplate]=[.spotlight,.editorial,.contrast]
        let template=value.template == .automatic ? templates[topic.utf8.reduce(0,{$0+Int($1)})%templates.count]:value.template
        let emphasis=value.emphasis ?? (title.contains(topic) && !topic.isEmpty ? [topic]:[])
        try validateEmphasis(emphasis,title:title)
        let search=([title]+revision.scenes.map{$0.title+" "+$0.narration}).joined(separator:" ").lowercased()
        let selected=(value.poses ?? []).enumerated().sorted { left,right in
            func score(_ pose:CoverPose)->Int {pose.keywords.filter{search.contains($0.lowercased())}.reduce(0,{$0+$1.count})}
            let a=score(left.element),b=score(right.element)
            return a==b ? left.offset<right.offset:a>b
        }.first?.element
        var hero=value.hero ?? selected?.image
        // The already imported master keeps legacy presenter projects useful;
        // a new pose set is optional, never a geometric substitute for the IP.
        if hero==nil,style == .presenter,
           let scene=revision.scenes.first(where:{$0.cartoonPresenter != nil}),
           let role=scene.cartoonPresenter?.masterRole,
           let sprite=scene.classicArtwork?.sprites.first(where:{$0.role==role}) {
            hero=CoverImage(assetID:sprite.assetID,sourceRect:MediaFraming(x:sprite.x,y:sprite.y,width:sprite.width,height:sprite.height))
        }
        return ResolvedCover(style:style,template:template,title:title,subtitle:value.subtitle ?? "",hero:hero,background:value.background,poseID:value.hero == nil ? selected?.id:nil,emphasis:emphasis)
    }
    public static func validate(revision:Revision,assets:[Asset])throws {
        let cover=try resolved(revision:revision)
        let all=(revision.coverPresentation?.images ?? [])+[cover.hero,cover.background].compactMap{$0}
        for image in all {
            try image.sourceRect?.validate()
            guard assets.contains(where:{$0.id==image.assetID && $0.workspaceID==revision.workspaceID && ($0.mediaType=="image" || $0.mediaType.hasPrefix("image/"))}) else {
                throw VideoError.permission("封面图片缺失、不是图片或不属于当前工作区")
            }
        }
    }
}
private struct CoverKey:CodingKey {
    var stringValue:String;var intValue:Int?{nil}
    init?(stringValue:String){self.stringValue=stringValue};init?(intValue:Int){return nil}
}
