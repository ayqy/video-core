import Foundation

public struct CartoonPresenterFrame:Codable,Equatable,Sendable {
    public var role:String;public var mouthOpen:Double
    public init(role:String,mouthOpen:Double){self.role=role;self.mouthOpen=mouthOpen}
    private enum CodingKeys:String,CodingKey {case role,mouthOpen}
    public init(from decoder:Decoder)throws {try PresenterDecoding.keys(decoder,["role","mouthOpen"]);let c=try decoder.container(keyedBy:CodingKeys.self);role=try c.decode(String.self,forKey:.role);mouthOpen=try c.decode(Double.self,forKey:.mouthOpen)}
}
public struct CartoonPresenterClip:Codable,Equatable,Sendable {
    public var id:String;public var frameDurationFrames:Int;public var frames:[CartoonPresenterFrame]
    public init(id:String,frameDurationFrames:Int=3,frames:[CartoonPresenterFrame]){self.id=id;self.frameDurationFrames=frameDurationFrames;self.frames=frames}
    private enum CodingKeys:String,CodingKey {case id,frameDurationFrames,frames}
    public init(from decoder:Decoder)throws {try PresenterDecoding.keys(decoder,["id","frameDurationFrames","frames"]);let c=try decoder.container(keyedBy:CodingKeys.self);id=try c.decode(String.self,forKey:.id);frameDurationFrames=try c.decode(Int.self,forKey:.frameDurationFrames);frames=try c.decode([CartoonPresenterFrame].self,forKey:.frames)}
}
public struct CartoonPresenterCue:Codable,Equatable,Sendable {
    public var startFrame:Int;public var endFrame:Int;public var clipID:String;public var animationOffsetFrames:Int
    public init(startFrame:Int,endFrame:Int,clipID:String,animationOffsetFrames:Int=0){self.startFrame=startFrame;self.endFrame=endFrame;self.clipID=clipID;self.animationOffsetFrames=animationOffsetFrames}
    private enum CodingKeys:String,CodingKey {case startFrame,endFrame,clipID,animationOffsetFrames}
    public init(from decoder:Decoder)throws {try PresenterDecoding.keys(decoder,["startFrame","endFrame","clipID","animationOffsetFrames"]);let c=try decoder.container(keyedBy:CodingKeys.self);startFrame=try c.decode(Int.self,forKey:.startFrame);endFrame=try c.decode(Int.self,forKey:.endFrame);clipID=try c.decode(String.self,forKey:.clipID);animationOffsetFrames=try c.decode(Int.self,forKey:.animationOffsetFrames)}
}
/// A single fixed image character. Every visible pose is an actual registered
/// sprite, not a code-drawn face. The master role identifies its neutral source
/// frame; source provenance/rights remain on the Host's ClassicArtwork.
public struct CartoonPresenter:Codable,Equatable,Sendable {
    public var version=1;public var id:String;public var masterRole:String
    public var x:Double;public var y:Double;public var width:Double;public var height:Double
    public var clips:[CartoonPresenterClip];public var cues:[CartoonPresenterCue];public var speech:CartoonSpeechTrack?
    public init(id:String,masterRole:String,x:Double,y:Double,width:Double,height:Double,clips:[CartoonPresenterClip],cues:[CartoonPresenterCue],speech:CartoonSpeechTrack?=nil){self.id=id;self.masterRole=masterRole;self.x=x;self.y=y;self.width=width;self.height=height;self.clips=clips;self.cues=cues;self.speech=speech}
    private enum CodingKeys:String,CodingKey {case version,id,masterRole,x,y,width,height,clips,cues,speech}
    public init(from decoder:Decoder)throws {
        try PresenterDecoding.keys(decoder,["version","id","masterRole","x","y","width","height","clips","cues"],optional:["speech"])
        let c=try decoder.container(keyedBy:CodingKeys.self);version=try c.decode(Int.self,forKey:.version);id=try c.decode(String.self,forKey:.id);masterRole=try c.decode(String.self,forKey:.masterRole)
        x=try c.decode(Double.self,forKey:.x);y=try c.decode(Double.self,forKey:.y);width=try c.decode(Double.self,forKey:.width);height=try c.decode(Double.self,forKey:.height)
        clips=try c.decode([CartoonPresenterClip].self,forKey:.clips);cues=try c.decode([CartoonPresenterCue].self,forKey:.cues);speech=try c.decodeIfPresent(CartoonSpeechTrack.self,forKey:.speech)
    }
    public var roles:Set<String>{Set([masterRole]+clips.flatMap{$0.frames.map(\.role)})}
    /// The presenter is an image overlay, not a business resource or a second
    /// bubble renderer. A pose is selected only through the real clip frames.
    public func validateActions(_ actions:[StoryAction]) throws {
        for action in actions where action.subjectID==id {
            guard [.move,.show,.hide].contains(action.kind),action.quantity==nil,action.targetID==nil else {throw VideoError.invalid("图片解说员仅接受位置和显隐动作；表情手势请引用真实序列，不能忽略气泡或资源交付")}
            for point in [action.from,action.to].compactMap({$0}) {
                guard point.x-width/2>=0,point.x+width/2<=1,point.y-height/2>=0,point.y+height/2<=1 else {throw VideoError.invalid("图片解说员移动后仍须完整位于画面内")}
            }
        }
    }
    public func validate(durationFrames:Int,sprites:[ClassicSprite],imageHashes:[String:String]=[:],voiceBinding:CartoonSpeechBinding?) throws {
        guard version==1,StoryActionRules.identifier(id),(1...54000).contains(durationFrames),
              [x,y,width,height].allSatisfy(\.isFinite),width>=0.05,height>=0.05,width<=1,height<=1,
              x-width/2>=0,x+width/2<=1,y-height/2>=0,y+height/2<=1,
              (1...16).contains(clips.count),Set(clips.map(\.id)).count==clips.count,
              (1...256).contains(cues.count),clips.reduce(0,{$0+$1.frames.count})<=256,
              Set(sprites.map(\.role)).count==sprites.count,roles.isSubset(of:Set(sprites.map(\.role))) else {throw VideoError.invalid("图片解说员的版本、固定主体、完整画框或真实序列帧缺失")}
        for clip in clips {
            guard StoryActionRules.identifier(clip.id),(1...30).contains(clip.frameDurationFrames),(3...32).contains(clip.frames.count),
                  Set(clip.frames.map(\.role)).count==clip.frames.count,
                  clip.frames.allSatisfy({PluginProtocolRules.text($0.role,maximum:128) && $0.mouthOpen.isFinite && (0...1).contains($0.mouthOpen)}),
                  clip.frames.contains(where:{$0.mouthOpen==0}),Set(clip.frames.map(\.mouthOpen)).count>=3 else {throw VideoError.invalid("图片表演须有真实不同帧、闭口与多个开口级别及有限节奏")}
            var regions=Set<String>()
            for frame in clip.frames {
                guard let sprite=sprites.first(where:{$0.role==frame.role}),[sprite.x,sprite.y,sprite.width,sprite.height].allSatisfy(\.isFinite),
                      sprite.x>=0,sprite.y>=0,sprite.width>0,sprite.height>0,sprite.x+sprite.width<=1.000001,sprite.y+sprite.height<=1.000001 else {throw VideoError.invalid("图片表演帧超出真实源图区域")}
                let source=imageHashes[sprite.assetID] ?? sprite.assetID
                let region="\(source)/\(sprite.x)/\(sprite.y)/\(sprite.width)/\(sprite.height)"
                guard regions.insert(region).inserted else {throw VideoError.invalid("不同序列帧不能重名引用同一实际图块")}
            }
        }
        var end=0
        for cue in cues {
            guard cue.startFrame>=end,cue.endFrame>cue.startFrame,cue.endFrame<=durationFrames,
                  (0...216000).contains(cue.animationOffsetFrames),clips.contains(where:{$0.id==cue.clipID}) else {throw VideoError.invalid("图片解说员片段不可重叠、越界或引用未知动作；空窗口保持不出场")}
            end=cue.endFrame
        }
        if let speech {
            guard speech.actorID==id,speech.durationFrames==durationFrames else {throw VideoError.review("图片口型须绑定本主体与完整当前源音轴，不能裁段冒完整原音")}
            try speech.validate(sceneFrames:durationFrames,actorIDs:[id],voiceBinding:voiceBinding)
        } else {guard voiceBinding==nil else {throw VideoError.review("图片解说员缺少当前原音能量轨，未编造口型")}}
    }
    /// RMS selects real authored mouth shapes. Source time only chooses among
    /// equivalent openness frames; it cannot make a silent character talk.
    public func role(at frame:Int,durationFrames:Int,speechFrame:Int?=nil)->String? {
        guard (0..<durationFrames).contains(frame),let cue=cues.first(where:{$0.startFrame<=frame && frame<$0.endFrame}),
              let clip=clips.first(where:{$0.id==cue.clipID}) else {return nil}
        let openness=speech?.mouthOpenness(frame:speechFrame ?? frame) ?? 0
        if openness<=0.015 {return clip.frames.first(where:{$0.mouthOpen==0})?.role}
        let spoken=clip.frames.filter{$0.mouthOpen>0}
        guard let distance=spoken.map({abs($0.mouthOpen-openness)}).min() else {return nil}
        let candidates=spoken.filter{abs($0.mouthOpen-openness)<=distance+0.025}
        guard !candidates.isEmpty else {return nil}
        let offset=cue.animationOffsetFrames+frame-cue.startFrame
        return candidates[(offset/max(1,clip.frameDurationFrames))%candidates.count].role
    }
}

private enum PresenterDecoding {
    struct Key:CodingKey {var stringValue:String;var intValue:Int?;init?(stringValue:String){self.stringValue=stringValue};init?(intValue:Int){return nil}}
    static func keys(_ decoder:Decoder,_ required:Set<String>,optional:Set<String> = []) throws {
        let c=try decoder.container(keyedBy:Key.self),actual=Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of:actual),actual.isSubset(of:required.union(optional)) else {throw VideoError.invalid("图片解说员协议缺少必填字段或含未知字段")}
    }
}

public enum CartoonPresenterSchema {
    public static let records:[String:String]=[
        "CartoonPresenterFrame":"role:s mouthOpen:n",
        "CartoonPresenterClip":"id:s frameDurationFrames:i frames:[CartoonPresenterFrame]",
        "CartoonPresenterCue":"startFrame:i endFrame:i clipID:s animationOffsetFrames:i",
        "CartoonPresenter":"version:i id:s masterRole:s x:n y:n width:n height:n clips:[CartoonPresenterClip] cues:[CartoonPresenterCue] speech?:CartoonSpeechTrack"
    ]
}
