import XCTest
@testable import VideoCore

final class StoryCausalSourcesTests:XCTestCase {
    private func model()->KnowledgeSimulation {
        let plans=[KnowledgeRuleActorPlan(actorID:"a",initialStateID:"loaded",defaultActionID:"deliver"),KnowledgeRuleActorPlan(actorID:"b",initialStateID:"loaded",defaultActionID:"wait"),KnowledgeRuleActorPlan(actorID:"buyer",initialStateID:"idle",defaultActionID:"wait")]
        let rules=[KnowledgeRule(id:"deliver-a",label:"甲实际运到",conditions:[.init(kind:.round,minimum:2,maximum:2),.init(kind:.action,actorID:"a",actionID:"deliver"),.init(kind:.state,actorID:"a",stateID:"loaded")],effects:[.setState(actorID:"a",stateID:"delivered")]),
                   KnowledgeRule(id:"sale-a",label:"交货后买家付款",conditions:[.init(kind:.round,minimum:3,maximum:3),.init(kind:.state,actorID:"a",stateID:"delivered")],effects:[.transfer(from:"buyer",to:"a",amount:2),.setState(actorID:"a",stateID:"sold")])]
        return KnowledgeSimulation(knowledgeLabel:"交货和结算",resourceLabel:"金币",participants:[.init(id:"a",name:"甲",strategy:.contribute,initialResources:4),.init(id:"b",name:"乙",strategy:.contribute,initialResources:4),.init(id:"buyer",name:"买家",strategy:.contribute,initialResources:12)],rounds:3,ruleTable:.init(actions:[.init(id:"deliver",label:"运货"),.init(id:"wait",label:"等候")],states:[.init(id:"loaded",label:"已装货"),.init(id:"delivered",label:"已运到"),.init(id:"sold",label:"已卖出"),.init(id:"idle",label:"空闲")],plans:plans,rules:rules))
    }
    private func source(_ model:KnowledgeSimulation,id:String,start:Int,end:Int,parent:String?=nil,plan:KnowledgeRuleActorPlan?=nil)throws->StoryCausalSource {
        .init(id:id,parentID:parent,intervention:plan.map{.init(actorID:$0.actorID,plan:$0)},model:model,seed:24,trace:try KnowledgeSimulationEngine.record(model:model,seed:24,throughTick:model.lastSettlementTick()),startFrame:start,endFrame:end)
    }
    private func transfer(_ id:String,_ subject:String,_ target:String,_ from:Int,_ to:Int,_ amount:Int)->StoryAction {
        .init(id:id,kind:.transfer,subjectID:subject,targetID:target,startFrame:from,endFrame:to,from:.init(x:0.2,y:0.5),to:.init(x:0.8,y:0.5),quantity:amount)
    }
    private func scene()throws->Scene {
        var scene=Scene(title:"交货再付款",body:"",narration:"送到之后，买家付钱。",durationFrames:180)
        scene.classicArtworkRequired=false
        scene.layers=["person-a","person-b","buyer","cargo-a","coin-a","fund","road"].map {id in var layer=SceneLayer(kind:.rectangle,endFrame:180);layer.id=id;return layer}
        let base=model();var refund=base,table=try XCTUnwrap(base.ruleTable);table.plans[0].defaultActionID="wait";refund.ruleTable=table
        var rescue=refund;table.plans[0].decisions=[.init(id:"resume",priority:0,conditions:[.init(kind:.round,minimum:2,maximum:2)],actionID:"deliver")];rescue.ruleTable=table
        scene.storyActions=[transfer("delivery","cargo-a","buyer",20,35,1),transfer("payment","coin-a","person-a",40,55,2),.init(id:"refund-wait",kind:.show,subjectID:"person-a",startFrame:65,endFrame:75),transfer("delivery-rescue","cargo-a","buyer",140,155,1),transfer("payment-rescue","coin-a","person-a",160,175,2)]
        scene.storyCausality = .init(poolSubjectID:"fund",actors:[.init(actorID:"a",subjectID:"person-a"),.init(actorID:"a",subjectID:"cargo-a"),.init(actorID:"a",subjectID:"road"),.init(actorID:"b",subjectID:"person-b"),.init(actorID:"buyer",subjectID:"buyer")],sources:[
            try source(base,id:"base",start:0,end:60),try source(refund,id:"refund",start:60,end:120,parent:"base",plan:refund.ruleTable!.plans[0]),try source(rescue,id:"rescue",start:120,end:180,parent:"refund",plan:rescue.ruleTable!.plans[0])],bindings:[
                .init(actionID:"delivery",sourceID:"base",eventID:"2-收益结算",kind:.delivery,actorID:"a",ruleID:"deliver-a",toActorID:"buyer",fromStateID:"loaded",toStateID:"delivered"),
                .init(actionID:"payment",sourceID:"base",eventID:"3-收益结算",kind:.payment,requires:["delivery"],ruleID:"sale-a",fromActorID:"buyer",toActorID:"a",amount:2),
                .init(actionID:"refund-wait",sourceID:"refund",eventID:"1-实际出力与扣费",kind:.performedAction,actorID:"a",actionKey:"wait"),
                .init(actionID:"delivery-rescue",sourceID:"rescue",eventID:"2-收益结算",kind:.delivery,actorID:"a",ruleID:"deliver-a",toActorID:"buyer",fromStateID:"loaded",toStateID:"delivered"),
                .init(actionID:"payment-rescue",sourceID:"rescue",eventID:"3-收益结算",kind:.payment,requires:["delivery-rescue"],ruleID:"sale-a",fromActorID:"buyer",toActorID:"a",amount:2)])
        return scene
    }
    private func mutate(_ change:(inout StoryCausality,inout [StoryAction])->Void)throws->Scene {
        var result=try scene(),causality=try XCTUnwrap(result.storyCausality),actions=try XCTUnwrap(result.storyActions);change(&causality,&actions);result.storyCausality=causality;result.storyActions=actions;return result
    }
    private func project(_ scene:Scene)->Project {Project(workspaceID:"w",name:"因果故事",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"交货"),aspect:.landscape,scenes:[scene]))}

    private func costScene(oldCost:Int=1,newCost:Int=2,unused:Bool=false)throws->Scene {
        var baseline=model();let actionID=unused ? "unused":"deliver"
        if unused {baseline.ruleTable!.actions.append(.init(id:actionID,label:"未选择的行动",cost:oldCost))}
        else {baseline.ruleTable!.actions[0].cost=oldCost}
        var alternative=baseline;let index=try XCTUnwrap(alternative.ruleTable!.actions.firstIndex{$0.id==actionID})
        alternative.ruleTable!.actions[index].cost=newCost
        var result=Scene(title:"同一行动的成本变化",body:"",narration:"成本变化后，按实际执行结果比较。",durationFrames:120)
        result.classicArtworkRequired=false
        result.layers=["person-a","person-b","buyer","fund"].map {id in var layer=SceneLayer(kind:.rectangle,endFrame:120);layer.id=id;return layer}
        result.storyActions=[.init(id:"base-action",kind:.show,subjectID:"person-a",startFrame:5,endFrame:15),.init(id:"cost-action",kind:.show,subjectID:"person-a",startFrame:65,endFrame:75)]
        result.storyCausality = .init(version:2,poolSubjectID:"fund",actors:[.init(actorID:"a",subjectID:"person-a"),.init(actorID:"b",subjectID:"person-b"),.init(actorID:"buyer",subjectID:"buyer")],sources:[
            try source(baseline,id:"base",start:0,end:60),
            .init(id:"cost",parentID:"base",actionCost:.init(actionID:actionID,newCost:newCost),model:alternative,seed:24,trace:try KnowledgeSimulationEngine.record(model:alternative,seed:24,throughTick:alternative.lastSettlementTick()),startFrame:60,endFrame:120)
        ],bindings:[
            .init(actionID:"base-action",sourceID:"base",eventID:"1-实际出力与扣费",kind:.performedAction,actorID:"a",actionKey:"deliver"),
            .init(actionID:"cost-action",sourceID:"cost",eventID:"1-实际出力与扣费",kind:.performedAction,actorID:"a",actionKey:"deliver")
        ])
        // Cost 100000 constrains the action, so its display must bind an actual
        // outcome rather than claim that the requested action was performed.
        if newCost>4 {result.storyCausality!.bindings[1] = .init(actionID:"cost-action",sourceID:"cost",eventID:"1-清障判定",kind:.outcome,outcome:result.storyCausality!.sources[1].trace.events.first{$0.id=="1-清障判定"}!.obstacleCleared)}
        return result
    }
    private struct LegacySource:Encodable {
        var id:String;var parentID:String?;var intervention:StoryCausalIntervention?
        var model:KnowledgeSimulation;var seed:UInt64;var trace:KnowledgeTrace;var startFrame:Int;var endFrame:Int
        init(_ value:StoryCausalSource) {id=value.id;parentID=value.parentID;intervention=value.intervention;model=value.model;seed=value.seed;trace=value.trace;startFrame=value.startFrame;endFrame=value.endFrame}
    }
    private struct LegacyCausality:Encodable {
        var version:Int;var poolSubjectID:String;var actors:[StoryCausalActor];var sources:[LegacySource];var bindings:[StoryCausalBinding]
        init(_ value:StoryCausality) {version=value.version;poolSubjectID=value.poolSubjectID;actors=value.actors;sources=value.sources.map(LegacySource.init);bindings=value.bindings}
    }

    func testThreeBranchesVerifyCompleteTracesAndConserveTwentyCoins()throws {
        let scene=try scene();try scene.validate(assets:[])
        let value=try XCTUnwrap(scene.storyCausality)
        let causalRoundTrip=try Codec.decoder().decode(StoryCausality.self,from:Codec.data(value))
        var restored=scene;restored.storyCausality=causalRoundTrip;try restored.validate(assets:[])
        XCTAssertEqual(try Codec.decoder().decode(Scene.self,from:Codec.data(scene)),scene)
        for source in value.sources {
            XCTAssertEqual(source.trace.events.count,18);XCTAssertEqual(source.trace.rounds.count,3)
            XCTAssertEqual(source.trace.finalResources.reduce(0){$0+$1.resources},20)
        }
        XCTAssertEqual(value.sources[0].trace.finalResources.first{$0.id=="a"}?.resources,6)
        XCTAssertEqual(value.sources[1].trace.finalResources.first{$0.id=="a"}?.resources,4)
        XCTAssertEqual(value.sources[2].trace.finalResources.first{$0.id=="a"}?.resources,6)
    }
    func testLegacyNilSceneEncodingAndValidationStayUnchanged()throws {
        let old=Scene(title:"旧镜头",body:"旧内容")
        let bytes=try Codec.data(old);XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("storyCausality"))
        let decoded=try Codec.decoder().decode(Scene.self,from:bytes);XCTAssertNil(decoded.storyCausality);XCTAssertEqual(try Codec.data(decoded),bytes);try decoded.validate(assets:[])
    }
    func testTamperedTraceWrongSeedAndPartialReplayAreRejected()throws {
        XCTAssertThrowsError(try mutate{$0.sources[0].trace.finalResources[0].resources+=1;_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.sources[0].seed=25;_=$1}.validate(assets:[]))
        var partial=try scene();var value=try XCTUnwrap(partial.storyCausality)
        value.sources[0].trace=try KnowledgeSimulationEngine.record(model:value.sources[0].model,seed:24,throughTick:5);partial.storyCausality=value
        XCTAssertThrowsError(try partial.validate(assets:[]))
    }
    func testCounterfactualRequiresSingleActualParentPlanChange()throws {
        XCTAssertThrowsError(try mutate{$0.sources[1].model.knowledgeLabel="偷偷更改另一输入";_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.sources[1].intervention=$0.sources[0].intervention;_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.sources[1].parentID="rescue";_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.sources[2].parentID=nil;$0.sources[2].intervention=nil;_=$1}.validate(assets:[]))
        var same=try scene();var value=try XCTUnwrap(same.storyCausality);value.sources[1]=try source(value.sources[0].model,id:"refund",start:60,end:120,parent:"base",plan:value.sources[0].model.ruleTable!.plans[0]);same.storyCausality=value
        XCTAssertThrowsError(try same.validate(assets:[]))
    }
    func testBranchWindowsAndCountsAreBoundedAndDisjoint()throws {
        XCTAssertThrowsError(try mutate{$0.sources[1].startFrame=59;_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.sources[2].endFrame=181;_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.sources.append($0.sources[0]);_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.sources[0].id="rescue";_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.version=2;_=$1}.validate(assets:[]))
    }
    func testBindingsRequireDeclaredActionsEventsSubjectsAndAppropriateFields()throws {
        XCTAssertThrowsError(try mutate{$0.bindings[0].actionID="missing";_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.bindings[0].eventID="future";_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.actors[0].subjectID="not-a-layer";_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.actors.append(.init(actorID:"b",subjectID:"cargo-a"));_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.bindings[0].outcome=true;_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$1[0].endFrame=61;_=$0}.validate(assets:[]))
    }
    func testPaymentUsesExactAppliedTransferRouteAmountAndRecipient()throws {
        XCTAssertThrowsError(try mutate{$0.bindings[1].amount=3;$1[1].quantity=3}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.bindings[1].fromActorID="b";_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.bindings[1].eventID="3-清障判定";_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$1[1].targetID="person-b";_=$0}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$1[1].quantity=1;_=$0}.validate(assets:[]))
    }
    func testMoneyPropIsIndependentOfPayerBodyButActualTransferIsNotDuplicated()throws {
        let scene=try scene();try scene.validate(assets:[])
        XCTAssertEqual(scene.storyActions?[1].subjectID,"coin-a")
        XCTAssertThrowsError(try mutate{value,actions in var action=actions[1];action.id="duplicate-money";action.startFrame=55;action.endFrame=59;actions.append(action);var binding=value.bindings[1];binding.actionID=action.id;value.bindings.append(binding)}.validate(assets:[]))
    }
    func testPaymentRequiresSameHouseholdBuyerAndEarlierRealDelivery()throws {
        XCTAssertThrowsError(try mutate{$0.bindings[1].requires=[];_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.bindings[0].actorID="b";_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.bindings[0].toActorID="b";$1[0].targetID="person-b"}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.bindings[1].requires=["delivery-rescue"];_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$1[1].startFrame=34;_=$0}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.bindings[1].eventID="2-收益结算";_=$1}.validate(assets:[]))
    }
    func testDeliveryRequiresActualStateChangeAndOwnedCargo()throws {
        XCTAssertThrowsError(try mutate{$0.bindings[0].fromStateID="sold";_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.bindings[0].ruleID="sale-a";_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$1[0].subjectID="person-b";_=$0}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$1[0].quantity=2;_=$0}.validate(assets:[]))
    }
    func testOneDeliveryTransitionCannotCreateTwoOwnedGoodsForSameOrDifferentRecipients()throws {
        var original=try scene()
        var secondGood=SceneLayer(kind:.rectangle,endFrame:180);secondGood.id="second-cargo-a"
        original.layers!.append(secondGood)
        original.storyCausality!.actors.append(.init(actorID:"a",subjectID:secondGood.id))
        // The same state may have additional visual views; these are not new deliveries.
        for (index,subject) in ["person-a","road"].enumerated() {
            let id="delivery-state-view-\(index)"
            original.storyActions!.append(.init(id:id,kind:.show,subjectID:subject,startFrame:10+index*5,endFrame:15+index*5))
            original.storyCausality!.bindings.append(.init(actionID:id,sourceID:"base",eventID:"2-收益结算",kind:.stateChange,actorID:"a",ruleID:"deliver-a",fromStateID:"loaded",toStateID:"delivered"))
        }
        try original.validate(assets:[])
        for (recipient,target) in [("buyer","buyer"),("b","person-b")] {
            var duplicate=original
            duplicate.storyActions!.append(transfer("second-delivery",secondGood.id,target,35,39,1))
            duplicate.storyCausality!.bindings.append(.init(actionID:"second-delivery",sourceID:"base",eventID:"2-收益结算",kind:.delivery,actorID:"a",ruleID:"deliver-a",toActorID:recipient,fromStateID:"loaded",toStateID:"delivered"))
            XCTAssertThrowsError(try duplicate.validate(assets:[])) {error in
                XCTAssertEqual(error as? VideoError,.invalid("同一次真实交货状态转换不能重复认领为多件货物或不同收货人的交付"))
            }
        }
    }
    func testPerformedActionRejectsRequestedButUnfundedAction()throws {
        var scene=try scene();var value=try XCTUnwrap(scene.storyCausality),model=value.sources[0].model
        model.ruleTable!.actions[0].cost=100
        value.sources=[try source(model,id:"base",start:0,end:180)]
        scene.storyActions=[.init(id:"false-performance",kind:.build,subjectID:"road",startFrame:10,endFrame:20)]
        value.bindings=[.init(actionID:"false-performance",sourceID:"base",eventID:"1-实际出力与扣费",kind:.performedAction,actorID:"a",actionKey:"deliver")];scene.storyCausality=value
        XCTAssertThrowsError(try scene.validate(assets:[]))
    }
    func testActionDependenciesRejectFutureCyclesAndUnboundReferences()throws {
        XCTAssertThrowsError(try mutate{$0.bindings[0].requires=["payment"];_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.bindings[0].requires=["delivery"];_=$1}.validate(assets:[]))
        XCTAssertThrowsError(try mutate{$0.bindings[1].requires=["nonexistent"];_=$1}.validate(assets:[]))
    }
    func testStrictDecodingRejectsUnknownKeysNestedTraceFieldsLegacyAliasesAndVersions()throws {
        let encoded=try Codec.data(try scene().storyCausality!)
        let base=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        func rejected(_ modify:(inout [String:Any])->Void)throws {var object=base;modify(&object);let data=try JSONSerialization.data(withJSONObject:object);XCTAssertThrowsError(try Codec.decoder().decode(StoryCausality.self,from:data))}
        try rejected{$0["version"]=2};try rejected{$0["oldBindings"]=[]};try rejected{$0.removeValue(forKey:"poolSubjectID")}
        try rejected{var sources=$0["sources"] as! [[String:Any]];sources[0]["traceDigest"]="unverified";$0["sources"]=sources}
        try rejected{var sources=$0["sources"] as! [[String:Any]],trace=sources[0]["trace"] as! [String:Any],events=trace["events"] as! [[String:Any]];events[0]["confirmed"]=true;trace["events"]=events;sources[0]["trace"]=trace;$0["sources"]=sources}
        try rejected{var sources=$0["sources"] as! [[String:Any]],model=sources[0]["model"] as! [String:Any];model["unsupportedInput"]=NSNull();sources[0]["model"]=model;$0["sources"]=sources}
        try rejected{var bindings=$0["bindings"] as! [[String:Any]];bindings[0]["kind"]="legacyTransfer";$0["bindings"]=bindings}
        try rejected{var bindings=$0["bindings"] as! [[String:Any]];bindings[0]["amount"]=1.5;$0["bindings"]=bindings}
    }
    func testEditorCausalChangeRemovalAndTimingRevokeReviewsButKeepOriginalVoice()throws {
        var original=try scene();original.captions=[.init(text:original.narration,startFrame:0,endFrame:180,confirmed:true)]
        var audio=Asset(workspaceID:"w",name:"original.wav",hash:String(repeating:"a",count:64),ext:"wav",bytes:44,mediaType:"audio",durationFrames:180)
        audio.id="approved-original";original.voice = .init(assetID:audio.id,textDigest:try original.speechDigest(),durationFrames:180,method:"原音",listened:true)
        let p=project(original)
        for index in 0..<4 {
            var changed=original
            if index==0 {changed.storyCausality!.actors.append(.init(actorID:"b",subjectID:"coin-a"))}
            if index==1 {changed.storyCausality=nil}
            if index==2 {changed.pauseFrames=1}
            if index==3 {changed.speed=1.2}
            let edited=try Editor.apply([.replaceScene(original.id,changed)],to:p,baseRevision:p.current.id,assets:[audio],message:"因果编辑")
            var expected=try XCTUnwrap(original.voice);expected.listened=false
            XCTAssertEqual(edited.current.scenes[0].voice,expected);XCTAssertFalse(edited.current.scenes[0].captions[0].confirmed)
            XCTAssertEqual(edited.revisions[0].scenes[0],original);XCTAssertEqual(try Codec.data(edited.current.review),try Codec.data(Review()))
        }
    }
    func testCausalSceneCannotSplitWithoutReauthoringAndRestoreKeepsVerifiedSources()throws {
        let scene=try scene(),p=project(scene)
        XCTAssertThrowsError(try Editor.apply([.splitScene(scene.id,90)],to:p,baseRevision:p.current.id,assets:[],message:"拒复制因果"))
        var changed=scene;changed.storyCausality=nil
        let edited=try Editor.apply([.replaceScene(scene.id,changed)],to:p,baseRevision:p.current.id,assets:[],message:"移除来源")
        let restored=try Editor.apply([.restore(p.current.id)],to:edited,baseRevision:edited.current.id,assets:[],message:"恢复完整来源")
        XCTAssertEqual(restored.current.scenes[0].storyCausality,scene.storyCausality);try restored.current.scenes[0].validate(assets:[])
    }
    func testPluginPropsNeverLeakHostModelsTracesOrCausalBindings()throws {
        let scene=try scene(),props=PluginVisualProps(scene:scene)
        let encoded=String(decoding:try Codec.data(props),as:UTF8.self)
        for forbidden in ["storyCausality","knowledgeLabel","finalResources","inputDigest","parentID","deliver-a","sale-a"] {XCTAssertFalse(encoded.contains(forbidden),forbidden)}
        XCTAssertEqual(props.storyActions,scene.storyActions)
        let roundTrip=try Codec.decoder().decode(PluginVisualProps.self,from:Codec.data(props))
        XCTAssertNil(roundTrip.drawingScene().storyCausality)
    }
    func testDiscoveryExposesStrictBoundedHostContractWithoutPluginABIChange()throws {
        let definitions=AgentSchemas.definitions()
        XCTAssertNotNil(definitions["Scene"]?.object?["properties"]?.object?["storyCausality"])
        for name in StoryCausalSchema.records.keys {XCTAssertEqual(definitions[name]?.object?["additionalProperties"],.boolean(false))}
        XCTAssertEqual(definitions["StoryCausality"]?.object?["properties"]?.object?["sources"]?.object?["maxItems"],.number(3))
        XCTAssertNotNil(definitions["StoryCausalBindingKind"])
    }

    // These identities are isolated rule fixtures, not decoded media or review evidence.
    private func causalWorldQualityFixture()throws->(Scene,Database) {
        var result=try scene();result.kind = .simulation
        var image=Asset(workspaceID:"w",name:"isolated-map.png",hash:String(repeating:"b",count:64),ext:"png",bytes:100,mediaType:"image")
        let proof=Evidence(workspaceID:"w",title:"隔离规则来源",source:"isolated-causal-world",claim:"仅质量门夹具，不是媒体或审核证据",owner:"isolated-rules",commercialAllowed:false,verified:true,assetID:image.id)
        image.evidenceID=proof.id
        result.classicArtwork=ClassicArtwork(gameplay:.sokoban,sprites:[.init(role:"ground",assetID:image.id),.init(role:"hero",assetID:image.id)],sources:[.init(assetID:image.id,hash:image.hash,source:proof.source,owner:proof.owner,license:"isolated-rules",evidenceID:proof.id)],derivation:.original,originalAssetIDs:[image.id])
        result.gameWorld=GameWorld(width:2,height:2,tiles:Array(repeating:"ground",count:4),entities:[.init(id:"game-hero",name:"勇士",role:"hero",x:0,y:0)])
        let voice=Asset(workspaceID:"w",name:"isolated-original.wav",hash:String(repeating:"a",count:64),ext:"wav",bytes:44,mediaType:"audio",durationFrames:180)
        result.voice = .init(assetID:voice.id,textDigest:try result.speechDigest(),durationFrames:180,method:"isolated-rule-identity",listened:false)
        result.captions=[.init(text:result.narration,startFrame:0,endFrame:180,confirmed:false)]
        var database=Database();database.assets=[image,voice];database.evidence=[proof]
        return(result,database)
    }
    func testCausalWorldPreviewUsesCompleteBranchesWithoutInventingLegacyRecording()throws {
        let (scene,database)=try causalWorldQualityFixture(),before=try Codec.data(scene)
        XCTAssertNil(scene.simulation.knowledge);XCTAssertNil(scene.simulationRecording);XCTAssertNil(scene.simulationRecordingConfirmed)
        let issues=try Quality.inspect(project(scene).current,database:database,requireReview:false,enforceBrandDelivery:false)
        XCTAssertTrue(issues.isEmpty,issues.map(\.message).joined(separator:"；"))
        XCTAssertEqual(try Codec.data(scene),before);XCTAssertFalse(scene.voice!.listened);XCTAssertFalse(scene.captions[0].confirmed)
    }
    func testCausalWorldQualityStillRejectsBadSourcesAndRequiresRightsAndMediaReview()throws {
        let (scene,database)=try causalWorldQualityFixture();var bad=scene
        bad.storyCausality!.sources[0].trace.finalResources[0].resources+=1
        XCTAssertThrowsError(try Quality.inspect(project(bad).current,database:database,requireReview:false,enforceBrandDelivery:false))
        var noRights=database;noRights.evidence=[]
        let rights=try Quality.inspect(project(scene).current,database:noRights,requireReview:false,enforceBrandDelivery:false)
        XCTAssertTrue(rights.contains{$0.id==scene.id+"classic_rights"})
        let review=try Quality.inspect(project(scene).current,database:database,requireReview:true,enforceBrandDelivery:false)
        for identity in [scene.id+"listened",scene.id+"captions","review"] {XCTAssertTrue(review.contains{$0.id==identity},identity)}
        XCTAssertFalse(review.contains{$0.id==scene.id+"simulation_recording"})
        XCTAssertFalse(scene.voice!.listened);XCTAssertFalse(scene.captions[0].confirmed);XCTAssertFalse(project(scene).current.review.complete)
    }
    func testLegacyWorldNonWorldAndMixedSingleSourceKeepOriginalRecordingGate()throws {
        let (scene,database)=try causalWorldQualityFixture()
        for kind in 0..<3 {
            var candidate=scene
            if kind==0 {candidate.storyCausality=nil}
            if kind==1 {candidate.gameWorld=nil;candidate.classicArtwork=nil}
            if kind==2 {candidate.simulation.knowledge=try XCTUnwrap(scene.storyCausality).sources[0].model}
            let issues=try Quality.inspect(project(candidate).current,database:database,requireReview:false,enforceBrandDelivery:false)
            XCTAssertTrue(issues.contains{$0.id==candidate.id+"simulation_recording"},"原门分支 \(kind)")
            XCTAssertNil(candidate.simulationRecording);XCTAssertFalse(candidate.simulationRecordingConfirmed ?? false)
        }
    }

    func testV2ActionCostVerifiesTheCompleteModelAndActualCostConsequences()throws {
        let scene=try costScene();try scene.validate(assets:[])
        let value=try XCTUnwrap(scene.storyCausality),parent=value.sources[0],child=value.sources[1]
        var expected=parent.model;expected.ruleTable!.actions[0].cost=2
        XCTAssertEqual(child.model,expected);XCTAssertEqual(child.actionCost,StoryCausalActionCost(actionID:"deliver",newCost:2));XCTAssertNil(child.intervention)
        XCTAssertEqual(parent.model.ruleTable!.actions[0].cost,1);XCTAssertEqual(parent.seed,child.seed)
        XCTAssertEqual(child.trace.events.count,18);XCTAssertEqual(child.trace.rounds.count,3)
        XCTAssertNotEqual(child.trace.events,parent.trace.events);XCTAssertNotEqual(child.trace.finalResources,parent.trace.finalResources)
        let explanation=try KnowledgeCounterfactualExplanation.build(baseline:parent.model,alternative:child.model,seed:parent.seed)
        XCTAssertEqual(explanation.comparison.baseline,parent.trace);XCTAssertEqual(explanation.comparison.alternative,child.trace)
        XCTAssertEqual(try Codec.decoder().decode(Scene.self,from:Codec.data(scene)),scene)
    }
    func testV2MayRetainLegacyPlanChildrenButV1CannotCarryCosts()throws {
        var result=try costScene(),value=try XCTUnwrap(result.storyCausality)
        var changed=value.sources[1].model;changed.ruleTable!.plans[0].defaultActionID="wait"
        value.sources.append(try source(changed,id:"plan",start:120,end:180,parent:"cost",plan:changed.ruleTable!.plans[0]))
        value.bindings.append(.init(actionID:"plan-action",sourceID:"plan",eventID:"1-实际出力与扣费",kind:.performedAction,actorID:"a",actionKey:"wait"))
        result.durationFrames=180;for index in result.layers!.indices {result.layers![index].endFrame=180}
        result.storyActions!.append(.init(id:"plan-action",kind:.show,subjectID:"person-a",startFrame:125,endFrame:135));result.storyCausality=value
        try result.validate(assets:[])
        value.version=1;result.storyCausality=value
        XCTAssertThrowsError(try result.validate(assets:[]));XCTAssertThrowsError(try Codec.decoder().decode(StoryCausality.self,from:Codec.data(value)))
        var noCost=try scene();noCost.storyCausality!.version=2
        XCTAssertThrowsError(try noCost.validate(assets:[]));XCTAssertThrowsError(try Codec.decoder().decode(StoryCausality.self,from:Codec.data(noCost.storyCausality!)))
    }
    func testActionCostBoundsIdentityNoOpAndMixedDeclarationsAreRejected()throws {
        for cost in [-1,100_001,1] {
            var result=try costScene();result.storyCausality!.sources[1].actionCost!.newCost=cost
            XCTAssertThrowsError(try result.validate(assets:[]),"invalid or unchanged cost \(cost)")
        }
        var unknown=try costScene();unknown.storyCausality!.sources[1].actionCost!.actionID="missing"
        XCTAssertThrowsError(try unknown.validate(assets:[]))
        var mixed=try costScene();mixed.storyCausality!.sources[1].intervention = .init(actorID:"a",plan:mixed.storyCausality!.sources[0].model.ruleTable!.plans[0])
        XCTAssertThrowsError(try mixed.validate(assets:[]));XCTAssertThrowsError(try Codec.decoder().decode(Scene.self,from:Codec.data(mixed)))
        try costScene(oldCost:1,newCost:0).validate(assets:[]);try costScene(oldCost:0,newCost:100_000).validate(assets:[])
    }
    func testCostBranchCannotChangeAnotherInputOrReuseTheOldTrace()throws {
        for kind in 0..<6 {
            var result=try costScene()
            if kind==0 {result.storyCausality!.sources[1].model.knowledgeLabel="隐藏修改"}
            if kind==1 {result.storyCausality!.sources[1].model.ruleTable!.plans[1].defaultActionID="deliver"}
            if kind==2 {result.storyCausality!.sources[1].trace=result.storyCausality!.sources[0].trace}
            if kind==3 {result.storyCausality!.sources[1].seed=25}
            if kind==4 {result.storyCausality!.sources[1].parentID="cost"}
            if kind==5 {result.storyCausality!.sources[1].model.ruleTable!.actions[1].cost=1}
            if [0,1,3,5].contains(kind) {
                let changed=result.storyCausality!.sources[1]
                result.storyCausality!.sources[1].trace=try KnowledgeSimulationEngine.record(model:changed.model,seed:changed.seed,throughTick:changed.model.lastSettlementTick())
            }
            XCTAssertThrowsError(try result.validate(assets:[]),"hidden input, forged trace or parent \(kind)")
        }
        var root=try costScene();root.storyCausality!.sources[0].actionCost = .init(actionID:"deliver",newCost:2)
        XCTAssertThrowsError(try root.validate(assets:[]))
    }
    func testCostBranchRejectsDigestOnlyChangesWithoutObservedConsequences()throws {
        let scene=try costScene(oldCost:0,newCost:1,unused:true),value=try XCTUnwrap(scene.storyCausality)
        XCTAssertNotEqual(value.sources[0].trace.inputDigest,value.sources[1].trace.inputDigest)
        XCTAssertEqual(value.sources[0].trace.events,value.sources[1].trace.events)
        XCTAssertEqual(value.sources[0].trace.rounds,value.sources[1].trace.rounds)
        XCTAssertEqual(value.sources[0].trace.finalResources,value.sources[1].trace.finalResources)
        XCTAssertThrowsError(try scene.validate(assets:[])) {error in XCTAssertEqual((error as? VideoError)?.code,"needs_review")}
    }
    func testCostDecodingRejectsNullHiddenFieldsAndNonIntegerValues()throws {
        let encoded=try Codec.data(try costScene().storyCausality!),base=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        func rejected(_ modify:(inout [String:Any])->Void)throws {var object=base;modify(&object);XCTAssertThrowsError(try Codec.decoder().decode(StoryCausality.self,from:JSONSerialization.data(withJSONObject:object)))}
        try rejected{$0["version"]=3}
        try rejected{var sources=$0["sources"] as! [[String:Any]];sources[1]["actionCost"]=NSNull();$0["sources"]=sources}
        try rejected{var sources=$0["sources"] as! [[String:Any]];sources[1]["intervention"]=NSNull();$0["sources"]=sources}
        let invalidCosts:[Any]=[1.5,true,"2",NSNull(),-1,100_001]
        for value in invalidCosts {
            try rejected{var sources=$0["sources"] as! [[String:Any]],cost=sources[1]["actionCost"] as! [String:Any];cost["newCost"]=value;sources[1]["actionCost"]=cost;$0["sources"]=sources}
        }
        try rejected{var sources=$0["sources"] as! [[String:Any]],cost=sources[1]["actionCost"] as! [String:Any];cost["otherCost"]=2;sources[1]["actionCost"]=cost;$0["sources"]=sources}
        try rejected{var sources=$0["sources"] as! [[String:Any]],cost=sources[1]["actionCost"] as! [String:Any];cost.removeValue(forKey:"newCost");sources[1]["actionCost"]=cost;$0["sources"]=sources}
        try rejected{var sources=$0["sources"] as! [[String:Any]];sources[1]["parameter"]=["actionID":"deliver","newCost":2];$0["sources"]=sources}
    }
    func testLegacyV1WireDigestReplayAndRestoreStayUnchanged()throws {
        let originalScene=try scene(),causality=try XCTUnwrap(originalScene.storyCausality),legacy=LegacyCausality(causality)
        XCTAssertEqual(try Codec.data(causality),try Codec.data(legacy));XCTAssertEqual(try Codec.digest(causality),try Codec.digest(legacy))
        XCTAssertFalse(String(decoding:try Codec.data(causality),as:UTF8.self).contains("actionCost"))
        var legacyScene=try XCTUnwrap(Codec.decoder().decode(AgentValue.self,from:Codec.data(originalScene)).object)
        legacyScene["storyCausality"]=try Codec.decoder().decode(AgentValue.self,from:Codec.data(legacy))
        let sceneBytes=try Codec.data(AgentValue.object(legacyScene));XCTAssertEqual(try Codec.data(originalScene),sceneBytes)
        XCTAssertEqual(try Codec.digest(originalScene),Codec.hash(sceneBytes))
        let original=project(originalScene);var workspace=Workspace(name:"旧v1因果",owner:"owner");workspace.id="w"
        let repository=try Repository(root:FileManager.default.temporaryDirectory.appendingPathComponent("causal-v1-replay-"+UUID().uuidString));defer{try? FileManager.default.removeItem(at:repository.root)}
        try repository.transaction{$0.workspaces=[workspace];$0.projects=[original]}
        let edits=try Codec.decoder().decode(AgentValue.self,from:Codec.data([Edit.replaceScene(originalScene.id,originalScene)]))
        let input=try Codec.data(AgentValue.object(["workspace_id":.string("w"),"project_id":.string(original.id),"base_revision":.string(original.current.id),"edits":edits]))
        let response=try repository.performAgentMutation(command:"edit apply",data:input,principal:"owner",requestID:"legacy-causal-v1")
        let reopened=try Repository(root:repository.root)
        XCTAssertEqual(response,try reopened.performAgentMutation(command:"edit apply",data:input,principal:"owner",requestID:"legacy-causal-v1",origin:.nativeIntent))
        let current=try XCTUnwrap(reopened.read().projects.first)
        XCTAssertEqual(current.revisions.count,2);XCTAssertEqual(try Codec.data(current.revisions[0]),try Codec.data(original.current))
        XCTAssertEqual(try current.revisions[0].contentDigest(),try original.current.contentDigest())
        var without=current.current.scenes[0];without.storyCausality=nil
        let removed=try Editor.apply([.replaceScene(without.id,without)],to:current,baseRevision:current.current.id,assets:[],message:"移除后恢复")
        let restored=try Editor.apply([.restore(original.current.id)],to:removed,baseRevision:removed.current.id,assets:[],message:"恢复完整v1来源")
        XCTAssertEqual(try Codec.data(restored.current.scenes[0]),sceneBytes);XCTAssertEqual(try reopened.read().agentReplayRecords?.count,1);XCTAssertTrue(try reopened.read().jobs.isEmpty)
    }
    func testDiscoveryKeepsBoundedStrictCostAndVersionSpecificPresence()throws {
        let definitions=AgentSchemas.definitions(),source=try XCTUnwrap(definitions["StoryCausalSource"]?.object),cost=try XCTUnwrap(definitions["StoryCausalActionCost"]?.object)
        XCTAssertEqual(source["properties"]?.object?["actionCost"],AgentSchemas.shape("StoryCausalActionCost"))
        XCTAssertNotNil(source["not"]);XCTAssertNotNil(source["allOf"])
        XCTAssertEqual(cost["additionalProperties"],.boolean(false))
        XCTAssertEqual(cost["properties"]?.object?["newCost"]?.object?["minimum"],.number(0));XCTAssertEqual(cost["properties"]?.object?["newCost"]?.object?["maximum"],.number(100_000))
        XCTAssertEqual(definitions["StoryCausality"]?.object?["properties"]?.object?["version"]?.object?["enum"],.array([.number(1),.number(2)]))
        XCTAssertNotNil(definitions["StoryCausality"]?.object?["allOf"])
    }
    func testCostMetadataNeverReachesPluginProps()throws {
        let scene=try costScene(),props=PluginVisualProps(scene:scene)
        var visual=scene;visual.storyCausality=nil
        let bytes=try Codec.data(props);XCTAssertEqual(bytes,try Codec.data(PluginVisualProps(scene:visual)))
        let text=String(decoding:bytes,as:UTF8.self)
        for field in ["actionCost","newCost","storyCausality","inputDigest","finalResources"] {XCTAssertFalse(text.contains(field),field)}
        XCTAssertNil(try Codec.decoder().decode(PluginVisualProps.self,from:bytes).drawingScene().storyCausality)
    }
}
