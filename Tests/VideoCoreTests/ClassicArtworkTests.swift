import XCTest
@testable import VideoCore

final class ClassicArtworkTests:XCTestCase {
    private func fixture() -> (Scene,[Asset],[Evidence]) {
        let proof=Evidence(workspaceID:"w",title:"测试纹理许可",source:"isolated-test-texture",claim:"只验证规则，非产品素材",owner:"test",commercialAllowed:true,verified:true)
        var asset=Asset(workspaceID:"w",name:"test.png",hash:String(repeating:"a",count:64),ext:"png",bytes:4,mediaType:"image");asset.evidenceID=proof.id
        let source=ClassicSource(assetID:asset.id,hash:asset.hash,source:proof.source,owner:proof.owner,license:"isolated-test",evidenceID:proof.id)
        var scene=Scene(kind:.simulation,title:"经典玩法",body:"测试事件");scene.classicArtwork=ClassicArtwork.quadrants(assetID:asset.id,gameplay:.sokoban,sources:[source])
        return(scene,[asset],[proof])
    }
    private func knowledgeFixture(_ model:KnowledgeSimulation) -> (Scene,[Asset],[Evidence]) {
        var(scene,assets,evidence)=fixture()
        var derived=assets[0];derived.id=Codec.id();derived.name="actual-knowledge-poses-fixture.png";derived.hash=String(repeating:"b",count:64);assets.append(derived)
        let proof=evidence[0],original=assets[0]
        let source=ClassicSource(assetID:derived.id,hash:derived.hash,source:proof.source,owner:proof.owner,license:"isolated-test",evidenceID:proof.id)
        let roles=ClassicArtworkRules.requiredRoles(knowledge:true,cartoon:false).union(["hero_walk_alt"])
        scene.simulation.knowledge=model
        scene.classicArtwork=ClassicArtwork(gameplay:.platformer,sprites:roles.sorted().map{ClassicSprite(role:$0,assetID:derived.id)},sources:scene.classicArtwork!.sources+[source],derivation:.qStyle,transformation:"隔离测试中的实际不同派生字节绑定，不代表产品素材",originalAssetIDs:[original.id])
        return(scene,assets,evidence)
    }
    private func publicGoodModel()->KnowledgeSimulation {
        KnowledgeSimulation(knowledgeLabel:"实际选择与后果",participants:[KnowledgeParticipant(id:"a",name:"甲",strategy:.contribute),KnowledgeParticipant(id:"b",name:"乙",strategy:.freeRide)],rounds:1)
    }
    private func matrixModel()->KnowledgeSimulation {
        var model=publicGoodModel();model.version=2;model.payoffMatrix = .prisonersDilemma()
        for index in model.participants.indices {model.participants[index].strategy = .contribute;model.participants[index].matrixStrategy = .alwaysFirst}
        return model
    }
    private func ruleTableModel()->KnowledgeSimulation {
        var model=publicGoodModel()
        for index in model.participants.indices {model.participants[index].strategy = .contribute}
        model.version=3;model.ruleTable=KnowledgeRuleTable(actions:[.init(id:"act",label:"执行")],states:[.init(id:"open",label:"待执行")],plans:model.participants.map{.init(actorID:$0.id,initialStateID:"open",defaultActionID:"act")},rules:[.init(id:"transfer",label:"实际交换",conditions:[.init(kind:.round,minimum:1,maximum:1)],effects:[.transfer(from:"a",to:"b",amount:1)])])
        return model
    }
    func testArtworkPinsConcreteFilesWorkspaceAndEvidence()throws {
        let(scene,assets,evidence)=fixture()
        try scene.validate(assets:assets)
        try ClassicArtworkRules.validateRights(scene:scene,workspaceID:"w",assets:assets,evidence:evidence,commercial:true)
        var changed=assets;changed[0].hash=String(repeating:"b",count:64)
        XCTAssertThrowsError(try ClassicArtworkRules.validate(scene:scene,assets:changed))
        changed=assets;changed[0].workspaceID="foreign"
        XCTAssertThrowsError(try ClassicArtworkRules.validateRights(scene:scene,workspaceID:"w",assets:changed,evidence:evidence,commercial:true))
        var revoked=evidence;revoked[0].commercialAllowed=false
        XCTAssertThrowsError(try ClassicArtworkRules.validateRights(scene:scene,workspaceID:"w",assets:assets,evidence:revoked,commercial:true))
    }
    func testQLabelCannotReplaceActualDerivedImageAndProvenance()throws {
        var(scene,assets,_)=fixture();scene.classicArtwork?.derivation = .qStyle
        XCTAssertThrowsError(try scene.validate(assets:assets))
        scene.classicArtwork?.originalAssetIDs=[assets[0].id];scene.classicArtwork?.transformation="标签变更不是真实转换"
        XCTAssertThrowsError(try scene.validate(assets:assets))
    }
    func testQBackgroundCannotHideAnUnprocessedHeroOrCrate()throws {
        var(scene,assets,evidence)=fixture()
        var derived=assets[0];derived.id=Codec.id();derived.name="actual-derived-fixture.png";derived.hash=String(repeating:"b",count:64);assets.append(derived)
        let proof=evidence[0]
        scene.classicArtwork?.sources.append(ClassicSource(assetID:derived.id,hash:derived.hash,source:proof.source,owner:proof.owner,license:"isolated-test",evidenceID:proof.id))
        scene.classicArtwork?.derivation = .qStyle;scene.classicArtwork?.originalAssetIDs=[assets[0].id];scene.classicArtwork?.transformation="测试派生文件绑定规则，不代表实际产品素材"
        scene.classicArtwork?.sprites[2].assetID=derived.id // Only the wall is changed; hero and crate remain originals.
        XCTAssertThrowsError(try scene.validate(assets:assets))
        for index in 0..<2 {scene.classicArtwork?.sprites[index].assetID=derived.id}
        XCTAssertNoThrow(try scene.validate(assets:assets))
        scene.classicArtwork?.sprites[1].assetID=assets[0].id
        XCTAssertThrowsError(try scene.validate(assets:assets))
    }
    func testQKnowledgeHeroCannotHideOriginalPublicGoodOrMatrixActionPoses()throws {
        for model in [publicGoodModel(),matrixModel()] {
            try model.validate()
            let(scene,assets,_)=knowledgeFixture(model)
            XCTAssertNoThrow(try ClassicArtworkRules.validate(scene:scene,assets:assets))
            for role in ["hero_idle","hero_walk","hero_walk_alt","hero_contribute","hero_success","hero_blocked"] {
                var changed=scene
                let index=try XCTUnwrap(changed.classicArtwork?.sprites.firstIndex{$0.role==role})
                changed.classicArtwork?.sprites[index].assetID=assets[0].id
                XCTAssertThrowsError(try ClassicArtworkRules.validate(scene:changed,assets:assets),"实际绘制的\(role)不能借用默认hero的Q版标签")
            }
        }
    }
    func testQKnowledgeSceneryRejectsOriginalGroundAndBackdropAcrossMechanisms()throws {
        for model in [publicGoodModel(),matrixModel(),ruleTableModel()] {
            try model.validate()
            var(scene,assets,_)=knowledgeFixture(model)
            XCTAssertNoThrow(try ClassicArtworkRules.validate(scene:scene,assets:assets),"可选天空背景未提供时不新增必填要求")
            scene.classicArtwork?.sprites.append(ClassicSprite(role:"backdrop",assetID:assets[1].id))
            XCTAssertNoThrow(try ClassicArtworkRules.validate(scene:scene,assets:assets))
            for role in ["floor","knowledge_backdrop","backdrop"] {
                var changed=scene
                let index=try XCTUnwrap(changed.classicArtwork?.sprites.firstIndex{$0.role==role})
                changed.classicArtwork?.sprites[index].assetID=assets[0].id
                XCTAssertThrowsError(try ClassicArtworkRules.validate(scene:changed,assets:assets),"实际绘制的\(role)不能以原件冒充统一Q版场景")
            }
        }
    }
    func testQPublicGoodChecksDerivedGateWithoutPromotingUnusedObstaclesInOtherMechanisms()throws {
        for model in [publicGoodModel(),matrixModel(),ruleTableModel()] {
            var(scene,assets,_)=knowledgeFixture(model)
            let index=try XCTUnwrap(scene.classicArtwork?.sprites.firstIndex{$0.role=="obstacle"})
            scene.classicArtwork?.sprites[index].assetID=assets[0].id
            if model.version==1 {
                XCTAssertThrowsError(try ClassicArtworkRules.validate(scene:scene,assets:assets),"公共品实际清障必须绘制Q版障碍")
            } else {
                XCTAssertNoThrow(try ClassicArtworkRules.validate(scene:scene,assets:assets),"矩阵和规则表不绘制此备用图块，不将它升级为本次Q版要求")
            }
        }
    }
    func testQKnowledgePoseChecksKeepOptionalWalkFallbackAndIgnoreUnusedExtraSprites()throws {
        var(scene,assets,_)=knowledgeFixture(publicGoodModel())
        scene.classicArtwork?.sprites.removeAll{$0.role=="hero_walk_alt"}
        scene.classicArtwork?.sprites.append(ClassicSprite(role:"unused-original-reference",assetID:assets[0].id))
        XCTAssertNoThrow(try ClassicArtworkRules.validate(scene:scene,assets:assets),"可选步态缺失仍由渲染器正常回退；未使用的原件参考不升级为Q版要求")
        var alias=assets[0];alias.id=Codec.id();alias.name="same-original-bytes.png";assets.append(alias)
        let source=try XCTUnwrap(scene.classicArtwork?.sources.first{$0.assetID==assets[0].id})
        scene.classicArtwork?.sources.append(ClassicSource(assetID:alias.id,hash:alias.hash,source:source.source,owner:source.owner,license:source.license,evidenceID:source.evidenceID))
        let walk=try XCTUnwrap(scene.classicArtwork?.sprites.firstIndex{$0.role=="hero_walk"})
        scene.classicArtwork?.sprites[walk].assetID=alias.id
        XCTAssertThrowsError(try ClassicArtworkRules.validate(scene:scene,assets:assets),"相同原件字节换assetID也不是派生")
    }
    func testQRuleTableChecksItsActualDeclaredPosesWithoutRequiringUnusedCelebration()throws {
        let model=ruleTableModel()
        try model.validate()
        var(scene,assets,_)=knowledgeFixture(model)
        let celebration=try XCTUnwrap(scene.classicArtwork?.sprites.firstIndex{$0.role=="hero_success"})
        scene.classicArtwork?.sprites[celebration].assetID=assets[0].id
        XCTAssertNoThrow(try ClassicArtworkRules.validate(scene:scene,assets:assets),"当前规则未声明或绘制的庆祝姿态不新增派生要求")
        for role in ["hero_idle","hero_walk","hero_walk_alt","hero_contribute","hero_blocked"] {
            var changed=scene
            let index=try XCTUnwrap(changed.classicArtwork?.sprites.firstIndex{$0.role==role})
            changed.classicArtwork?.sprites[index].assetID=assets[0].id
            XCTAssertThrowsError(try ClassicArtworkRules.validate(scene:changed,assets:assets),role)
        }
        var action=scene;action.simulation.knowledge?.ruleTable?.actions[0].pose = .celebrate
        XCTAssertThrowsError(try ClassicArtworkRules.validate(scene:action,assets:assets),"声明动作实际选择的庆祝图块也须为派生")
        var state=scene;state.simulation.knowledge?.ruleTable?.states[0].pose = .celebrate
        XCTAssertThrowsError(try ClassicArtworkRules.validate(scene:state,assets:assets),"声明状态实际选择的庆祝图块也须为派生")
    }
    func testAudioBoundsAndListeningAreIndependentOfNarration()throws {
        var(scene,assets,evidence)=fixture()
        let proof=Evidence(workspaceID:"w",title:"提示录音",source:"test-recording",claim:"测试",owner:"test",commercialAllowed:true,verified:true)
        var audio=Asset(workspaceID:"w",name:"ready.wav",hash:String(repeating:"c",count:64),ext:"wav",bytes:44,mediaType:"audio",durationFrames:15);audio.evidenceID=proof.id;assets.append(audio);evidence.append(proof)
        scene.classicArtwork?.sources.append(ClassicSource(assetID:audio.id,hash:audio.hash,source:proof.source,owner:proof.owner,license:"test",evidenceID:proof.id))
        scene.classicArtwork?.audioCues=[ClassicAudioCue(assetID:audio.id,startFrame:0,durationFrames:15,use:.prompt)]
        XCTAssertNil(scene.voice);XCTAssertTrue(scene.narration.isEmpty)
        try scene.validate(assets:assets)
        XCTAssertThrowsError(try ClassicArtworkRules.validateRights(scene:scene,workspaceID:"w",assets:assets,evidence:evidence,commercial:true,requireListening:true))
        scene.classicArtwork?.audioCues[0].listened=true
        try ClassicArtworkRules.validateRights(scene:scene,workspaceID:"w",assets:assets,evidence:evidence,commercial:true,requireListening:true)
        scene.classicArtwork?.audioCues[0].startFrame=Int.max
        XCTAssertThrowsError(try scene.validate(assets:assets))
    }
    func testFreezeTracksOriginalAndAtlasRights()throws {
        let(scene,assets,evidence)=fixture()
        let product=Product(workspaceID:"w",sku:"qa",name:"qa",checkout:"https://example.com",audience:"a",task:"t",outcome:"o",prerequisite:"p",scope:"s",prices:[Price(money:Money(1),source:"test")])
        var revision=Revision(product:product,purpose:.education,aspect:.landscape,scenes:[scene],cta:"核对")
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:assets,evidence:evidence)
        XCTAssertTrue(revision.dependencies!.records.contains{$0.id=="asset:"+assets[0].id})
        XCTAssertTrue(revision.dependencies!.records.contains{$0.id=="evidence:"+evidence[0].id})
        var changed=evidence;changed[0].source="changed"
        XCTAssertFalse(DependencyRules.diff(revision:revision,assets:assets,evidence:changed).isEmpty)
    }
    func testRuleEventsDriveBoundedDeterministicCharacterMotion()throws {
        var simulation=Simulation();simulation.initial=20;simulation.capacity=100;simulation.events=[RuleEvent(tick:1,delta:70,label:"输入")]
        let before=try ClassicMotionRules.state(simulation:simulation,frame:29,fps:30)
        let moving=try ClassicMotionRules.state(simulation:simulation,frame:40,fps:30)
        let after=try ClassicMotionRules.state(simulation:simulation,frame:60,fps:30)
        XCTAssertEqual(before.position,0.2,accuracy:0.0001);XCTAssertEqual(after.position,0.9,accuracy:0.0001)
        XCTAssertGreaterThan(moving.position,before.position);XCTAssertLessThan(moving.position,after.position);XCTAssertGreaterThan(moving.jump,0)
        XCTAssertEqual(moving,try ClassicMotionRules.state(simulation:simulation,frame:40,fps:30));XCTAssertEqual(moving.value,90)
        simulation.events.append(RuleEvent(tick:3,delta:-40,label:"释放"))
        XCTAssertEqual(try ClassicMotionRules.state(simulation:simulation,frame:100,fps:30).direction,-1)
    }
    func testNewDraftCanSaveBeforeArtworkSelection()throws {
        let scene=Scene(kind:.simulation,title:"先建草稿",body:"稍后选择素材")
        XCTAssertEqual(scene.classicArtworkRequired,true)
        XCTAssertNoThrow(try scene.validate(assets:[]))
        var object=try JSONSerialization.jsonObject(with:Codec.data(scene)) as! [String:Any];object.removeValue(forKey:"classicArtworkRequired")
        let historic=try Codec.decoder().decode(Scene.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNil(historic.classicArtworkRequired)
    }
}

/// Isolated rule fixtures, not game artwork, paid access or human approval.
final class KnowledgeParticipantAppearanceTests: XCTestCase {
    private let keys=["listen","speak","walk","walkAlternate","object","celebrate"]
    private let legacy=["hero_idle","hero_contribute","hero_walk","hero_walk_alt","hero_blocked","hero_success"]
    private func model(_ version:Int=1)->KnowledgeSimulation {
        var model=KnowledgeSimulation(knowledgeLabel:"参与者选择",participants:[
            .init(id:"a",name:"甲",strategy:.contribute,initialResources:10),
            .init(id:"b",name:"乙",strategy:.freeRide,initialResources:10)
        ],rounds:1)
        if version==2 {
            model.version=2;model.payoffMatrix = .prisonersDilemma()
            for i in model.participants.indices {model.participants[i].strategy = .contribute;model.participants[i].matrixStrategy = .alwaysFirst}
        } else if version==3 {
            for i in model.participants.indices {model.participants[i].strategy = .contribute}
            model.version=3
            model.ruleTable=KnowledgeRuleTable(actions:[.init(id:"wait",label:"等待",pose:.idle)],states:[.init(id:"open",label:"待处理")],
                plans:[.init(actorID:"a",initialStateID:"open",defaultActionID:"wait"),.init(actorID:"b",initialStateID:"open",defaultActionID:"wait")],
                rules:[.init(id:"remain",label:"保持",conditions:[.init(kind:.round,minimum:1,maximum:1)],effects:[.setState(actorID:"a",stateID:"open")])])
        }
        return model
    }
    private func fixture(_ version:Int=1)throws->(Scene,[Asset],[Evidence]) {
        let proof=Evidence(workspaceID:"w",title:"隔离规则纹理",source:"isolated-appearance",claim:"只验证视觉身份与来源规则",owner:"rules",commercialAllowed:false,verified:true)
        var original=Asset(workspaceID:"w",name:"original.png",hash:String(repeating:"a",count:64),ext:"png",bytes:4,mediaType:"image")
        original.evidenceID=proof.id
        var derived=original;derived.id=Codec.id();derived.name="derived.png";derived.hash=String(repeating:"b",count:64)
        let sources=[original,derived].map{ClassicSource(assetID:$0.id,hash:$0.hash,source:proof.source,owner:proof.owner,license:"isolated",evidenceID:proof.id)}
        let required=ClassicArtworkRules.requiredRoles(knowledge:true,cartoon:false).union(["hero_walk_alt"])
        var sprites=required.sorted().map{ClassicSprite(role:$0,assetID:derived.id)}
        for id in ["a","b"] {
            sprites += keys.enumerated().map{ClassicSprite(role:id+"_"+$0.element,assetID:derived.id,x:Double($0.offset%3)/3,y:Double($0.offset/3)/2,width:1.0/3,height:0.5)}
        }
        let appearances=["b","a"].map{id in KnowledgeParticipantAppearance(participantID:id,poseRoles:Dictionary(uniqueKeysWithValues:keys.map{($0,id+"_"+$0)}))}
        var scene=Scene(kind:.simulation,title:"同一知识的不同角色",body:"规则结果不因视觉身份绑定而改变。",durationFrames:180)
        scene.simulation.knowledge=model(version)
        scene.classicArtwork=ClassicArtwork(gameplay:.sokoban,sprites:sprites,sources:sources,derivation:.qStyle,transformation:"隔离实际不同字节测试",originalAssetIDs:[original.id],knowledgeParticipants:appearances)
        return(scene,[original,derived],[proof])
    }
    func testOldArtworkJSONWithoutMappingRetainsExactEncodedBytes()throws {
        var(scene,_,_)=try fixture();scene.classicArtwork?.knowledgeParticipants=nil
        let artwork=try XCTUnwrap(scene.classicArtwork),bytes=try Codec.data(artwork)
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("knowledgeParticipants"))
        let decoded=try Codec.decoder().decode(ClassicArtwork.self,from:bytes)
        XCTAssertNil(decoded.knowledgeParticipants);XCTAssertEqual(try Codec.data(decoded),bytes)
        XCTAssertEqual(try KnowledgeParticipantAppearanceRules.spriteRole(participantID:"old-any-id",legacyRole:"hero_walk",artwork:decoded),"hero_walk")
    }
    func testNormalBindingAllMechanismsUsesExactParticipantIDsWithoutChangingCausalInputs()throws {
        for version in [1,2,3] {
            let(scene,assets,evidence)=try fixture(version),oldSimulation=try Codec.data(scene.simulation)
            let oldTrace=try SimulationReplay.record(scene:scene)
            let bound=try ClassicSceneEditing.binding(XCTUnwrap(scene.classicArtwork),character:"甲与乙",to:scene,assets:assets,evidence:evidence,workspaceID:"w",requireQStyle:true)
            try ClassicArtworkRules.validateRights(scene:bound,workspaceID:"w",assets:assets,evidence:evidence,commercial:false)
            XCTAssertEqual(try Codec.data(bound.simulation),oldSimulation)
            XCTAssertEqual(try SimulationReplay.record(scene:bound),oldTrace)
            var reordered=bound;reordered.simulation.knowledge?.participants.reverse()
            for id in ["a","b"] {for (i,role) in legacy.enumerated() {
                XCTAssertEqual(try KnowledgeParticipantAppearanceRules.spriteRole(participantID:id,legacyRole:role,artwork:XCTUnwrap(reordered.classicArtwork)),id+"_"+keys[i])
            }}
            XCTAssertThrowsError(try ClassicArtworkRules.validateRights(scene:bound,workspaceID:"w",assets:assets,evidence:evidence,commercial:true))
        }
    }
    func testPresentMappingRejectsUnknownDuplicateMissingAndNonKnowledgeParticipants()throws {
        let(scene,assets,_)=try fixture()
        for mutation in 0..<6 {
            var changed=scene
            switch mutation {
            case 0:changed.classicArtwork?.knowledgeParticipants=[]
            case 1:changed.classicArtwork?.knowledgeParticipants?.removeLast()
            case 2:changed.classicArtwork?.knowledgeParticipants?[0].participantID="unknown"
            case 3:
                let duplicate=changed.classicArtwork!.knowledgeParticipants![1]
                changed.classicArtwork?.knowledgeParticipants?[0]=duplicate
            case 4:changed.simulation.knowledge=nil
            default:changed.kind = .cartoon
            }
            XCTAssertThrowsError(try ClassicArtworkRules.validate(scene:changed,assets:assets),"mutation "+String(mutation))
        }
    }
    func testBoundPosesRequireAllSixActualRolesAndDistinctWalkRegions()throws {
        let(scene,assets,_)=try fixture()
        for mutation in 0..<6 {
            var changed=scene
            switch mutation {
            case 0:changed.classicArtwork?.knowledgeParticipants?[0].poseRoles.removeValue(forKey:"object")
            case 1:changed.classicArtwork?.knowledgeParticipants?[0].poseRoles["extra"]="a_listen"
            case 2:changed.classicArtwork?.knowledgeParticipants?[0].poseRoles["walk"]="missing"
            case 3:changed.classicArtwork?.knowledgeParticipants?[0].poseRoles["listen"]=" a_listen"
            case 4:changed.classicArtwork?.knowledgeParticipants?[0].poseRoles["walkAlternate"]="b_walk"
            default:
                let index=try XCTUnwrap(changed.classicArtwork?.sprites.firstIndex{$0.role=="b_walkAlternate"})
                let other=try XCTUnwrap(changed.classicArtwork?.sprites.first{$0.role=="b_walk"})
                changed.classicArtwork?.sprites[index]=ClassicSprite(role:"b_walkAlternate",assetID:other.assetID,x:other.x,y:other.y,width:other.width,height:other.height)
            }
            XCTAssertThrowsError(try ClassicArtworkRules.validate(scene:changed,assets:assets),"mutation "+String(mutation))
        }
    }
    func testEveryBoundPoseMustBeDerivedEvenWhenDefaultHeroIsValid()throws {
        let(scene,assets,_)=try fixture()
        for id in ["a","b"] {for key in keys {
            var changed=scene
            let index=try XCTUnwrap(changed.classicArtwork?.sprites.firstIndex{$0.role==id+"_"+key})
            changed.classicArtwork?.sprites[index].assetID=assets[0].id
            XCTAssertThrowsError(try ClassicArtworkRules.validate(scene:changed,assets:assets),id+"_"+key)
        }}
        var changed=scene,aliased=assets[0];aliased.id=Codec.id()
        let original=try XCTUnwrap(changed.classicArtwork?.sources.first{$0.assetID==assets[0].id})
        changed.classicArtwork?.sources.append(ClassicSource(assetID:aliased.id,hash:aliased.hash,source:original.source,owner:original.owner,license:original.license,evidenceID:original.evidenceID))
        let index=try XCTUnwrap(changed.classicArtwork?.sprites.firstIndex{$0.role=="b_speak"})
        changed.classicArtwork?.sprites[index].assetID=aliased.id
        XCTAssertThrowsError(try ClassicArtworkRules.validate(scene:changed,assets:assets+[aliased]))
    }
    func testSameDerivedImageAliasCannotPretendToBeAnotherWalkFrameAndSpriteLimitRemains()throws {
        let(scene,assets,_)=try fixture()
        var alias=assets[1];alias.id=Codec.id()
        var changed=scene
        let source=try XCTUnwrap(changed.classicArtwork?.sources.first{$0.assetID==assets[1].id})
        changed.classicArtwork?.sources.append(ClassicSource(assetID:alias.id,hash:alias.hash,source:source.source,owner:source.owner,license:source.license,evidenceID:source.evidenceID))
        let walk=try XCTUnwrap(changed.classicArtwork?.sprites.first{$0.role=="b_walk"})
        let index=try XCTUnwrap(changed.classicArtwork?.sprites.firstIndex{$0.role=="b_walkAlternate"})
        changed.classicArtwork?.sprites[index]=ClassicSprite(role:"b_walkAlternate",assetID:alias.id,x:walk.x,y:walk.y,width:walk.width,height:walk.height)
        XCTAssertThrowsError(try ClassicArtworkRules.validate(scene:changed,assets:assets+[alias]))
        changed=scene
        while changed.classicArtwork!.sprites.count<33 {
            let count=changed.classicArtwork!.sprites.count
            changed.classicArtwork?.sprites.append(ClassicSprite(role:"unused_"+String(count),assetID:assets[1].id))
        }
        XCTAssertThrowsError(try ClassicArtworkRules.validate(scene:changed,assets:assets))
    }
    func testCounterfactualKeepsVisualIdentityButChangesActualRecordedConsequence()throws {
        let(scene,assets,_)=try fixture()
        var changed=scene;changed.simulation.knowledge?.threshold=2
        changed.simulation.knowledge?.participants[1].strategy = .contribute
        try ClassicArtworkRules.validate(scene:changed,assets:assets)
        XCTAssertEqual(changed.classicArtwork?.knowledgeParticipants,scene.classicArtwork?.knowledgeParticipants)
        XCTAssertNotEqual(try SimulationReplay.record(scene:changed),try SimulationReplay.record(scene:scene))
    }
    func testVisualWireRetainsMappingsWithoutSourcesNarrationOrApprovalAndNewSchemaIsExplicit()throws {
        let(scene,_,_)=try fixture()
        let props=PluginVisualProps(scene:scene),data=try Codec.data(props)
        let decoded=try Codec.decoder().decode(PluginVisualProps.self,from:data)
        XCTAssertEqual(decoded.artwork?.knowledgeParticipants,scene.classicArtwork?.knowledgeParticipants)
        XCTAssertEqual(decoded.drawingScene().classicArtwork?.knowledgeParticipants,scene.classicArtwork?.knowledgeParticipants)
        XCTAssertTrue(decoded.drawingScene().classicArtwork!.sources.isEmpty)
        XCTAssertNil(decoded.drawingScene().voice)
        for schema in [1,2,3,5] {
            XCTAssertThrowsError(try PluginInputCompatibility.requireKnowledgeSupport(scene.simulation,pluginID:"video.game",inputSchema:schema,appearances:scene.classicArtwork?.knowledgeParticipants))
        }
        XCTAssertNoThrow(try PluginInputCompatibility.requireKnowledgeSupport(scene.simulation,pluginID:"video.game",inputSchema:6,appearances:scene.classicArtwork?.knowledgeParticipants))
        XCTAssertEqual(try PluginInputCompatibility.publicationSchema(pluginID:"video.game"),2)
        XCTAssertEqual(try PluginInputCompatibility.publicationSchema(pluginID:"video.game",requested:"6"),6)
        XCTAssertThrowsError(try PluginInputCompatibility.publicationSchema(pluginID:"video.cartoon",requested:"6"))
        for old in [1,2,3,4,5] {XCTAssertNil(PluginRPCSchemas.definitions(inputSchemaVersion:old)["PluginArtworkProps"]?.object?["properties"]?.object?["knowledgeParticipants"])}
        let definitions=PluginRPCSchemas.definitions(inputSchemaVersion:6)
        XCTAssertNotNil(definitions["KnowledgeParticipantAppearance"])
        XCTAssertNotNil(definitions["PluginArtworkProps"]?.object?["properties"]?.object?["knowledgeParticipants"])
        XCTAssertNotNil(AgentSchemas.definitions()["ClassicArtwork"]?.object?["properties"]?.object?["knowledgeParticipants"])
    }
}
