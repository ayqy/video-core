import Foundation

public enum CartoonPose: String, Codable, CaseIterable, Sendable {
    case listen, speak, walk, object, celebrate
    public var title: String {
        switch self { case .listen: return "倾听"; case .speak: return "发言／示意"; case .walk: return "走向对方"; case .object: return "质疑／受阻"; case .celebrate: return "回应／庆祝" }
    }
}
public enum CartoonCamera: String, Codable, CaseIterable, Sendable {
    case ensemble, speaker
    public var title: String { self == .ensemble ? "全体互动" : "发言者近景" }
}
public struct CartoonActor: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Actual atlas roles, independently editable for each existing character.
    public var poseRoles: [String: String]
    public init(id: String, name: String, poseRoles: [String: String]) { self.id=id; self.name=name; self.poseRoles=poseRoles }
    public static let dinoRoles = ["listen":"hero_idle", "speak":"hero_contribute", "walk":"hero_walk", "walkAlternate":"hero_walk_alt", "object":"hero_blocked", "celebrate":"hero_success"]
}
public struct CartoonActorCue: Codable, Equatable, Identifiable, Sendable {
    public var actorID: String
    public var pose: CartoonPose
    public var fromX: Double
    public var toX: Double
    public var lookAtID: String?
    public var id: String { actorID }
    public init(actorID: String, pose: CartoonPose, fromX: Double, toX: Double, lookAtID: String? = nil) { self.actorID=actorID;self.pose=pose;self.fromX=fromX;self.toX=toX;self.lookAtID=lookAtID }
}
public struct CartoonBeat: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var startFrame: Int
    public var endFrame: Int
    public var speakerID: String?
    public var camera: CartoonCamera
    public var cues: [CartoonActorCue]
    public var animationOffsetFrames: Int
    public init(id: String = Codec.id(), startFrame: Int, endFrame: Int, speakerID: String? = nil, camera: CartoonCamera = .ensemble, cues: [CartoonActorCue], animationOffsetFrames: Int = 0) { self.id=id;self.startFrame=startFrame;self.endFrame=endFrame;self.speakerID=speakerID;self.camera=camera;self.cues=cues;self.animationOffsetFrames=animationOffsetFrames }
}
public struct CartoonActorFrame: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var x: Double
    public var pose: CartoonPose
    public var role: String
    public var mirrored: Bool
    public var speaking: Bool
}
public struct CartoonFrameState: Equatable, Sendable {
    public var beatID: String
    public var beatIndex: Int
    public var camera: CartoonCamera
    public var speakerID: String?
    public var localAnimationFrame: Int
    public var actors: [CartoonActorFrame]
}

/// Source-frame choreography, not generated dialogue, physics or phoneme lip sync.
/// The Host retains narration/captions and asset rights; the module sees only these visual cues.
public struct CartoonPerformance: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var actors: [CartoonActor]
    public var beats: [CartoonBeat]
    public init(actors: [CartoonActor], beats: [CartoonBeat]) { self.actors=actors;self.beats=beats }

    private static func text(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximum && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    public func validate(durationFrames: Int, availableRoles: Set<String>? = nil) throws {
        let ids=Set(actors.map(\.id))
        guard version == 1, (1...54000).contains(durationFrames), (2...4).contains(actors.count), ids.count==actors.count,
              (1...64).contains(beats.count), Set(beats.map(\.id)).count==beats.count else { throw VideoError.invalid("角色表演需2—4个独立角色和1—64个完整连续节拍") }
        let allowedKeys=Set(CartoonPose.allCases.map(\.rawValue)+["walkAlternate"])
        for actor in actors {
            guard actor.id.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil,
                  Self.text(actor.name, maximum: 120), !actor.poseRoles.isEmpty, actor.poseRoles.count<=6,
                  Set(actor.poseRoles.keys).isSubset(of: allowedKeys), actor.poseRoles.values.allSatisfy({ Self.text($0,maximum:128) }) else { throw VideoError.invalid("角色标识、名称或实际动作图块映射无效") }
        }
        var boundary=0
        for beat in beats {
            guard Self.text(beat.id,maximum:80), beat.startFrame==boundary, beat.endFrame>beat.startFrame,
                  beat.endFrame<=durationFrames, (0...216000).contains(beat.animationOffsetFrames),
                  beat.speakerID.map({ ids.contains($0) }) ?? true,
                  beat.camera != .speaker || beat.speakerID != nil,
                  beat.cues.count==actors.count, Set(beat.cues.map(\.actorID))==ids else { throw VideoError.invalid("表演节拍须连续覆盖镜头，发言者、取景和全部角色轨迹须明确") }
            for cue in beat.cues {
                guard cue.fromX.isFinite, cue.toX.isFinite, (0.08...0.92).contains(cue.fromX), (0.08...0.92).contains(cue.toX),
                      cue.lookAtID.map({ ids.contains($0) && $0 != cue.actorID }) ?? true,
                      let actor=actors.first(where:{$0.id==cue.actorID}), let role=actor.poseRoles[cue.pose.rawValue],
                      availableRoles.map({$0.contains(role)}) ?? true else { throw VideoError.invalid("角色轨迹、注视对象或实际姿态图块不完整") }
                if cue.pose == .walk {
                    guard let alternate=actor.poseRoles["walkAlternate"], alternate != role,
                          availableRoles.map({$0.contains(alternate)}) ?? true else { throw VideoError.invalid("行走需要两幅不同的实际动作图块，不能用一张贴图代替步态") }
                }
            }
            boundary=beat.endFrame
        }
        guard boundary==durationFrames else { throw VideoError.invalid("角色表演未覆盖完整源镜头，请调整最后节拍终止帧") }
    }
    public func frameState(frame: Int, fps: Int, durationFrames: Int) throws -> CartoonFrameState {
        try validate(durationFrames:durationFrames)
        guard frame>=0, frame<=216000, (1...120).contains(fps) else { throw VideoError.invalid("角色表演帧或帧率超界") }
        let visible=min(frame,durationFrames-1)
        let index=beats.firstIndex(where:{$0.startFrame<=visible && visible<$0.endFrame})!
        let beat=beats[index], span=max(1,beat.endFrame-beat.startFrame-1)
        let p=Double(visible-beat.startFrame)/Double(span)
        let animation=beat.animationOffsetFrames+visible-beat.startFrame
        let positions=Dictionary(uniqueKeysWithValues:beat.cues.map{($0.actorID,$0.fromX+($0.toX-$0.fromX)*p)})
        let states=actors.map { actor -> CartoonActorFrame in
            let cue=beat.cues.first(where:{$0.actorID==actor.id})!
            var role=actor.poseRoles[cue.pose.rawValue]!
            if cue.pose == .walk && (animation/max(1,fps/6))%2==1 { role=actor.poseRoles["walkAlternate"]! }
            let x=positions[actor.id]!, look=cue.lookAtID.flatMap{positions[$0]}
            return CartoonActorFrame(id:actor.id,name:actor.name,x:x,pose:cue.pose,role:role,mirrored:look.map{$0<x} ?? (x>0.5),speaking:beat.speakerID==actor.id)
        }
        return CartoonFrameState(beatID:beat.id,beatIndex:index,camera:beat.camera,speakerID:beat.speakerID,localAnimationFrame:animation,actors:states)
    }
    public func validate(durationFrames: Int, sprites: [ClassicSprite]) throws {
        try validate(durationFrames:durationFrames,availableRoles:Set(sprites.map(\.role)))
        for actor in actors where beats.contains(where:{$0.cues.contains(where:{$0.actorID==actor.id && $0.pose == .walk})}) {
            let a=sprites.first(where:{$0.role==actor.poseRoles["walk"]})!,b=sprites.first(where:{$0.role==actor.poseRoles["walkAlternate"]})!
            guard a.assetID != b.assetID || a.x != b.x || a.y != b.y || a.width != b.width || a.height != b.height else {throw VideoError.invalid("行走的两个动作名称指向同一图块，请绑定真实不同的步态区域")}
        }
    }
    /// Split and trim preserve the original source-frame positions and walk phase.
    public func trimmed(from start: Int, to end: Int, durationFrames: Int) throws -> CartoonPerformance {
        try validate(durationFrames:durationFrames)
        guard start>=0, end>start, end<=durationFrames else { throw VideoError.invalid("角色表演裁切超出源范围") }
        var result=self
        result.beats=beats.compactMap { beat in
            let a=max(start,beat.startFrame),b=min(end,beat.endFrame)
            guard a<b else{return nil}
            var copy=beat; copy.startFrame=a-start;copy.endFrame=b-start
            let span=Double(max(1,beat.endFrame-beat.startFrame-1))
            let left=Double(a-beat.startFrame)/span, right=Double(b-1-beat.startFrame)/span
            copy.cues=beat.cues.map { cue in var c=cue;c.fromX=min(0.92,max(0.08,cue.fromX+(cue.toX-cue.fromX)*left));c.toX=min(0.92,max(0.08,cue.fromX+(cue.toX-cue.fromX)*right));return c }
            copy.animationOffsetFrames+=a-beat.startFrame
            return copy
        }
        try result.validate(durationFrames:end-start)
        return result
    }
    public static func conversation(durationFrames: Int) throws -> CartoonPerformance {
        guard (6...54000).contains(durationFrames) else { throw VideoError.invalid("完整角色表演须为6—54000源帧") }
        let actors=[CartoonActor(id:"actor-a",name:"甲",poseRoles:CartoonActor.dinoRoles),CartoonActor(id:"actor-b",name:"乙",poseRoles:CartoonActor.dinoRoles)]
        let first=durationFrames/3,second=durationFrames*2/3
        let beats=[
            CartoonBeat(startFrame:0,endFrame:first,speakerID:"actor-a",cues:[.init(actorID:"actor-a",pose:.speak,fromX:0.25,toX:0.25,lookAtID:"actor-b"),.init(actorID:"actor-b",pose:.listen,fromX:0.75,toX:0.75,lookAtID:"actor-a")]),
            CartoonBeat(startFrame:first,endFrame:second,speakerID:"actor-b",camera:.speaker,cues:[.init(actorID:"actor-a",pose:.listen,fromX:0.25,toX:0.25,lookAtID:"actor-b"),.init(actorID:"actor-b",pose:.object,fromX:0.75,toX:0.75,lookAtID:"actor-a")]),
            CartoonBeat(startFrame:second,endFrame:durationFrames,cues:[.init(actorID:"actor-a",pose:.walk,fromX:0.25,toX:0.40,lookAtID:"actor-b"),.init(actorID:"actor-b",pose:.walk,fromX:0.75,toX:0.60,lookAtID:"actor-a")])]
        return CartoonPerformance(actors:actors,beats:beats)
    }
}

public enum CartoonPerformanceSchema {
    public static let records: [String:String] = [
        "CartoonPerformance":"version:i actors:[CartoonActor] beats:[CartoonBeat]",
        "CartoonActor":"id:s name:s poseRoles:{s}",
        "CartoonActorCue":"actorID:s pose:CartoonPose fromX:n toX:n lookAtID?:s",
        "CartoonBeat":"id:s startFrame:i endFrame:i speakerID?:s camera:CartoonCamera cues:[CartoonActorCue] animationOffsetFrames:i"
    ]
    public static let enums: [String:[String]] = ["CartoonPose":CartoonPose.allCases.map(\.rawValue), "CartoonCamera":CartoonCamera.allCases.map(\.rawValue)]
}
