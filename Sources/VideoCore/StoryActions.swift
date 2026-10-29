import Foundation

/// Authored process coordinates use the visible stage, normalized from its top-left.
public struct StoryPoint: Codable, Equatable, Sendable {
    public var x: Double; public var y: Double
    public init(x: Double, y: Double) { self.x=x; self.y=y }
    public func validate() throws {
        guard x.isFinite,y.isFinite,(0...1).contains(x),(0...1).contains(y) else { throw VideoError.invalid("故事动作坐标须位于归一化舞台内") }
    }
}
public enum StoryActionKind: String, Codable, CaseIterable, Sendable { case move, transfer, build, show, hide, speak }
public struct StoryAction: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var kind: StoryActionKind; public var subjectID: String; public var targetID: String?
    public var startFrame: Int; public var endFrame: Int; public var from: StoryPoint?; public var to: StoryPoint?
    public var quantity: Int?; public var text: String?
    public init(id:String=Codec.id(),kind:StoryActionKind,subjectID:String,targetID:String?=nil,startFrame:Int,endFrame:Int,from:StoryPoint?=nil,to:StoryPoint?=nil,quantity:Int?=nil,text:String?=nil) {
        self.id=id;self.kind=kind;self.subjectID=subjectID;self.targetID=targetID;self.startFrame=startFrame;self.endFrame=endFrame;self.from=from;self.to=to;self.quantity=quantity;self.text=text
    }
}
public struct StoryActionState: Equatable, Sendable {
    public var position: StoryPoint?; public var progress: Double; public var opacity: Double
    public var bubbleText: String?; public var quantity: Int?
    public init(position:StoryPoint?=nil,progress:Double=1,opacity:Double=1,bubbleText:String?=nil,quantity:Int?=nil) {
        self.position=position;self.progress=progress;self.opacity=opacity;self.bubbleText=bubbleText;self.quantity=quantity
    }
}
public enum StoryActionRules {
    public static func identifier(_ value:String)->Bool { value.range(of:"^[A-Za-z0-9._-]{1,80}$",options:.regularExpression) != nil }
    public static func validate(_ actions:[StoryAction],durationFrames:Int,subjectIDs:Set<String>) throws {
        guard (1...54000).contains(durationFrames),actions.count<=256,Set(actions.map(\.id)).count==actions.count else { throw VideoError.invalid("故事动作数量、重复标识或镜头时长无效") }
        for action in actions {
            guard identifier(action.id),subjectIDs.contains(action.subjectID),action.targetID.map({subjectIDs.contains($0) && $0 != action.subjectID}) ?? true,
                  action.startFrame>=0,action.endFrame>action.startFrame,action.endFrame<=durationFrames,
                  action.quantity.map({(1...9999).contains($0)}) ?? true else { throw VideoError.invalid("故事动作须绑定实际对象、有效源帧和有界数量") }
            try action.from?.validate();try action.to?.validate()
            if [.move,.transfer].contains(action.kind) {
                guard action.from != nil,action.to != nil,action.text==nil else { throw VideoError.invalid("移动或交付须给出完整起止位置，不能隐藏气泡文字") }
                guard action.kind != .transfer || action.targetID != nil else {throw VideoError.invalid("交付过程须明确另一个实际接收对象")}
            } else { guard action.from==nil,action.to==nil else { throw VideoError.invalid("非移动故事动作不接受隐藏位置") } }
            if action.kind == .speak {
                guard let text=action.text,PluginProtocolRules.text(text,maximum:192),text.count<=48,action.quantity==nil else { throw VideoError.invalid("原生气泡须有1—48字实际台词，不能夹带数量") }
            } else { guard action.text==nil else { throw VideoError.invalid("只有说话动作可携带气泡文字") } }
        }
        for subject in Set(actions.map(\.subjectID)) {
            for group in [actions.filter{$0.subjectID==subject && [.move,.transfer].contains($0.kind)},actions.filter{$0.subjectID==subject && [.build,.show,.hide].contains($0.kind)},actions.filter{$0.subjectID==subject && $0.kind == .speak}] {
                let ordered=group.sorted{$0.startFrame<$1.startFrame}
                for index in ordered.indices.dropFirst() where ordered[index].startFrame<ordered[index-1].endFrame { throw VideoError.invalid("同一对象的同类故事动作时间窗不能重叠") }
            }
        }
    }
    /// Completed moves/builds remain in their authored final state; speech never lingers.
    public static func presentation(subjectID:String,actions:[StoryAction],frame:Int)->StoryActionState {
        let ordered=actions.filter{$0.subjectID==subjectID}.sorted { $0.startFrame == $1.startFrame ? $0.id<$1.id:$0.startFrame<$1.startFrame }
        var state=StoryActionState()
        if let first=ordered.first(where:{[.build,.show,.hide].contains($0.kind)}),frame<first.startFrame,[.build,.show].contains(first.kind) { state.opacity=0;state.progress=0 }
        for action in ordered where frame>=action.startFrame {
            let p=min(1,max(0,Double(frame-action.startFrame)/Double(max(1,action.endFrame-action.startFrame-1))))
            switch action.kind {
            case .move,.transfer:
                if let a=action.from,let b=action.to { state.position=p>=1 ? b:StoryPoint(x:a.x+(b.x-a.x)*p,y:a.y+(b.y-a.y)*p) }
                state.quantity=action.quantity
            case .build:state.progress=p;state.opacity=p>0 ? 1:0
            case .show:state.opacity=p;state.progress=1
            case .hide:state.opacity=1-p;state.progress=1
            case .speak:if frame<action.endFrame {state.bubbleText=action.text}
            }
        }
        return state
    }
}

public struct GameWorldEntity: Codable, Equatable, Identifiable, Sendable {
    public var id:String;public var name:String;public var role:String;public var x:Double;public var y:Double
    public var scale:Double;public var value:Int?;public var visible:Bool
    public init(id:String,name:String,role:String,x:Double,y:Double,scale:Double=1,value:Int?=nil,visible:Bool=true) {self.id=id;self.name=name;self.role=role;self.x=x;self.y=y;self.scale=scale;self.value=value;self.visible=visible}
}
public struct GameWorldUpdate: Codable, Equatable, Sendable {
    public var frame:Int;public var entityID:String;public var x:Double?;public var y:Double?;public var role:String?;public var value:Int?;public var visible:Bool?
    public init(frame:Int,entityID:String,x:Double?=nil,y:Double?=nil,role:String?=nil,value:Int?=nil,visible:Bool?=nil) {self.frame=frame;self.entityID=entityID;self.x=x;self.y=y;self.role=role;self.value=value;self.visible=visible}
}
public struct GameWorld: Codable, Equatable, Sendable {
    public var version=1;public var width:Int;public var height:Int;public var tiles:[String];public var entities:[GameWorldEntity];public var updates:[GameWorldUpdate]
    public init(width:Int,height:Int,tiles:[String],entities:[GameWorldEntity],updates:[GameWorldUpdate]=[]) {self.width=width;self.height=height;self.tiles=tiles;self.entities=entities;self.updates=updates}
    public func validate(durationFrames:Int,availableRoles:Set<String>?=nil) throws {
        guard version==1,(1...64).contains(width),(1...64).contains(height),tiles.count==width*height,
              (1...64).contains(entities.count),updates.count<=2048,(1...54000).contains(durationFrames),Set(entities.map(\.id)).count==entities.count else {throw VideoError.invalid("动态游戏地图版本、完整网格、实体或更新数量无效")}
        let ids=Set(entities.map(\.id))
        func role(_ value:String)->Bool {PluginProtocolRules.text(value,maximum:128) && (availableRoles?.contains(value) ?? true)}
        func point(_ x:Double,_ y:Double)->Bool {x.isFinite && y.isFinite && (0...Double(width-1)).contains(x) && (0...Double(height-1)).contains(y)}
        guard tiles.allSatisfy(role) else {throw VideoError.invalid("地图图块须引用实际图集角色")}
        for entity in entities {
            guard StoryActionRules.identifier(entity.id),PluginProtocolRules.text(entity.name,maximum:192),entity.name.count<=48,role(entity.role),point(entity.x,entity.y),entity.scale.isFinite,(0.25...4).contains(entity.scale),entity.value.map({(0...999999).contains($0)}) ?? true else {throw VideoError.invalid("游戏实体身份、名称、位置、图块或账目无效")}
        }
        var keys=Set<String>()
        for update in updates {
            guard ids.contains(update.entityID),(0..<durationFrames).contains(update.frame),keys.insert(update.entityID+"/"+String(update.frame)).inserted,
                  (update.x==nil)==(update.y==nil),update.x.map({point($0,update.y!)}) ?? true,update.role.map(role) ?? true,
                  update.value.map({(0...999999).contains($0)}) ?? true,
                  update.x != nil || update.role != nil || update.value != nil || update.visible != nil else {throw VideoError.invalid("游戏状态更新须绑定实际实体、唯一源帧与合法变更")}
        }
    }
    public func frameState(frame:Int,durationFrames:Int) throws -> [GameWorldEntity] {
        try validate(durationFrames:durationFrames)
        let current=min(max(0,frame),durationFrames-1)
        var result=entities
        for update in updates.sorted(by:{$0.frame<$1.frame}) where update.frame<=current {
            guard let index=result.firstIndex(where:{$0.id==update.entityID}) else {continue}
            if let x=update.x,let y=update.y {result[index].x=x;result[index].y=y}
            if let role=update.role {result[index].role=role}
            if let value=update.value {result[index].value=value}
            if let visible=update.visible {result[index].visible=visible}
        }
        return result
    }
}

public enum CartoonRigExpression:String,Codable,CaseIterable,Sendable {case neutral,happy,thinking,surprised,worried}
public enum CartoonRigGesture:String,Codable,CaseIterable,Sendable {case idle,point,offer,withdraw,celebrate}
public struct CartoonRigActor:Codable,Equatable,Identifiable,Sendable {
    public var id:String;public var name:String;public var color:String;public var x:Double;public var y:Double;public var scale:Double;public var mirrored:Bool
    public init(id:String,name:String,color:String="70C9CF",x:Double,y:Double,scale:Double=1,mirrored:Bool=false) {self.id=id;self.name=name;self.color=color;self.x=x;self.y=y;self.scale=scale;self.mirrored=mirrored}
}
public struct CartoonRigCue:Codable,Equatable,Sendable {
    public var actorID:String;public var startFrame:Int;public var endFrame:Int;public var expression:CartoonRigExpression;public var gesture:CartoonRigGesture
    public init(actorID:String,startFrame:Int,endFrame:Int,expression:CartoonRigExpression = .neutral,gesture:CartoonRigGesture = .idle) {self.actorID=actorID;self.startFrame=startFrame;self.endFrame=endFrame;self.expression=expression;self.gesture=gesture}
}
public struct SpeechEnergyCue:Codable,Equatable,Sendable {
    public var startFrame:Int;public var endFrame:Int;public var rms:Double
    public init(startFrame:Int,endFrame:Int,rms:Double) {self.startFrame=startFrame;self.endFrame=endFrame;self.rms=rms}
}
public struct CartoonSpeechBinding:Codable,Equatable,Sendable {
    public var voiceAssetID:String;public var sourceSHA256:String;public var textDigest:String;public var durationFrames:Int
    public init(voiceAssetID:String,sourceSHA256:String,textDigest:String,durationFrames:Int) {self.voiceAssetID=voiceAssetID;self.sourceSHA256=sourceSHA256;self.textDigest=textDigest;self.durationFrames=durationFrames}
    public static func from(scene:Scene,assets:[Asset]) throws -> CartoonSpeechBinding? {
        guard scene.cartoonRig?.speech != nil else {return nil}
        guard let voice=scene.voice,let asset=assets.first(where:{$0.id==voice.assetID}),asset.mediaType.hasPrefix("audio"),asset.durationFrames==voice.durationFrames,voice.textDigest == (try scene.speechDigest()),PluginProtocolRules.hash(asset.hash) else {throw VideoError.review("口型必须绑定当前完整原音、实际摘要、台词与时长")}
        return Self(voiceAssetID:voice.assetID,sourceSHA256:asset.hash,textDigest:voice.textDigest,durationFrames:voice.durationFrames)
    }
}
public struct CartoonSpeechTrack:Codable,Equatable,Sendable {
    public var actorID:String;public var voiceAssetID:String;public var sourceSHA256:String;public var textDigest:String;public var durationFrames:Int;public var energy:[SpeechEnergyCue]
    public init(actorID:String,voiceAssetID:String,sourceSHA256:String,textDigest:String,durationFrames:Int,energy:[SpeechEnergyCue]) {self.actorID=actorID;self.voiceAssetID=voiceAssetID;self.sourceSHA256=sourceSHA256;self.textDigest=textDigest;self.durationFrames=durationFrames;self.energy=energy}
    public var binding:CartoonSpeechBinding {CartoonSpeechBinding(voiceAssetID:voiceAssetID,sourceSHA256:sourceSHA256,textDigest:textDigest,durationFrames:durationFrames)}
    public func validate(sceneFrames:Int,actorIDs:Set<String>,voiceBinding:CartoonSpeechBinding?) throws {
        guard (1...54000).contains(sceneFrames),actorIDs.contains(actorID),StoryActionRules.identifier(voiceAssetID),PluginProtocolRules.hash(sourceSHA256),PluginProtocolRules.hash(textDigest),durationFrames>=1,durationFrames<=sceneFrames,!energy.isEmpty,energy.count<=4096,binding==voiceBinding else {throw VideoError.review("能量口型与实际原音、台词、演员或时长不符；请按当前原音重新分析")}
        var end=0
        for cue in energy {
            guard cue.startFrame==end,cue.endFrame>cue.startFrame,cue.endFrame<=durationFrames,cue.rms.isFinite,(0...1).contains(cue.rms) else {throw VideoError.invalid("原音RMS片段须连续完整覆盖take，不能随机口型或留下空洞")}
            end=cue.endFrame
        }
        guard end==durationFrames else {throw VideoError.invalid("原音能量口型未完整覆盖实际take")}
    }
    /// Actual decoded RMS drives openness; silence is closed. This is not phoneme recognition.
    public func mouthOpenness(frame:Int)->Double {
        guard let cue=energy.first(where:{$0.startFrame<=frame && frame<$0.endFrame}),cue.rms>0.008 else {return 0}
        return min(1,max(0,(sqrt(cue.rms)-sqrt(0.008))/(sqrt(0.18)-sqrt(0.008))))
    }
}
public struct CartoonRigActorFrame:Equatable,Sendable {
    public var actor:CartoonRigActor;public var expression:CartoonRigExpression;public var gesture:CartoonRigGesture;public var gestureProgress:Double;public var mouthOpenness:Double
}
public struct CartoonRig:Codable,Equatable,Sendable {
    public var version=1;public var actors:[CartoonRigActor];public var cues:[CartoonRigCue];public var speech:CartoonSpeechTrack?
    public init(version:Int=1,actors:[CartoonRigActor],cues:[CartoonRigCue]=[],speech:CartoonSpeechTrack?=nil) {self.version=version;self.actors=actors;self.cues=cues;self.speech=speech}
    public func validate(durationFrames:Int,voiceBinding:CartoonSpeechBinding?) throws {
        let ids=Set(actors.map(\.id))
        guard [1,2].contains(version),(1...54000).contains(durationFrames),(1...(version==1 ? 4:8)).contains(actors.count),ids.count==actors.count,cues.count<=256 else {throw VideoError.invalid("原生卡通rig版本、演员或动作数量无效；v1最多4人，显式v2最多8人")}
        for actor in actors {try StoryPoint(x:actor.x,y:actor.y).validate();guard StoryActionRules.identifier(actor.id),PluginProtocolRules.text(actor.name,maximum:192),actor.name.count<=48,actor.color.range(of:"^[a-fA-F0-9]{6}$",options:.regularExpression) != nil,actor.scale.isFinite,(0.25...2).contains(actor.scale) else {throw VideoError.invalid("原生卡通演员身份、颜色或尺度无效")}}
        for cue in cues {guard ids.contains(cue.actorID),cue.startFrame>=0,cue.endFrame>cue.startFrame,cue.endFrame<=durationFrames else {throw VideoError.invalid("卡通表情和肢体动作超出实际演员或源帧")}}
        for id in ids {let ordered=cues.filter{$0.actorID==id}.sorted{$0.startFrame<$1.startFrame};for i in ordered.indices.dropFirst() where ordered[i].startFrame<ordered[i-1].endFrame {throw VideoError.invalid("同一演员的rig动作不能重叠")}}
        try speech?.validate(sceneFrames:durationFrames,actorIDs:ids,voiceBinding:voiceBinding)
    }
    public func frameState(frame:Int,durationFrames:Int) -> [CartoonRigActorFrame] {
        guard (1...54000).contains(durationFrames) else {return []}
        let frame=min(max(frame,0),max(0,durationFrames-1))
        return actors.map {actor in
            let cue=cues.first{$0.actorID==actor.id && $0.startFrame<=frame && frame<$0.endFrame}
            let progress=cue.map{min(1,Double(frame-$0.startFrame)/Double(max(1,$0.endFrame-$0.startFrame-1)))} ?? 0
            return CartoonRigActorFrame(actor:actor,expression:cue?.expression ?? .neutral,gesture:cue?.gesture ?? .idle,gestureProgress:progress,mouthOpenness:speech?.actorID==actor.id ? speech?.mouthOpenness(frame:frame) ?? 0:0)
        }
    }
}
public enum StorySceneRules {
    public static func validate(scene:Scene,assets:[Asset]) throws {
        var subjects=Set((scene.layers ?? []).map(\.id))
        if let world=scene.gameWorld {
            guard scene.kind == .simulation,scene.cartoonRig==nil,let artwork=scene.classicArtwork else {throw VideoError.invalid("游戏世界须绑定仿真镜头及实际图集")}
            try world.validate(durationFrames:scene.durationFrames,availableRoles:Set(artwork.sprites.map(\.role)))
            guard subjects.isDisjoint(with:Set(world.entities.map(\.id))) else {throw VideoError.invalid("游戏实体与舞台对象标识不能冲突")}
            subjects.formUnion(world.entities.map(\.id))
        }
        if let rig=scene.cartoonRig {
            guard scene.kind == .cartoon,scene.gameWorld==nil,scene.cartoonPerformance==nil,scene.classicArtwork==nil,scene.classicArtworkRequired==false else {throw VideoError.invalid("原创代码rig须显式使用卡通镜头，不能冒外部图集角色")}
            let binding=try CartoonSpeechBinding.from(scene:scene,assets:assets)
            guard scene.voice==nil || rig.speech != nil else {throw VideoError.review("有声原生卡通须先按当前原音提供能量口型")}
            try rig.validate(durationFrames:scene.durationFrames,voiceBinding:binding)
            guard subjects.isDisjoint(with:Set(rig.actors.map(\.id))) else {throw VideoError.invalid("卡通演员与舞台对象标识不能冲突")}
            subjects.formUnion(rig.actors.map(\.id))
        }
        if let actions=scene.storyActions {try StoryActionRules.validate(actions,durationFrames:scene.durationFrames,subjectIDs:subjects)}
    }
}

public enum StoryActionSchema {
    public static let records:[String:String]=[
        "StoryPoint":"x:n y:n",
        "StoryAction":"id:s kind:StoryActionKind subjectID:s targetID?:s startFrame:i endFrame:i from?:StoryPoint to?:StoryPoint quantity?:i text?:s",
        "GameWorld":"version:i width:i height:i tiles:[s] entities:[GameWorldEntity] updates:[GameWorldUpdate]",
        "GameWorldEntity":"id:s name:s role:s x:n y:n scale:n value?:i visible:b",
        "GameWorldUpdate":"frame:i entityID:s x?:n y?:n role?:s value?:i visible?:b",
        "CartoonRigActor":"id:s name:s color:s x:n y:n scale:n mirrored:b",
        "CartoonRigCue":"actorID:s startFrame:i endFrame:i expression:CartoonRigExpression gesture:CartoonRigGesture",
        "SpeechEnergyCue":"startFrame:i endFrame:i rms:n",
        "CartoonSpeechBinding":"voiceAssetID:s sourceSHA256:s textDigest:s durationFrames:i",
        "CartoonSpeechTrack":"actorID:s voiceAssetID:s sourceSHA256:s textDigest:s durationFrames:i energy:[SpeechEnergyCue]",
        "CartoonRig":"version:i actors:[CartoonRigActor] cues:[CartoonRigCue] speech?:CartoonSpeechTrack"
    ]
    public static let enums:[String:[String]]=["StoryActionKind":StoryActionKind.allCases.map(\.rawValue),"CartoonRigExpression":CartoonRigExpression.allCases.map(\.rawValue),"CartoonRigGesture":CartoonRigGesture.allCases.map(\.rawValue)]
}
