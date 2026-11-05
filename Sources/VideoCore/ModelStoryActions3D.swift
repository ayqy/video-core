import Foundation

/// Operations on original native instances. Movement and poses reference the
/// model's actual sampled tracks; no substitute 2D objects or rule traces are
/// sent to a rendering plugin.
public enum ModelStoryActionKind3D: String, Codable, CaseIterable, Sendable { case move,pose,show,hide,speak }
public struct ModelStoryAction3D: Codable, Equatable, Identifiable, Sendable {
    public var id:String;public var kind:ModelStoryActionKind3D;public var instanceID:String
    /// Half-open windows on the complete model source-frame axis.
    public var startFrame:Int;public var endFrame:Int;public var requires:[String]
    /// Pose operations name actual original DAE joints, with changing tracks.
    public var jointNames:[String]?
    /// Speech anchors use instance-local, Y-up source units before the original
    /// instance transform. The native renderer projects them each source frame.
    public var anchor:ModelVector3?;public var text:String?
    public init(id:String,kind:ModelStoryActionKind3D,instanceID:String,startFrame:Int,endFrame:Int,requires:[String]=[],jointNames:[String]?=nil,anchor:ModelVector3?=nil,text:String?=nil) {
        self.id=id;self.kind=kind;self.instanceID=instanceID;self.startFrame=startFrame;self.endFrame=endFrame;self.requires=requires;self.jointNames=jointNames;self.anchor=anchor;self.text=text
    }
    private enum CodingKeys:String,CodingKey {case id,kind,instanceID,startFrame,endFrame,requires,jointNames,anchor,text}
    public init(from decoder:Decoder)throws {
        try ModelStoryDecoding3D.keys(decoder,required:["id","kind","instanceID","startFrame","endFrame","requires"],optional:["jointNames","anchor","text"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id);kind=try c.decode(ModelStoryActionKind3D.self,forKey:.kind);instanceID=try c.decode(String.self,forKey:.instanceID)
        startFrame=try c.decode(Int.self,forKey:.startFrame);endFrame=try c.decode(Int.self,forKey:.endFrame);requires=try c.decode([String].self,forKey:.requires)
        for key in [CodingKeys.jointNames,.anchor,.text] where c.contains(key) {
            guard !(try c.decodeNil(forKey:key)) else {throw VideoError.invalid("三维原生动作的可选字段不能用null隐藏")}
        }
        jointNames=try c.decodeIfPresent([String].self,forKey:.jointNames);text=try c.decodeIfPresent(String.self,forKey:.text)
        if c.contains(.anchor) {
            try ModelStoryDecoding3D.keys(c.superDecoder(forKey:.anchor),required:["x","y","z"])
            anchor=try c.decode(ModelVector3.self,forKey:.anchor)
        } else {anchor=nil}
        try validateFields()
    }
    func validateFields()throws {
        switch kind {
        case .pose:
            guard let names=jointNames,(1...64).contains(names.count),Set(names).count==names.count,anchor==nil,text==nil else {throw VideoError.invalid("三维pose须明确1至64个不重复的原骨关节，不能携带气泡字段")}
        case .speak:
            guard jointNames==nil,let anchor,[anchor.x,anchor.y,anchor.z].allSatisfy({$0.isFinite && abs($0)<=1_000_000}),let text,PluginProtocolRules.text(text,maximum:192),text.count<=48 else {throw VideoError.invalid("三维发言须绑定实际实例局部锚点和1至48字台词")}
        case .move,.show,.hide:
            guard jointNames==nil,anchor==nil,text==nil else {throw VideoError.invalid("三维移动或显隐不接受隐藏骨骼、锚点或台词字段")}
        }
    }
}
public struct ModelStoryActionState3D:Equatable,Sendable {
    public var opacity:Double;public var speech:ModelStoryAction3D?
    public init(opacity:Double=1,speech:ModelStoryAction3D?=nil) {self.opacity=opacity;self.speech=speech}
}
public enum ModelStoryActionRules3D {
    /// Validate the complete source contract, not an unrelated list of claims.
    public static func validate(_ actions:[ModelStoryAction3D],model:ModelScene3D,durationFrames:Int)throws {
        guard model.version==2,model.actions==actions else {throw VideoError.invalid("三维原生动作须属于当前显式v2模型")}
        try model.validate(durationFrames:durationFrames)
    }
    /// ModelScene3D calls this only after validating all actual source tracks,
    /// resources, unique targets and joint identities. Keep it separate from
    /// the public entry so source sampling cannot recursively validate itself.
    static func validateVerifiedModel(_ actions:[ModelStoryAction3D],model:ModelScene3D,durationFrames:Int)throws {
        guard model.version==2,(1...256).contains(actions.count),Set(actions.map(\.id)).count==actions.count else {throw VideoError.invalid("三维原生动作数量、版本或重复标识无效")}
        let byID=Dictionary(uniqueKeysWithValues:actions.map{($0.id,$0)})
        for action in actions {
            guard StoryActionRules.identifier(action.id),let instance=model.instances.first(where:{$0.id==action.instanceID}),
                  action.startFrame>=0,action.endFrame>action.startFrame,action.endFrame<=durationFrames,
                  action.requires.count<=32,Set(action.requires).count==action.requires.count else {throw VideoError.invalid("三维原生动作须引用实际实例、完整源帧窗和不重复的有界前置")}
            try action.validateFields()
            for required in action.requires {
                guard StoryActionRules.identifier(required),required != action.id,let previous=byID[required],previous.endFrame<=action.startFrame else {throw VideoError.invalid("三维动作前置须真实存在且已经完成，不能引用自身、未来或循环")}
            }
            switch action.kind {
            case .move:
                guard action.endFrame-action.startFrame>=2,let track=model.transformTracks.first(where:{$0.instanceID==instance.id}),
                      changes(keys:track.keyframes,fallback:instance.transform,action:action,translationOnly:true) else {throw VideoError.invalid("三维move须在声明源帧窗内发生实际实例平移；静止、仅旋转或未绑定轨道不能认领移动")}
            case .pose:
                guard action.endFrame-action.startFrame>=2,let names=action.jointNames,names.allSatisfy({name in
                    guard instance.resource.inspection.jointNames.contains(name),let track=model.jointTracks.first(where:{$0.instanceID==instance.id && $0.jointName==name}) else {return false}
                    return changes(keys:track.keyframes,fallback:.init(),action:action,translationOnly:false)
                }) else {throw VideoError.invalid("三维pose须在声明源帧窗内改变每个指定的实际原骨轨道，不能以自造关节或恒定姿态冒动作")}
            case .show,.hide,.speak:break
            }
        }
        for instance in model.instances {
            let own=actions.filter{$0.instanceID==instance.id}
            for group in [own.filter{$0.kind == .move},own.filter{$0.kind == .show || $0.kind == .hide},own.filter{$0.kind == .speak}] {
                let rows=group.sorted{($0.startFrame,$0.id)<($1.startFrame,$1.id)}
                for index in rows.indices.dropFirst() {
                    guard rows[index].startFrame>=rows[index-1].endFrame else {throw VideoError.invalid("同一三维实例的移动、显隐或发言不能同类重叠")}
                    if rows[index].kind == .show || rows[index].kind == .hide {
                        guard rows[index].kind != rows[index-1].kind else {throw VideoError.invalid("三维显隐动作须实际改变前一状态，不能重复认领同一次显隐")}
                    }
                }
            }
            // Two independently labelled poses must not claim the same native
            // joint over overlapping windows. Disjoint joints may move together.
            let poses=own.filter{$0.kind == .pose}
            for index in poses.indices {
                for other in poses.indices where other>index {
                    if poses[index].startFrame<poses[other].endFrame && poses[other].startFrame<poses[index].endFrame {
                        guard Set(poses[index].jointNames ?? []).isDisjoint(with:Set(poses[other].jointNames ?? [])) else {throw VideoError.invalid("同一原骨关节不能被重叠的三维pose重复认领")}
                    }
                }
            }
            // A native speech may not be assigned to an invisible speaker at
            // any part of its declared window. Visibility changes are finite.
            for speech in own where speech.kind == .speak {
                var frames:Set<Int>=[speech.startFrame,speech.endFrame-1]
                for change in own where change.kind == .show || change.kind == .hide {
                    if speech.startFrame<=change.startFrame && change.startFrame<speech.endFrame {frames.insert(change.startFrame)}
                }
                guard frames.allSatisfy({presentation(instanceID:instance.id,actions:actions,frame:$0).opacity==1}) else {throw VideoError.invalid("三维发言的完整时间窗内说话者必须可见")}
            }
        }
        // A later label cannot claim that an animation started later than the
        // real original track. Every changing interval must be covered by an
        // actual operation on that same instance/joint. Work on finite key
        // segments and operation windows, never scan or store every frame.
        for track in model.transformTracks {
            try requireCoverage(keys:track.keyframes,windows:actions.filter{$0.instanceID==track.instanceID && $0.kind == .move})
        }
        for track in model.jointTracks {
            try requireCoverage(keys:track.keyframes,windows:actions.filter{$0.instanceID==track.instanceID && $0.kind == .pose && ($0.jointNames?.contains(track.jointName) ?? false)})
        }
    }
    /// Random-access source-frame evaluation. Visibility starts from the same
    /// authored default on every call. Show/hide are explicit step changes,
    /// not undeclared fades; an active speech never survives its own window.
    public static func presentation(instanceID:String,actions:[ModelStoryAction3D],frame:Int)->ModelStoryActionState3D {
        let own=actions.filter{$0.instanceID==instanceID}.sorted{($0.startFrame,$0.id)<($1.startFrame,$1.id)}
        var result=ModelStoryActionState3D()
        if own.first(where:{$0.kind == .show || $0.kind == .hide})?.kind == .show {result.opacity=0}
        for action in own where action.startFrame<=frame {
            switch action.kind {
            case .show:result.opacity=1
            case .hide:result.opacity=0
            case .speak:if frame<action.endFrame {result.speech=action}
            case .move,.pose:break
            }
        }
        if result.opacity==0 {result.speech=nil}
        return result
    }
    private static func changes(keys:[ModelTransformKeyframe],fallback:ModelTransform3D,action:ModelStoryAction3D,translationOnly:Bool)->Bool {
        let first=ModelScene3D.sample(keys:keys,fallback:fallback,sourceFrame:action.startFrame)
        let frames=Set([action.endFrame-1]+keys.filter{action.startFrame<$0.frame && $0.frame<action.endFrame}.map(\.frame))
        return frames.contains {frame in
            let value=ModelScene3D.sample(keys:keys,fallback:fallback,sourceFrame:frame)
            return differs(first,value,translationOnly:translationOnly)
        }
    }
    private static func differs(_ first:ModelTransform3D,_ value:ModelTransform3D,translationOnly:Bool=false)->Bool {
        func vector(_ a:ModelVector3,_ b:ModelVector3)->Bool {abs(a.x-b.x)>0.000000001 || abs(a.y-b.y)>0.000000001 || abs(a.z-b.z)>0.000000001}
        if vector(first.translation,value.translation) {return true}
        if translationOnly {return false}
        let a=first.rotation,b=value.rotation,dot=a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w
        return vector(first.scale,value.scale) || 1-abs(dot)>0.000000001
    }
    private static func requireCoverage(keys:[ModelTransformKeyframe],windows:[ModelStoryAction3D])throws {
        let ordered=windows.sorted{($0.startFrame,$0.id)<($1.startFrame,$1.id)}
        for index in keys.indices.dropFirst() where differs(keys[index-1].transform,keys[index].transform) {
            // A linear/slerp segment a...b changes integer samples a+1...b.
            var cursor=keys[index-1].frame+1
            let end=keys[index].frame+1
            for action in ordered where action.endFrame>cursor {
                guard action.startFrame<=cursor else {break}
                cursor=max(cursor,action.endFrame)
                if cursor>=end {break}
            }
            guard cursor>=end else {throw VideoError.invalid("三维原轨在原生动作声明窗外已发生变化；请按实际开始、结束帧编排动作和前置")}
        }
    }
}

/// These records are added only to the Host schema and explicit game10.
/// ModelScene3DSchema.records remains the unchanged game9/v1 declaration.
public enum ModelStoryAction3DSchema {
    public static let records:[String:String]=[
        "ModelStoryAction3D":"id:s kind:ModelStoryActionKind3D instanceID:s startFrame:i endFrame:i requires:[s] jointNames?:[s] anchor?:ModelVector3 text?:s",
        "ModelScene3D":"version:i instances:[ModelInstance3D] camera:ModelCamera3D lights:[ModelLight3D] transformTracks:[ModelTransformTrack] jointTracks:[ModelJointTrack] actions?:[ModelStoryAction3D]"
    ]
    public static let enums:[String:[String]]=["ModelStoryActionKind3D":ModelStoryActionKind3D.allCases.map(\.rawValue)]
}
enum ModelStoryDecoding3D {
    private struct Key:CodingKey {var stringValue:String;var intValue:Int?{nil};init?(stringValue:String){self.stringValue=stringValue};init?(intValue:Int){return nil}}
    static func keys(_ decoder:Decoder,required:Set<String>,optional:Set<String>=[])throws {
        let c=try decoder.container(keyedBy:Key.self),actual=Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of:actual),actual.isSubset(of:required.union(optional)) else {throw VideoError.invalid("三维原生动作字段缺失或未知，未静默忽略旧别名或扩展字段")}
    }
}
