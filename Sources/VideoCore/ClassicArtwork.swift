import Foundation

public enum ClassicGameplay: String, Codable, CaseIterable, Sendable {
    case sokoban = "推箱子", platformer = "横版跳跃", match3 = "三消"
}
/// Coordinates use the source image's top-left origin; all values are normalized.
public struct ClassicSprite: Codable, Equatable, Sendable {
    public var role: String; public var assetID: String
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(role: String, assetID: String, x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.role=role;self.assetID=assetID;self.x=x;self.y=y;self.width=width;self.height=height
    }
}
/// A source record applies to a concrete imported file, never an entire arbitrary public repository.
public struct ClassicSource: Codable, Equatable, Sendable {
    public var assetID: String; public var hash: String; public var source: String
    public var owner: String; public var license: String; public var evidenceID: String
    public init(assetID:String,hash:String,source:String,owner:String,license:String,evidenceID:String) {
        self.assetID=assetID;self.hash=hash;self.source=source;self.owner=owner;self.license=license;self.evidenceID=evidenceID
    }
}
public struct ClassicAudioCue: Codable, Equatable, Identifiable, Sendable {
    public enum Use: String, Codable, CaseIterable, Sendable { case effect = "游戏音效", prompt = "原录音提示（非课程旁白）" }
    public var id = Codec.id(); public var assetID: String; public var startFrame: Int
    public var durationFrames: Int; public var gain: Double; public var use: Use; public var listened: Bool
    public init(assetID:String,startFrame:Int,durationFrames:Int,gain:Double=0.35,use:Use = .effect,listened:Bool=false) {
        self.assetID=assetID;self.startFrame=startFrame;self.durationFrames=durationFrames;self.gain=gain;self.use=use;self.listened=listened
    }
}
/// Purely visual identity for one existing knowledge participant. Pose keys use
/// CartoonPose's established contract plus the actual alternate walk frame.
/// No rule, strategy, source permission, sound or review belongs to this value.
public struct KnowledgeParticipantAppearance: Codable, Equatable, Sendable {
    public var participantID: String
    public var poseRoles: [String: String]
    public init(participantID: String, poseRoles: [String: String]) {
        self.participantID=participantID;self.poseRoles=poseRoles
    }
}
public enum KnowledgeParticipantAppearanceRules {
    public static let poseKeys = Set(CartoonPose.allCases.map(\.rawValue)+["walkAlternate"])
    private static let legacyPoseKeys = [
        "hero_idle":"listen", "hero_contribute":"speak", "hero_walk":"walk",
        "hero_walk_alt":"walkAlternate", "hero_blocked":"object", "hero_success":"celebrate"
    ]
    /// Missing mappings preserve the prior atlas contract. A present mapping
    /// must cover exactly the real participants; it never infers a character
    /// from a label, sorted position, strategy or a prior simulation result.
    public static func validate(artwork: ClassicArtwork, knowledge: KnowledgeSimulation?,
                                imageHashes: [String: String] = [:]) throws {
        guard let appearances=artwork.knowledgeParticipants else { return }
        guard let knowledge else { throw VideoError.invalid("参与者姿态映射只能绑定实际知识模型，不能用于普通游戏或卡通镜头") }
        try knowledge.validate()
        let ids=Set(knowledge.participants.map(\.id))
        guard appearances.count==ids.count, (2...8).contains(appearances.count),
              Set(appearances.map(\.participantID))==ids,
              Set(appearances.map(\.participantID)).count==appearances.count,
              !artwork.sprites.isEmpty,artwork.sprites.count<=32,
              Set(artwork.sprites.map(\.role)).count==artwork.sprites.count else {
            throw VideoError.invalid("参与者姿态须逐项覆盖当前知识实体，拒绝缺项、未知或重复标识及超量图块")
        }
        for appearance in appearances {
            guard Set(appearance.poseRoles.keys)==poseKeys,
                  appearance.poseRoles.values.allSatisfy({
                      !$0.isEmpty && $0==$0.trimmingCharacters(in:.whitespacesAndNewlines) &&
                      $0.utf8.count<=128 && !$0.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
                  }),
                  appearance.poseRoles.values.allSatisfy({role in artwork.sprites.contains{$0.role==role}}),
                  let walk=artwork.sprites.first(where:{$0.role==appearance.poseRoles["walk"]}),
                  let alternate=artwork.sprites.first(where:{$0.role==appearance.poseRoles["walkAlternate"]}) else {
                throw VideoError.invalid("每个知识参与者须明确绑定倾听、示意、两幅步态、受阻和庆祝的实际图块")
            }
            let sameImage:Bool
            if let a=imageHashes[walk.assetID],let b=imageHashes[alternate.assetID] { sameImage=a==b }
            else { sameImage=walk.assetID==alternate.assetID }
            guard !sameImage || walk.x != alternate.x || walk.y != alternate.y ||
                  walk.width != alternate.width || walk.height != alternate.height else {
                throw VideoError.invalid("知识参与者的两个步态指向同一原图区域，请绑定实际不同的步态")
            }
        }
    }
    /// Call after the complete mapping preflight. Only an actual phase/state
    /// pose is translated; participant identity never changes its causal pose.
    public static func spriteRole(participantID: String, legacyRole: String, artwork: ClassicArtwork) throws -> String {
        guard let appearances=artwork.knowledgeParticipants else { return legacyRole }
        guard let key=legacyPoseKeys[legacyRole],
              let appearance=appearances.first(where:{$0.participantID==participantID}),
              let role=appearance.poseRoles[key],artwork.sprites.contains(where:{$0.role==role}) else {
            throw VideoError.invalid("当前知识实体或实际动作缺少已核姿态映射，未退回其他角色")
        }
        return role
    }
}
public struct ClassicArtwork: Codable, Equatable, Sendable {
    public enum Derivation: String, Codable, CaseIterable, Sendable { case original = "下载原件", qStyle = "已生成Q版派生" }
    public var gameplay: ClassicGameplay; public var sprites: [ClassicSprite]; public var sources: [ClassicSource]
    public var derivation: Derivation; public var transformation: String; public var originalAssetIDs: [String]
    public var audioCues: [ClassicAudioCue]
    public var knowledgeParticipants: [KnowledgeParticipantAppearance]?
    public init(gameplay:ClassicGameplay,sprites:[ClassicSprite],sources:[ClassicSource],derivation:Derivation = .original,transformation:String="",originalAssetIDs:[String]=[],audioCues:[ClassicAudioCue]=[],knowledgeParticipants:[KnowledgeParticipantAppearance]?=nil) {
        self.gameplay=gameplay;self.sprites=sprites;self.sources=sources;self.derivation=derivation;self.transformation=transformation;self.originalAssetIDs=originalAssetIDs;self.audioCues=audioCues;self.knowledgeParticipants=knowledgeParticipants
    }
    public var assetIDs: Set<String> { Set(sprites.map(\.assetID)+sources.map(\.assetID)+originalAssetIDs+audioCues.map(\.assetID)) }
    public var evidenceIDs: Set<String> { Set(sources.map(\.evidenceID)) }
    /// The generated atlas contract is top-left hero, top-right crate, bottom-left wall, bottom-right floor.
    public static func quadrants(assetID:String,gameplay:ClassicGameplay,sources:[ClassicSource],derivation:Derivation = .original,transformation:String="",originalAssetIDs:[String]=[]) -> ClassicArtwork {
        let roles=["hero","crate","wall","floor"]
        return ClassicArtwork(gameplay:gameplay,sprites:roles.enumerated().map { ClassicSprite(role:$0.element,assetID:assetID,x:Double($0.offset%2)*0.5,y:Double($0.offset/2)*0.5,width:0.5,height:0.5) },sources:sources,derivation:derivation,transformation:transformation,originalAssetIDs:originalAssetIDs)
    }
}
public enum ClassicArtworkRules {
    public static func requiredRoles(knowledge: Bool, cartoon: Bool) -> Set<String> {
        if knowledge { return ["hero", "floor", "knowledge_backdrop", "obstacle", "hero_idle", "hero_walk", "hero_contribute", "hero_success", "hero_blocked"] }
        return cartoon ? ["hero", "floor"] : ["hero", "crate", "wall", "floor"]
    }
    public static func validate(scene:Scene,assets:[Asset]) throws {
        guard let artwork=scene.classicArtwork else { return }
        guard (1...54000).contains(scene.durationFrames),[.simulation,.cartoon].contains(scene.kind),!artwork.sprites.isEmpty,artwork.sprites.count<=32,artwork.sources.count<=64,Set(artwork.sprites.map(\.role)).count==artwork.sprites.count else { throw VideoError.invalid("经典素材场景类型、图块数或角色标识无效") }
        try KnowledgeParticipantAppearanceRules.validate(artwork:artwork,knowledge:scene.kind == .simulation ? scene.simulation.knowledge:nil,
            imageHashes:Dictionary(assets.map{($0.id,$0.hash)},uniquingKeysWith:{first,_ in first}))
        let required = requiredRoles(knowledge: scene.kind == .simulation && scene.simulation.knowledge != nil, cartoon: scene.kind == .cartoon)
        guard required.isSubset(of:Set(artwork.sprites.map(\.role))) else { throw VideoError.invalid("外部图集须提供角色、地面以及游戏所需箱子和墙体") }
        guard Set(artwork.sources.map(\.assetID)).count==artwork.sources.count else { throw VideoError.invalid("同一素材不能填写互相冲突的来源记录") }
        for source in artwork.sources {
            guard let asset=assets.first(where:{$0.id==source.assetID}),asset.hash==source.hash,asset.evidenceID==source.evidenceID,
                  [source.source,source.owner,source.license,source.evidenceID].allSatisfy({!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) else { throw VideoError.permission("经典素材原件、摘要或来源授权关联不一致") }
        }
        guard artwork.assetIDs.isSubset(of:Set(artwork.sources.map(\.assetID))) else { throw VideoError.permission("图集、原件与音效都须保留各自的具体文件来源与授权") }
        for sprite in artwork.sprites {
            guard let asset=assets.first(where:{$0.id==sprite.assetID}),asset.mediaType.hasPrefix("image"),!sprite.role.isEmpty,
                  [sprite.x,sprite.y,sprite.width,sprite.height].allSatisfy(\.isFinite),sprite.x>=0,sprite.y>=0,sprite.width>0,sprite.height>0,sprite.x+sprite.width<=1.000001,sprite.y+sprite.height<=1.000001 else { throw VideoError.invalid("图块源图片缺失或裁切范围超出原图") }
        }
        if artwork.derivation == .qStyle {
            let originalHashes=Set(assets.filter{artwork.originalAssetIDs.contains($0.id)}.map(\.hash))
            var primaryRoles:Set<String> = scene.kind == .simulation && scene.simulation.knowledge == nil ? ["hero","crate"]:["hero"]
            if scene.kind == .simulation, let knowledge=scene.simulation.knowledge {
                if let appearances=artwork.knowledgeParticipants {
                    primaryRoles.formUnion(appearances.flatMap{Array($0.poseRoles.values)})
                }
                // Knowledge renderers draw scenery and actual action/state
                // sprites, not just the legacy hero. A derived hero must not
                // hide originals in the scene or its performed poses.
                // Filtering existing sprites below retains the optional second
                // walk frame and sky backdrop; no new role becomes required.
                primaryRoles.formUnion(["floor","knowledge_backdrop","backdrop","hero_idle","hero_walk","hero_walk_alt","hero_contribute","hero_blocked"])
                if knowledge.version==1 { primaryRoles.insert("obstacle") }
                if knowledge.isRuleTable, let table=knowledge.ruleTable {
                    primaryRoles.formUnion(table.actions.map{$0.pose.spriteRole})
                    primaryRoles.formUnion(table.states.map{$0.pose.spriteRole})
                } else { primaryRoles.insert("hero_success") }
            }
            if let acting=scene.cartoonPerformance {primaryRoles.formUnion(acting.actors.flatMap{Array($0.poseRoles.values)})}
            let primarySprites=artwork.sprites.filter{primaryRoles.contains($0.role)}
            guard !artwork.originalAssetIDs.isEmpty,!artwork.transformation.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  primarySprites.allSatisfy({ sprite in assets.first(where:{$0.id==sprite.assetID}).map{!originalHashes.contains($0.hash)} == true }) else { throw VideoError.review("Q版角色与主要游戏元素须绑定实际派生产物、原件及转换过程；不能仅更换背景或把原件改标签充当派生") }
        }
        guard artwork.audioCues.count<=128,Set(artwork.audioCues.map(\.id)).count==artwork.audioCues.count else { throw VideoError.invalid("音效数量超界或标识重复") }
        for cue in artwork.audioCues {
            guard let asset=assets.first(where:{$0.id==cue.assetID}),asset.mediaType=="audio",let duration=asset.durationFrames,
                  cue.startFrame>=0,cue.durationFrames>0,cue.durationFrames<=duration,cue.durationFrames<=scene.durationFrames,cue.startFrame<=scene.durationFrames-cue.durationFrames,cue.gain.isFinite,(0...1).contains(cue.gain) else { throw VideoError.invalid("游戏音效实长、位置或音量无效；不得自动截断提示语") }
        }
    }
    /// New bindings/revisions and current production require real registered
    /// source identity. Historical metadata stays decodable and repairable even
    /// if an earlier release allowed separate imports of the same walking cell.
    public static func validateWalkingSources(scene:Scene,assets:[Asset]) throws {
        guard let performance=scene.cartoonPerformance,let artwork=scene.classicArtwork else{return}
        try performance.validate(durationFrames:scene.durationFrames,sprites:artwork.sprites)
        let imageHashes=Dictionary(assets.filter{$0.mediaType.hasPrefix("image")}.map{($0.id,$0.hash)},uniquingKeysWith:{first,_ in first})
        for actor in performance.actors where performance.beats.contains(where:{$0.cues.contains(where:{$0.actorID==actor.id && $0.pose == .walk})}) {
            for key in ["walk","walkAlternate"] {
                guard let role=actor.poseRoles[key],let sprite=artwork.sprites.first(where:{$0.role==role}),imageHashes[sprite.assetID] != nil else {
                    throw VideoError.invalid("新角色步态须绑定当前工作区已登记的实际图片来源")
                }
            }
        }
        try performance.validate(durationFrames:scene.durationFrames,sprites:artwork.sprites,imageHashes:imageHashes)
    }
    public static func validateRights(scene:Scene,workspaceID:String,assets:[Asset],evidence:[Evidence],commercial:Bool,requireListening:Bool=false,now:Date=Date()) throws {
        let scoped=assets.filter{$0.workspaceID==workspaceID}
        try validate(scene:scene,assets:scoped)
        try validateWalkingSources(scene:scene,assets:scoped)
        guard let artwork=scene.classicArtwork else { return }
        for source in artwork.sources {
            guard let proof=evidence.first(where:{$0.id==source.evidenceID && $0.workspaceID==workspaceID}),proof.usable(commercial:commercial,now:now),proof.owner==source.owner,proof.source==source.source else { throw VideoError.permission("外部游戏图像/录音的具体授权尚未核实、已过期或来源不一致") }
        }
        var visited:Set<String>=[],pending=Array(artwork.evidenceIDs)
        while let id=pending.popLast() {
            guard visited.insert(id).inserted else{continue}
            guard let proof=evidence.first(where:{$0.id==id && $0.workspaceID==workspaceID}),proof.usable(commercial:commercial,now:now) else{throw VideoError.permission("素材依赖的许可文件或授权记录已失效")}
            if let assetID=proof.assetID {
                guard let asset=assets.first(where:{$0.id==assetID && $0.workspaceID==workspaceID}) else{throw VideoError.permission("来源许可原件已缺失或跨工作区")}
                if let next=asset.evidenceID{pending.append(next)}
                else if commercial{throw VideoError.permission("来源许可原件尚无权利核对记录")}
            }
        }
        if requireListening && artwork.audioCues.contains(where:{!$0.listened && $0.gain>0}) { throw VideoError.review("游戏音效与原录音提示尚未实际试听确认") }
    }
}
public struct ClassicMotion: Equatable, Sendable {
    public var value:Int;public var before:Int;public var after:Int;public var progress:Double;public var position:Double;public var jump:Double;public var direction:Double;public var eventLabel:String?
}
public enum ClassicMotionRules {
    /// Frame rendering and numeric labels use the same recorded transitions. No wall-clock or random motion.
    public static func state(simulation:Simulation,frame:Int,fps:Int) throws -> ClassicMotion {
        let state=try SimulationReplay.frameState(simulation:simulation,frame:frame,fps:fps)
        let recording=try SimulationReplay.record(simulation:simulation,throughTick:frame/fps)
        let event=recording.transitions.last
        let elapsed=event.map {Double(frame-$0.tick*fps)/Double(fps)} ?? 1
        let p=min(1,max(0,elapsed/0.7));let eased=p*p*(3-2*p)
        let before=event?.before ?? state.value,after=event?.after ?? state.value
        let value=Double(before)+(Double(after)-Double(before))*eased
        return ClassicMotion(value:state.value,before:before,after:after,progress:p,position:value/Double(simulation.capacity),jump:event == nil ? 0:sin(p * .pi),direction:after<before ? -1:1,eventLabel:event?.label)
    }
}
