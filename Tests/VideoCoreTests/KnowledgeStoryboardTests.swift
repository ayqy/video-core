import XCTest
@testable import VideoCore

final class KnowledgeStoryboardTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1_790_000_000)
    private func fixture()throws->(TeachingInput,[Asset],[Evidence],NarrativeTemplate,StyleKit) {
        var material=Asset(workspaceID:"w",name:"知识讲稿.txt",hash:"lesson-source",ext:"txt",bytes:40,mediaType:"text")
        var page=CoursePage(number:1,text:"公共品门槛取决于实际投入，模型不代表现实预测。");page.confirmed=true;material.pages=[page]
        var source=Asset(workspaceID:"w",name:"实际角色原图.png",hash:"original-roles",ext:"png",bytes:50,mediaType:"image")
        var atlas=Asset(workspaceID:"w",name:"实际Q版角色.png",hash:"derived-roles",ext:"png",bytes:60,mediaType:"image")
        var proofs=[material,source,atlas].map { asset in Evidence(workspaceID:"w",title:asset.name,source:"https://example.org/"+asset.id,claim:"实际文件来源与教学用途授权",owner:"素材提供者",commercialAllowed:true,verified:true) }
        for index in proofs.indices {proofs[index].checkedAt=now.addingTimeInterval(-10)}
        material.evidenceID=proofs[0].id;source.evidenceID=proofs[1].id;atlas.evidenceID=proofs[2].id
        let assets=[material,source,atlas]
        let sources=[source,atlas].map{asset->ClassicSource in let proof=proofs.first{$0.id==asset.evidenceID}!;return ClassicSource(assetID:asset.id,hash:asset.hash,source:proof.source,owner:proof.owner,license:"本例明确教学授权",evidenceID:proof.id)}
        let roles=["hero","floor","knowledge_backdrop","obstacle","hero_idle","hero_walk","hero_contribute","hero_success","hero_blocked","hero_walk_alt"]
        let sprites=roles.enumerated().map{ClassicSprite(role:$0.element,assetID:atlas.id,x:Double($0.offset)/10,y:0,width:0.1,height:1)}
        let artwork=ClassicArtwork(gameplay:.platformer,sprites:sprites,sources:sources,derivation:.qStyle,transformation:"从所选原图导出实际动作图块",originalAssetIDs:[source.id])
        let baseline=KnowledgeSimulation(knowledgeLabel:"公共品门槛",resourceLabel:"精力",participants:[KnowledgeParticipant(id:"a",name:"甲",strategy:.contribute),KnowledgeParticipant(id:"b",name:"乙",strategy:.freeRide)],rounds:1,threshold:2)
        var alternative=baseline;alternative.participants[1].strategy = .contribute
        func shots(_ prefix:String)->[KnowledgeStoryboardShot] {
            [.init(id:prefix+"-decision",title:"先作选择",narration:"两人按本轮策略作出选择。",startTick:0,endTickExclusive:2,durationFrames:120,visualSummary:"先观察两人的实际行动"),
             .init(id:prefix+"-rule",title:"按规则观察后果",narration:"实际投入决定是否达到规则门槛。",startTick:2,endTickExclusive:5,durationFrames:180),
             .init(id:prefix+"-result",title:"核对真实结算",narration:"最后核对两人的资源余额。",startTick:5,endTickExclusive:6,durationFrames:90)]
        }
        let plan=KnowledgeStoryboardPlan(baseline:baseline,alternative:alternative,seed:42,artwork:artwork,ruleExplanation:"本例只讨论已声明的公共品门槛模型。",alternativeExplanation:"保留同一种子与参与者，只修改乙的行动策略。",conclusion:"在本模型中，改变实际参与会改变是否清障和最终资源。",baselineShots:shots("before"),alternativeShots:shots("after"))
        let topic=TeachingTopic(workspaceID:"w",name:"公共品小课",audience:"初学者",task:"识别投入与收益",knowledge:page.text,hook:"为什么同一规则会出现不同结果？",outcome:"能核对两份轨迹",prerequisite:"先理解本例单位",proof:"逐步观察选择、投入和结算，不把演绎当现实预测。",boundary:"只适用于已写明的模型规则。",evidenceIDs:proofs.map(\.id))
        var input=TeachingInput(topic:topic,contentContext:ContentContext(workspaceID:"w",name:"公共品小课"),grammar:.simulation,sources:[NarrativeSource(assetID:material.id,pages:[1],excerpt:page.text,confirmed:true)],aspect:.landscape)
        input.knowledgeStoryboard=plan
        return(input,assets,proofs,NarrativeTemplate(workspaceID:"w",name:"知识分镜"),StyleKit(workspaceID:"w",name:"本地教学"))
    }
    private func compose(_ input:TeachingInput,_ assets:[Asset],_ proofs:[Evidence],_ template:NarrativeTemplate,_ style:StyleKit)throws->TeachingDocument {
        try TeachingPlanner.compose(input:input,assets:assets,evidence:proofs,template:template,style:style,now:now)
    }
    private func explicitDebateFixture()throws->(TeachingInput,[Asset],[Evidence],NarrativeTemplate,StyleKit) {
        var(input,assets,proofs,template,style)=try fixture()
        let artwork=input.knowledgeStoryboard!.artwork
        input.knowledgeStoryboard=nil;input.grammar = .debate
        var question=try CartoonPerformance.conversation(durationFrames:90)
        question.beats[0].speakerID="actor-b";question.beats[0].camera = .speaker
        question.beats[0].cues[0].pose = .listen;question.beats[0].cues[1].pose = .object
        question.beats[1].speakerID="actor-a";question.beats[1].camera = .ensemble
        question.beats[1].cues[0].pose = .celebrate;question.beats[1].cues[1].pose = .listen
        let shots=[
            CartoonTeachingShot(id:"question-one",role:.question,title:"先提出疑问",visualSummary:"乙质疑，甲倾听后回应，两人走近。",narration:"不参与是不是一定更好？",durationFrames:90,performance:question),
            CartoonTeachingShot(id:"question-two",role:.question,title:"再确认前提",visualSummary:"核对同一条已声明规则。",narration:"还要先说明适用的规则。",durationFrames:60,performance:try .conversation(durationFrames:60)),
            CartoonTeachingShot(id:"answer",role:.response,title:"依据材料回应",visualSummary:"依次发言后一起观察结果。",narration:"先核对实际投入和结果，不能把本例推广到所有情形。",durationFrames:120,performance:try .conversation(durationFrames:120))]
        input.counterargument=shots.filter{$0.role == .question}.map(\.narration).joined()
        input.response=shots.filter{$0.role == .response}.map(\.narration).joined()
        input.cartoonStoryboard=CartoonTeachingPlan(artwork:artwork,shots:shots)
        template.beats=[TemplateBeat(role:.example,frames:30,motion:true),TemplateBeat(role:.claim,frames:45,motion:true)]
        return(input,assets,proofs,template,style)
    }
    func testSourceBackedKnowledgePlanCreatesActualWindowsAndOneRevisionWithoutGrantingReview()throws {
        let(i,a,e,t,s)=try fixture(),document=try compose(i,a,e,t,s)
        let shots=document.revision.scenes.filter{$0.kind == .simulation}
        XCTAssertEqual(shots.count,6);XCTAssertNil(document.revision.product);XCTAssertEqual(document.revision.schemaVersion,2)
        XCTAssertEqual(shots.map{$0.simulationPresentation?.sourceStartFrame},[0,60,150,0,60,150])
        XCTAssertEqual(shots.map{$0.simulationPresentation?.sourceEndFrame},[60,150,180,60,150,180])
        XCTAssertEqual(shots.map(\.durationFrames),[120,180,90,120,180,90])
        XCTAssertEqual(shots[0].body,"先观察两人的实际行动");XCTAssertNotEqual(shots[0].body,shots[0].narration)
        XCTAssertTrue(shots.allSatisfy{$0.simulation.seed==42 && $0.classicArtwork?.derivation == .qStyle && $0.narrativeSources==i.sources})
        XCTAssertTrue(shots.allSatisfy{$0.voice==nil && $0.simulationRecording==nil && $0.simulationRecordingConfirmed != true})
        XCTAssertTrue(document.beats.contains{$0.role == .claim && $0.text==i.knowledgeStoryboard!.conclusion})
        XCTAssertTrue(document.beats.contains{$0.role == .boundary});XCTAssertFalse(document.confirmed);XCTAssertFalse(document.revision.review.complete)
        let before=try SimulationReplay.record(simulation:shots[0].simulation,throughTick:5),after=try SimulationReplay.record(simulation:shots[3].simulation,throughTick:5)
        XCTAssertNotEqual(before.knowledgeTrace?.rounds.first?.obstacleCleared,after.knowledgeTrace?.rounds.first?.obstacleCleared)
    }
    func testPlanRejectsGapsTruncationDuplicateIDsAndLabelOnlyCounterfactual()throws {
        let(i,_,_,_,_)=try fixture();let original=i.knowledgeStoryboard!
        var plan=original;plan.baselineShots[1].startTick=3;XCTAssertThrowsError(try plan.validate())
        plan=original;plan.baselineShots.removeLast();XCTAssertThrowsError(try plan.validate())
        plan=original;plan.alternativeShots[0].id=plan.baselineShots[0].id;XCTAssertThrowsError(try plan.validate())
        plan=original;plan.alternative=plan.baseline;plan.alternative.knowledgeLabel="只是换一个名称";XCTAssertThrowsError(try plan.validate())
        plan=original;plan.version=2;XCTAssertThrowsError(try plan.validate())
        plan=original;plan.baselineShots[0].durationFrames=Int.max;XCTAssertThrowsError(try plan.validate())
        plan=original;plan.baseline.rounds=16;plan.alternative.rounds=16
        for index in plan.baseline.participants.indices {plan.baseline.participants[index].initialResources=1000;plan.alternative.participants[index].initialResources=1000}
        let end=try plan.baseline.lastSettlementTick()+1
        plan.baselineShots=[.init(id:"short-before",title:"过度压缩",narration:"不能跳过中间事件。",startTick:0,endTickExclusive:end,durationFrames:30)]
        plan.alternativeShots=[.init(id:"short-after",title:"过度压缩",narration:"不能跳过中间事件。",startTick:0,endTickExclusive:end,durationFrames:30)]
        XCTAssertThrowsError(try plan.validate())
    }
    func testOldInputNilEncodingAndConflictingModesStayExplicit()throws {
        var(i,a,e,t,s)=try fixture();i.knowledgeStoryboard=nil
        let data=try Codec.data(i),object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        XCTAssertNil(object["knowledgeStoryboard"]);XCTAssertNil(object["cartoonStoryboard"])
        XCTAssertEqual(try Codec.data(Codec.decoder().decode(TeachingInput.self,from:data)),data)
        i.knowledgeStoryboard=try fixture().0.knowledgeStoryboard;i.grammar = .practice
        XCTAssertThrowsError(try compose(i,a,e,t,s))
        i.grammar = .simulation;i.simulation=Simulation();XCTAssertThrowsError(try compose(i,a,e,t,s))
    }
    func testKnowledgePlanRejectsClockOnlyChangesWhileReadComparisonKeepsThemObservable()throws {
        var(input,assets,proofs,template,style)=try fixture()
        var plan=input.knowledgeStoryboard!
        plan.alternative=plan.baseline
        plan.alternative.startTick=9;plan.alternative.roundTicks=11
        let end=try plan.alternative.lastSettlementTick()+1
        plan.alternativeShots=[.init(id:"after-clock",title:"仅改变展示时间",narration:"参与者和实际行动没有变化。",startTick:0,endTickExclusive:end,durationFrames:end*30)]
        let explanation=try KnowledgeCounterfactualExplanation.build(baseline:plan.baseline,alternative:plan.alternative,seed:plan.seed)
        XCTAssertNotEqual(explanation.comparison.baseline.events,explanation.comparison.alternative.events)
        XCTAssertTrue(explanation.changedEvents.isEmpty);XCTAssertEqual(explanation.timingChanges.count,6)
        XCTAssertEqual(explanation.comparison.balances.map(\.difference),[0,0])
        input.knowledgeStoryboard=plan
        XCTAssertThrowsError(try plan.validate()){error in XCTAssertTrue(error.localizedDescription.contains("实际行动、状态或结算观察差异"))}
        XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
    }
    func testKnowledgePlanRejectsUnreachedThresholdChangesInsteadOfTreatingAnInputAsAnOutcome()throws {
        var(input,assets,proofs,template,style)=try fixture()
        var plan=input.knowledgeStoryboard!
        plan.alternative=plan.baseline;plan.alternative.threshold=3
        let explanation=try KnowledgeCounterfactualExplanation.build(baseline:plan.baseline,alternative:plan.alternative,seed:plan.seed)
        XCTAssertNotEqual(explanation.comparison.baseline.events,explanation.comparison.alternative.events)
        XCTAssertTrue(explanation.changedEvents.isEmpty);XCTAssertTrue(explanation.timingChanges.isEmpty)
        XCTAssertTrue(explanation.comparison.baseline.rounds.allSatisfy{!$0.obstacleCleared})
        XCTAssertTrue(explanation.comparison.alternative.rounds.allSatisfy{!$0.obstacleCleared})
        XCTAssertEqual(explanation.comparison.balances.map(\.difference),[0,0])
        input.knowledgeStoryboard=plan
        XCTAssertThrowsError(try plan.validate()){error in XCTAssertTrue(error.localizedDescription.contains("实际行动、状态或结算观察差异"))}
        XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
    }
    func testKnowledgePlanAcceptsDifferentExecutedActionsWithoutRequiringDifferentFinalBalances()throws {
        var(input,assets,proofs,template,style)=try fixture()
        var plan=input.knowledgeStoryboard!
        let people=plan.baseline.participants.map{person in var value=person;value.strategy = .contribute;return value}
        let table=KnowledgeRuleTable(actions:[.init(id:"act",label:"执行"),.init(id:"wait",label:"等待",pose:.idle)],
            states:[.init(id:"pending",label:"待执行")],
            plans:people.map{.init(actorID:$0.id,initialStateID:"pending",defaultActionID:"act")},
            rules:[.init(id:"later",label:"第二轮才记录",conditions:[.init(kind:.round,minimum:2,maximum:2)],effects:[.setState(actorID:"a",stateID:"pending")])])
        plan.baseline=KnowledgeSimulation(knowledgeLabel:"行动与结果的区别",participants:people,rounds:1,ruleTable:table)
        plan.alternative=plan.baseline;plan.alternative.ruleTable?.plans[0].defaultActionID="wait"
        let explanation=try KnowledgeCounterfactualExplanation.build(baseline:plan.baseline,alternative:plan.alternative,seed:plan.seed)
        XCTAssertEqual(explanation.comparison.balances.map(\.difference),[0,0])
        XCTAssertEqual(explanation.firstOutcomeDifference?.phase,.decision)
        let action=try XCTUnwrap(explanation.changedEvents.first{$0.phase == .contribution})
        XCTAssertEqual(action.baseline.actors.first?.executedActionID,"act")
        XCTAssertEqual(action.alternative.actors.first?.executedActionID,"wait")
        XCTAssertTrue(explanation.comparison.baseline.events.allSatisfy{$0.ruleExecution?.transfers.isEmpty != false})
        input.knowledgeStoryboard=plan
        try plan.validate()
        let document=try compose(input,assets,proofs,template,style)
        XCTAssertEqual(document.revision.scenes.filter{$0.kind == .simulation}.count,6)
        XCTAssertFalse(document.confirmed);XCTAssertFalse(document.revision.review.complete)
    }
    func testKnowledgePlanAcceptsChangedPassageEvenWhenTheModelPaysNoBenefit()throws {
        var(input,assets,proofs,template,style)=try fixture()
        var plan=input.knowledgeStoryboard!
        plan.baseline.benefit=0;plan.baseline.threshold=1
        plan.alternative=plan.baseline;plan.alternative.threshold=2
        let explanation=try KnowledgeCounterfactualExplanation.build(baseline:plan.baseline,alternative:plan.alternative,seed:plan.seed)
        XCTAssertEqual(explanation.comparison.balances.map(\.difference),[0,0])
        XCTAssertEqual(explanation.firstOutcomeDifference?.phase,.resolution)
        XCTAssertTrue(explanation.comparison.baseline.rounds[0].actors.allSatisfy(\.passed))
        XCTAssertTrue(explanation.comparison.alternative.rounds[0].actors.allSatisfy{!$0.passed})
        input.knowledgeStoryboard=plan
        try plan.validate()
        let document=try compose(input,assets,proofs,template,style)
        XCTAssertEqual(document.revision.scenes.filter{$0.kind == .simulation}.count,6)
        XCTAssertFalse(document.confirmed);XCTAssertFalse(document.revision.review.complete)
    }
    private func ruleBehaviorPlan(from original:KnowledgeStoryboardPlan)->KnowledgeStoryboardPlan {
        var plan=original
        let people=plan.baseline.participants.map{person in var value=person;value.strategy = .contribute;return value}
        let table=KnowledgeRuleTable(actions:[.init(id:"act",label:"执行")],states:[.init(id:"open",label:"待交付"),.init(id:"received",label:"已收到",pose:.celebrate)],
            plans:people.map{.init(actorID:$0.id,initialStateID:"open",defaultActionID:"act")},
            rules:[.init(id:"exchange",label:"实际交换",conditions:[.init(kind:.round,minimum:1,maximum:1)],
                effects:[.transfer(from:"a",to:"b",amount:1),.setState(actorID:"b",stateID:"received")])])
        plan.baseline=KnowledgeSimulation(knowledgeLabel:"行动与记录的区别",participants:people,rounds:1,ruleTable:table)
        plan.alternative=plan.baseline
        return plan
    }
    func testKnowledgePlanRejectsRuleAliasesAndConditionOnlyObservationsWhileComparisonRetainsThem()throws {
        let(original,assets,proofs,template,style)=try fixture()
        for change in ["rule-alias","condition-facts"] {
            var input=original,plan=ruleBehaviorPlan(from:original.knowledgeStoryboard!)
            if change=="rule-alias" {plan.alternative.ruleTable?.rules[0].id="renamed-exchange"}
            else {plan.alternative.ruleTable?.rules[0].conditions=[.init(kind:.resources,actorID:"a",minimum:0,maximum:3)]}
            let explanation=try KnowledgeCounterfactualExplanation.build(baseline:plan.baseline,alternative:plan.alternative,seed:plan.seed)
            XCTAssertFalse(explanation.changedEvents.isEmpty,change);XCTAssertFalse(explanation.hasBehaviorDifference,change)
            XCTAssertEqual(explanation.comparison.baseline.events.map(\.actors),explanation.comparison.alternative.events.map(\.actors),change)
            input.knowledgeStoryboard=plan
            XCTAssertThrowsError(try plan.validate(),change)
            XCTAssertThrowsError(try compose(input,assets,proofs,template,style),change)
        }
    }
    func testKnowledgePlanRejectsMatchedNoOpStateWritesWithNoActualStateChange()throws {
        var(input,assets,proofs,template,style)=try fixture()
        var plan=ruleBehaviorPlan(from:input.knowledgeStoryboard!)
        plan.baseline.ruleTable?.rules[0].effects=[.setState(actorID:"a",stateID:"open")]
        plan.alternative=plan.baseline;plan.alternative.ruleTable?.rules[0].conditions=[.init(kind:.round,minimum:2,maximum:2)]
        let explanation=try KnowledgeCounterfactualExplanation.build(baseline:plan.baseline,alternative:plan.alternative,seed:plan.seed)
        XCTAssertFalse(explanation.changedEvents.isEmpty);XCTAssertFalse(explanation.hasBehaviorDifference)
        XCTAssertEqual(explanation.comparison.baseline.events.map(\.actors),explanation.comparison.alternative.events.map(\.actors))
        input.knowledgeStoryboard=plan
        XCTAssertThrowsError(try plan.validate())
        XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
    }
    func testKnowledgePlanRejectsEquivalentParticipantAndRulePlanOrdering()throws {
        var(input,assets,proofs,template,style)=try fixture()
        var plan=ruleBehaviorPlan(from:input.knowledgeStoryboard!)
        plan.alternative.participants.reverse();plan.alternative.ruleTable?.plans.reverse()
        let explanation=try KnowledgeCounterfactualExplanation.build(baseline:plan.baseline,alternative:plan.alternative,seed:plan.seed)
        XCTAssertNotEqual(explanation.comparison.baseline.inputDigest,explanation.comparison.alternative.inputDigest)
        XCTAssertEqual(explanation.comparison.baseline.events,explanation.comparison.alternative.events)
        XCTAssertFalse(explanation.hasBehaviorDifference)
        input.knowledgeStoryboard=plan
        XCTAssertThrowsError(try plan.validate())
        XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
    }
    func testKnowledgePlanAcceptsDifferentActualTransferRoutesWithIdenticalActorsAndBalances()throws {
        var(input,assets,proofs,template,style)=try fixture()
        var plan=ruleBehaviorPlan(from:input.knowledgeStoryboard!)
        let people=["a","b","c"].map{KnowledgeParticipant(id:$0,name:$0,strategy:.contribute,initialResources:3)}
        plan.baseline.participants=people
        plan.baseline.ruleTable?.plans=people.map{.init(actorID:$0.id,initialStateID:"open",defaultActionID:"act")}
        plan.baseline.ruleTable?.rules[0].effects=[.transfer(from:"a",to:"b",amount:1),.transfer(from:"b",to:"c",amount:1),.transfer(from:"c",to:"a",amount:1)]
        plan.alternative=plan.baseline
        plan.alternative.ruleTable?.rules[0].effects=[.transfer(from:"a",to:"c",amount:1),.transfer(from:"c",to:"b",amount:1),.transfer(from:"b",to:"a",amount:1)]
        let explanation=try KnowledgeCounterfactualExplanation.build(baseline:plan.baseline,alternative:plan.alternative,seed:plan.seed)
        XCTAssertTrue(explanation.hasBehaviorDifference)
        XCTAssertEqual(explanation.comparison.baseline.events.map(\.actors),explanation.comparison.alternative.events.map(\.actors))
        XCTAssertEqual(explanation.comparison.balances.map(\.difference),[0,0,0])
        input.knowledgeStoryboard=plan
        try plan.validate()
        let document=try compose(input,assets,proofs,template,style)
        XCTAssertEqual(document.revision.scenes.filter{$0.kind == .simulation}.count,6)
        XCTAssertFalse(document.confirmed);XCTAssertFalse(document.revision.review.complete)
    }
    func testPlanRetainsSourceRightsBoundaryAndRejectsInheritedAudioOffsets()throws {
        var(i,a,e,t,s)=try fixture();i.knowledgeStoryboard!.artwork.audioCues=[ClassicAudioCue(assetID:"source-voice",startFrame:120,durationFrames:90)]
        XCTAssertThrowsError(try compose(i,a,e,t,s))
        i=try fixture().0;a[0].pages[0].confirmed=false;XCTAssertThrowsError(try compose(i,a,e,t,s))
        a[0].pages[0].confirmed=true;a[2].workspaceID="another";XCTAssertThrowsError(try compose(i,a,e,t,s))
    }
    func testDebateUsesRealSelectedCastAndTwoExplicitSpeakers()throws {
        var(i,a,e,t,s)=try fixture();let artwork=i.knowledgeStoryboard!.artwork;i.knowledgeStoryboard=nil;i.grammar = .debate
        i.counterargument="不参与是不是一定更好？";i.response="先核对规则和实际结果，不能把本例推广到所有情形。"
        let actors=[CartoonActor(id:"a",name:"提问者",poseRoles:CartoonActor.dinoRoles),CartoonActor(id:"b",name:"回应者",poseRoles:CartoonActor.dinoRoles)]
        i.cartoonStoryboard=CartoonTeachingPlan(artwork:artwork,actors:actors)
        let document=try compose(i,a,e,t,s),scenes=document.revision.scenes.filter{$0.kind == .cartoon}
        XCTAssertEqual(scenes.count,2);XCTAssertEqual(scenes.map{$0.cartoonPerformance?.beats.first?.speakerID},["a","b"])
        XCTAssertEqual(scenes.map(\.narration),[i.counterargument,i.response]);XCTAssertTrue(scenes.allSatisfy{$0.classicArtwork==artwork && $0.voice==nil})
        for scene in scenes {try scene.cartoonPerformance!.validate(durationFrames:scene.durationFrames,sprites:artwork.sprites)}
        i.cartoonStoryboard!.actors[1].id="a";XCTAssertThrowsError(try compose(i,a,e,t,s))
    }
    func testExplicitDebateRetainsCompleteShotsAndHostSpeechInsteadOfApplyingTemplateTiming()throws {
        let(input,assets,proofs,template,style)=try explicitDebateFixture()
        let plan=try XCTUnwrap(input.cartoonStoryboard),shots=try XCTUnwrap(plan.shots)
        let document=try compose(input,assets,proofs,template,style),scenes=document.revision.scenes.filter{$0.kind == .cartoon}
        XCTAssertEqual(scenes.count,3)
        XCTAssertEqual(scenes.map(\.cartoonPerformance),shots.map{Optional($0.performance)})
        XCTAssertEqual(scenes.map(\.durationFrames),[90,60,120])
        XCTAssertEqual(scenes.map(\.title),shots.map(\.title));XCTAssertEqual(scenes.map(\.body),shots.map(\.visualSummary))
        XCTAssertEqual(scenes.map(\.narration),shots.map(\.narration))
        XCTAssertEqual(scenes[0].cartoonPerformance?.beats.map(\.speakerID),["actor-b","actor-a",nil])
        XCTAssertEqual(scenes[0].cartoonPerformance?.beats.map(\.camera),[.speaker,.ensemble,.ensemble])
        XCTAssertTrue(scenes.allSatisfy{$0.character.isEmpty && $0.keyframes.isEmpty && $0.voice==nil && $0.captions.isEmpty})
        XCTAssertTrue(scenes.allSatisfy{$0.classicArtwork==plan.artwork && $0.narrativeSources==input.sources})
        XCTAssertEqual(document.beats.filter{beat in scenes.contains{$0.id==beat.sceneID}}.map(\.text),shots.map(\.narration))
        XCTAssertFalse(document.confirmed);XCTAssertFalse(document.revision.review.complete)
        for scene in scenes {try scene.validate(assets:assets)}
    }
    func testExplicitDebateRejectsDifferentSpeechMissingViewpointCastAndBrokenPerformance()throws {
        let(original,assets,proofs,template,style)=try explicitDebateFixture()
        var input=original;input.response+=" ";XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
        input=original;input.counterargument="新讲稿不能盲套旧表演";XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
        input=original;input.cartoonStoryboard!.shots!.removeLast();XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
        input=original;input.cartoonStoryboard!.shots![1].performance.actors[0].name="另一角色";XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
        input=original;input.cartoonStoryboard!.shots![0].durationFrames=91;XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
        input=original;input.cartoonStoryboard!.shots![0].performance.beats[1].startFrame+=1;XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
        input=original;input.cartoonStoryboard!.artwork.audioCues=[ClassicAudioCue(assetID:"old-voice",startFrame:0,durationFrames:30)];XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
        input=original;input.cartoonStoryboard!.shots![0].narration="caf\u{00E9}的写法也须保留原字。"
        input.counterargument="cafe\u{0301}的写法也须保留原字。"+input.cartoonStoryboard!.shots![1].narration
        XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
    }
    func testExplicitDebateRejectsReorderedShotsDuplicateIDsAndIncompatibleModeInsteadOfFlattening()throws {
        let(original,assets,proofs,template,style)=try explicitDebateFixture()
        var input=original;input.cartoonStoryboard!.shots!.swapAt(1,2);XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
        input=original;input.cartoonStoryboard!.shots![1].id=input.cartoonStoryboard!.shots![0].id;XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
        input=original;input.cartoonStoryboard!.version=1;XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
        input=original;input.cartoonStoryboard!.version=3;XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
        input=original;input.grammar = .practice;input.steps=["真实步骤"];XCTAssertThrowsError(try compose(input,assets,proofs,template,style))
        XCTAssertThrowsError(try original.cartoonStoryboard!.performance(speakerIndex:0,durationFrames:90))
    }
    func testCartoonPlanCodingKeepsLegacyCastOnlyBytesAndExplicitFullPerformances()throws {
        let(input,_,_,_,_)=try explicitDebateFixture(),explicit=try XCTUnwrap(input.cartoonStoryboard)
        let legacy=CartoonTeachingPlan(artwork:explicit.artwork,actors:explicit.actors),oldData=try Codec.data(legacy)
        let object=try JSONSerialization.jsonObject(with:oldData) as! [String:Any]
        XCTAssertNil(object["shots"]);XCTAssertEqual(object["version"] as? Int,1)
        let decoded=try Codec.decoder().decode(CartoonTeachingPlan.self,from:oldData)
        XCTAssertEqual(try Codec.data(decoded),oldData)
        let oldPerformance=try decoded.performance(speakerIndex:1,durationFrames:90)
        XCTAssertEqual(oldPerformance.actors,legacy.actors);XCTAssertEqual(oldPerformance.beats.count,1)
        XCTAssertEqual(oldPerformance.beats[0].speakerID,legacy.actors[1].id);XCTAssertEqual(oldPerformance.beats[0].camera,.speaker)
        XCTAssertEqual(oldPerformance.beats[0].startFrame,0);XCTAssertEqual(oldPerformance.beats[0].endFrame,90)
        XCTAssertEqual(oldPerformance.beats[0].cues.map(\.pose),[.listen,.speak])
        let data=try Codec.data(explicit),newDecoded=try Codec.decoder().decode(CartoonTeachingPlan.self,from:data)
        XCTAssertEqual(try Codec.data(newDecoded),data);XCTAssertEqual(newDecoded.version,2)
        XCTAssertEqual(newDecoded.shots,explicit.shots)
        try newDecoded.validate(counterargument:input.counterargument,response:input.response)
    }
    func testExplicitCartoonHumanRewriteRetainsPerformanceAndRecordsTheHostNarrationChange()throws {
        let(input,assets,proofs,template,style)=try explicitDebateFixture()
        var document=try compose(input,assets,proofs,template,style)
        let original=try XCTUnwrap(document.revision.scenes.first{$0.kind == .cartoon})
        try document.rewrite(sceneID:original.id,text:"先说明本例规则，再讨论是否参与。",author:"实际作者",reason:"明确前提并重新核对动作",assets:assets,now:now)
        let changed=try XCTUnwrap(document.revision.scenes.first{$0.id==original.id})
        XCTAssertEqual(changed.body,original.body);XCTAssertEqual(changed.cartoonPerformance,original.cartoonPerformance)
        XCTAssertEqual(document.rewrites.last?.before,original.narration);XCTAssertEqual(document.rewrites.last?.after,changed.narration)
        XCTAssertFalse(document.confirmed);XCTAssertFalse(changed.narration==original.narration)
    }
    func testStructuredNarrationRewritePreservesScreenSummaryAndRecordsActualOldSpeech()throws {
        let(i,a,e,t,s)=try fixture();var document=try compose(i,a,e,t,s)
        let scene=document.revision.scenes.first{$0.simulationPresentation != nil}!,summary=scene.body
        try document.rewrite(sceneID:scene.id,text:"先观察甲乙的选择，再核对投入。",author:"作者",reason:"说清先后顺序",assets:a,now:now)
        let changed=document.revision.scenes.first{$0.id==scene.id}!
        XCTAssertEqual(changed.body,summary);XCTAssertEqual(changed.narration,"先观察甲乙的选择，再核对投入。")
        XCTAssertEqual(document.rewrites[0].before,scene.narration);XCTAssertFalse(document.confirmed)
        XCTAssertEqual(changed.simulationPresentation,scene.simulationPresentation)
    }
    func testExplicitVoiceExtensionRetimesActingAndCueTriggerWithoutStretchingAudio()throws {
        var scene=Scene(kind:.cartoon,title:"争论",body:"核对规则",narration:"核对规则",durationFrames:90)
        scene.cartoonPerformance=try .conversation(durationFrames:90)
        var artwork=try fixture().0.knowledgeStoryboard!.artwork
        artwork.audioCues=[ClassicAudioCue(assetID:"effect",startFrame:10,durationFrames:12,gain:0.4,listened:true)];scene.classicArtwork=artwork
        let extended=try StoryboardTiming.extending(scene:scene,to:300)
        XCTAssertEqual(extended.cartoonPerformance?.beats.map(\.startFrame),[0,100,200]);XCTAssertEqual(extended.cartoonPerformance?.beats.map(\.endFrame),[100,200,300])
        XCTAssertEqual(extended.cartoonPerformance?.actors,scene.cartoonPerformance?.actors)
        XCTAssertEqual(extended.classicArtwork?.audioCues[0].startFrame,33);XCTAssertEqual(extended.classicArtwork?.audioCues[0].durationFrames,12)
        XCTAssertEqual(extended.classicArtwork?.audioCues[0].gain,0.4);XCTAssertEqual(extended.classicArtwork?.audioCues[0].listened,false)
        XCTAssertEqual(scene.durationFrames,90);XCTAssertEqual(scene.classicArtwork?.audioCues[0].listened,true)
    }
    func testExplicitVoiceExtensionPreservesVisibleSimulationWindowAndRejectsShrink()throws {
        var scene=Scene(kind:.simulation,title:"结算",body:"只显示本段",durationFrames:90)
        scene.simulationPresentation=SimulationPresentation(sourceStartFrame:150,sourceEndFrame:180,presentationFrames:90)
        let extended=try StoryboardTiming.extending(scene:scene,to:270)
        XCTAssertEqual(try extended.renderSimulationSourceFrame(atTimelineFrame:0),150)
        XCTAssertEqual(try extended.renderSimulationSourceFrame(atTimelineFrame:269),179)
        XCTAssertThrowsError(try StoryboardTiming.extending(scene:scene,to:60));XCTAssertThrowsError(try StoryboardTiming.extending(scene:scene,to:Int.max))
        scene.durationFrames=0;XCTAssertThrowsError(try StoryboardTiming.extending(scene:scene,to:270))
    }
    func testRetimeKeepsAllBeatsNonemptyAndValidatesDuplicateCastBeforeLookup()throws {
        let performance=try CartoonPerformance.conversation(durationFrames:90),retimed=try performance.retimed(from:90,to:3)
        XCTAssertEqual(retimed.beats.map{$0.endFrame-$0.startFrame},[1,1,1])
        XCTAssertEqual(try performance.retimed(from:90,to:90),performance)
        XCTAssertThrowsError(try performance.retimed(from:90,to:2))
        XCTAssertThrowsError(try CartoonPerformance.dialogue(actors:[performance.actors[0],performance.actors[0]],speakerID:performance.actors[0].id,durationFrames:90))
    }
}
