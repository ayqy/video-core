import XCTest
@testable import VideoCore

/// Isolated visual-binding rules; no media, entitlement or human approval is created.
final class KnowledgeParticipantCharacterBindingTests:XCTestCase {
    private let poseKeys=["listen","speak","walk","walkAlternate","object","celebrate"]
    private func fixture()->(Scene,ClassicArtwork,[CartoonActor],[Asset],[Evidence]) {
        let proof=Evidence(workspaceID:"w",title:"隔离角色来源",source:"isolated-character-library",claim:"只核显式角色绑定",owner:"rules",commercialAllowed:false,verified:false)
        var original=Asset(workspaceID:"w",name:"original.png",hash:String(repeating:"a",count:64),ext:"png",bytes:8,mediaType:"image")
        original.evidenceID=proof.id
        var derived=original;derived.id=Codec.id();derived.name="derived.png";derived.hash=String(repeating:"b",count:64)
        let sources=[original,derived].map{ClassicSource(assetID:$0.id,hash:$0.hash,source:proof.source,owner:proof.owner,license:"isolated",evidenceID:proof.id)}
        var sprites=ClassicArtworkRules.requiredRoles(knowledge:true,cartoon:false).union(["hero_walk_alt"]).sorted().map{ClassicSprite(role:$0,assetID:derived.id)}
        let actors=["blue","red"].map{id in CartoonActor(id:id,name:id=="blue" ? "蓝角色":"红角色",poseRoles:Dictionary(uniqueKeysWithValues:poseKeys.map{($0,id+"_"+$0)}))}
        for actor in actors {sprites += poseKeys.enumerated().map{ClassicSprite(role:actor.poseRoles[$0.element]!,assetID:derived.id,x:Double($0.offset%3)/3,y:Double($0.offset/3)/2,width:1.0/3,height:0.5)}}
        let artwork=ClassicArtwork(gameplay:.sokoban,sprites:sprites,sources:sources,derivation:.qStyle,transformation:"隔离不同原件字节",originalAssetIDs:[original.id])
        var scene=Scene(kind:.simulation,title:"同名参与者",body:"明确角色与真实选择分别保存。",durationFrames:180)
        scene.simulation.knowledge=KnowledgeSimulation(knowledgeLabel:"公共品",participants:[
            .init(id:"p-z",name:"同名参与者",strategy:.contribute,initialResources:10),
            .init(id:"p-a",name:"同名参与者",strategy:.freeRide,initialResources:10)],rounds:1)
        return(scene,artwork,actors,[original,derived],[proof])
    }
    private func bind(_ selections:[String:String],_ scene:Scene,_ artwork:ClassicArtwork,_ actors:[CartoonActor],_ assets:[Asset],_ evidence:[Evidence])throws->Scene {
        try ClassicSceneEditing.bindingKnowledgeCharacters(selections,actors:actors,artwork:artwork,to:scene,assets:assets,evidence:evidence,workspaceID:"w")
    }
    func testExplicitIDsWinOverParticipantOrderAndDisplayNames()throws {
        let(scene,artwork,actors,assets,evidence)=fixture(),choices=["p-z":"red","p-a":"blue"]
        let first=try bind(choices,scene,artwork,actors,assets,evidence)
        var reordered=scene;reordered.simulation.knowledge?.participants.reverse()
        let second=try bind(choices,reordered,artwork,Array(actors.reversed()),assets,evidence)
        for value in [first,second] {
            XCTAssertEqual(ClassicSceneEditing.knowledgeCharacterSelections(in:value,actors:actors),choices)
            XCTAssertEqual(value.classicArtwork?.knowledgeParticipants?.first{$0.participantID=="p-z"}?.poseRoles,actors[1].poseRoles)
            XCTAssertEqual(value.classicArtwork?.knowledgeParticipants?.first{$0.participantID=="p-a"}?.poseRoles,actors[0].poseRoles)
        }
        XCTAssertEqual(try Codec.data(first.simulation),try Codec.data(scene.simulation))
        XCTAssertNil(scene.classicArtwork)
        XCTAssertFalse(evidence[0].verified);XCTAssertFalse(evidence[0].commercialAllowed)
    }
    func testMissingUnknownDuplicateAndNonKnowledgeInputsDoNotChangeLegacyDraft()throws {
        var(scene,artwork,actors,assets,evidence)=fixture();scene.classicArtwork=artwork
        let before=try Codec.data(scene)
        for choices in [[String:String](),["p-z":"red"],["p-z":"red","p-a":"missing"],["p-z":"red","p-a":"blue","stale":"blue"]] {
            XCTAssertThrowsError(try bind(choices,scene,artwork,actors,assets,evidence))
        }
        let complete=["p-z":"red","p-a":"blue"]
        XCTAssertThrowsError(try bind(complete,scene,artwork,[actors[0],actors[0]],assets,evidence))
        var changed=scene;changed.simulation.knowledge=nil
        XCTAssertThrowsError(try bind(complete,changed,artwork,actors,assets,evidence))
        changed=scene;changed.kind = .cartoon
        XCTAssertThrowsError(try bind(complete,changed,artwork,actors,assets,evidence))
        changed=scene;changed.locked=true
        XCTAssertThrowsError(try bind(complete,changed,artwork,actors,assets,evidence))
        XCTAssertEqual(try Codec.data(scene),before)
        XCTAssertNil(scene.classicArtwork?.knowledgeParticipants)
        XCTAssertTrue(ClassicSceneEditing.knowledgeCharacterSelections(in:scene,actors:actors).isEmpty)
    }
    func testOnlyExactUnambiguousStoredMappingsAreRestored()throws {
        let(scene,artwork,actors,assets,evidence)=fixture(),choices=["p-z":"red","p-a":"blue"]
        let bound=try bind(choices,scene,artwork,actors,assets,evidence),before=try Codec.data(bound)
        XCTAssertEqual(ClassicSceneEditing.knowledgeCharacterSelections(in:bound,actors:Array(actors.reversed())),choices)
        var alias=actors[0];alias.id="blue-alias"
        let recovered=ClassicSceneEditing.knowledgeCharacterSelections(in:bound,actors:actors+[alias])
        XCTAssertNil(recovered["p-a"]);XCTAssertEqual(recovered["p-z"],"red")
        var renamed=bound;renamed.simulation.knowledge?.participants[0].id="new-participant"
        XCTAssertTrue(ClassicSceneEditing.knowledgeCharacterSelections(in:renamed,actors:actors).isEmpty)
        XCTAssertEqual(try Codec.data(bound),before)
    }
    func testQStyleWorkspaceAndEveryPoseSourceStillApply()throws {
        let(scene,artwork,actors,assets,evidence)=fixture(),choices=["p-z":"red","p-a":"blue"]
        var originalArtwork=artwork;originalArtwork.derivation = .original
        XCTAssertThrowsError(try bind(choices,scene,originalArtwork,actors,assets,evidence))
        for key in poseKeys {
            var changed=artwork
            let index=try XCTUnwrap(changed.sprites.firstIndex{$0.role==actors[0].poseRoles[key]})
            changed.sprites[index].assetID=assets[0].id
            XCTAssertThrowsError(try bind(choices,scene,changed,actors,assets,evidence))
        }
        var incomplete=actors;incomplete[0].poseRoles.removeValue(forKey:"object")
        XCTAssertThrowsError(try bind(choices,scene,artwork,incomplete,assets,evidence))
        var foreignAssets=assets;foreignAssets[1].workspaceID="other"
        XCTAssertThrowsError(try bind(choices,scene,artwork,actors,foreignAssets,evidence))
        var foreignEvidence=evidence;foreignEvidence[0].workspaceID="other"
        XCTAssertThrowsError(try bind(choices,scene,artwork,actors,assets,foreignEvidence))
    }
    func testVisualRebindPreservesRecordingAndOldRevision()throws {
        let(source,artwork,actors,assets,evidence)=fixture()
        var original=try bind(["p-z":"blue","p-a":"red"],source,artwork,actors,assets,evidence)
        original.simulationRecording=try SimulationReplay.record(scene:original)
        original.simulationRecordingConfirmed=false
        let revision=Revision(contentContext:ContentContext(workspaceID:"w",name:"显式角色对应"),aspect:.landscape,scenes:[original])
        let project=Project(workspaceID:"w",name:"保留历史",revision:revision),before=try Codec.data(project)
        let rebound=try bind(["p-z":"red","p-a":"red"],original,artwork,actors,assets,evidence)
        let saved=try Editor.apply([.replaceScene(original.id,rebound)],to:project,baseRevision:revision.id,assets:assets,message:"明确改变一个参与者外观")
        XCTAssertEqual(try Codec.data(project),before);XCTAssertEqual(try Codec.data(saved.revisions[0]),try Codec.data(revision))
        let current=saved.current.scenes[0]
        XCTAssertEqual(try Codec.data(current.simulation),try Codec.data(original.simulation))
        XCTAssertEqual(current.simulationRecording,original.simulationRecording)
        XCTAssertFalse(current.simulationRecordingConfirmed ?? true)
        XCTAssertEqual(try SimulationReplay.record(scene:current),try SimulationReplay.record(scene:original))
        XCTAssertEqual(current.classicArtwork?.knowledgeParticipants?.first{$0.participantID=="p-a"},original.classicArtwork?.knowledgeParticipants?.first{$0.participantID=="p-a"})
        XCTAssertTrue([saved.current.review.text,saved.current.review.rights,saved.current.review.fullPreview,saved.current.review.sound,saved.current.review.captions].allSatisfy{!$0})
    }
    func testExplicitSharedCharacterPreservesOriginalAudioAndVoice()throws {
        var(scene,artwork,actors,assets,evidence)=fixture()
        let proof=Evidence(workspaceID:"w",title:"隔离完整原音",source:"isolated-sound",claim:"原声音字段保持",owner:"rules",commercialAllowed:false,verified:false)
        var audio=Asset(workspaceID:"w",name:"original.wav",hash:String(repeating:"c",count:64),ext:"wav",bytes:8,mediaType:"audio",durationFrames:30)
        audio.evidenceID=proof.id;assets.append(audio);evidence.append(proof)
        var previous=artwork
        previous.sources.append(try ClassicSceneEditing.source(assetID:audio.id,assets:assets,evidence:evidence,workspaceID:"w"))
        previous.audioCues=[ClassicAudioCue(assetID:audio.id,startFrame:45,durationFrames:30,gain:0.3,use:.effect,listened:false)]
        scene.classicArtwork=previous
        scene.characterProfile=CharacterProfile(name:"原角色",evidenceIDs:[proof.id],voiceAssetID:audio.id,original:false)
        let choices=["p-z":"blue","p-a":"blue"],before=try Codec.data(scene)
        let bound=try bind(choices,scene,artwork,actors,assets,evidence)
        XCTAssertEqual(ClassicSceneEditing.knowledgeCharacterSelections(in:bound,actors:actors),choices)
        XCTAssertEqual(bound.classicArtwork?.audioCues,previous.audioCues)
        XCTAssertEqual(bound.classicArtwork?.sources.first{$0.assetID==audio.id},previous.sources.first{$0.assetID==audio.id})
        XCTAssertEqual(bound.characterProfile?.voiceAssetID,audio.id)
        XCTAssertTrue(bound.characterProfile?.evidenceIDs.contains(proof.id) ?? false)
        XCTAssertEqual(bound.voice,scene.voice);XCTAssertEqual(bound.captions,scene.captions)
        XCTAssertEqual(try Codec.data(scene),before)
        XCTAssertFalse(evidence.contains{$0.verified || $0.commercialAllowed})
    }
}

final class ClassicSceneEditingTests:XCTestCase {
    private func fixture()->([Asset],[Evidence]) {
        var images:[Asset]=[];var evidence:[Evidence]=[]
        for index in 0..<2 {
            var asset=Asset(workspaceID:"w",name:"isolated-\(index).png",hash:String(repeating:String(index),count:64),ext:"png",bytes:10,mediaType:"image")
            let e=Evidence(workspaceID:"w",title:"隔离来源\(index)",source:"isolated-source/\(index)",claim:"固定来源，不授予商用",owner:"隔离权利人",commercialAllowed:false,verified:true)
            asset.evidenceID=e.id;images.append(asset);evidence.append(e)
        }
        var audio=Asset(workspaceID:"w",name:"downloaded-cue.wav",hash:String(repeating:"2",count:64),ext:"wav",bytes:10,mediaType:"audio",durationFrames:120)
        let proof=Evidence(workspaceID:"w",title:"隔离原音",source:"isolated-source/sound",claim:"下载原音未听审",owner:"隔离权利人",commercialAllowed:false,verified:true)
        audio.evidenceID=proof.id;images.append(audio);evidence.append(proof)
        return(images,evidence)
    }
    func testActualDifferentDerivativeAndOriginalSourcesAreRequired()throws {
        let (assets,evidence)=fixture()
        XCTAssertThrowsError(try ClassicSceneEditing.derivedAtlas(assetID:assets[0].id,originalAssetIDs:[assets[0].id],gameplay:.sokoban,transformation:"改标签",assets:assets,evidence:evidence,workspaceID:"w"))
        let art=try ClassicSceneEditing.derivedAtlas(assetID:assets[1].id,originalAssetIDs:[assets[0].id],gameplay:.sokoban,transformation:"已有实际编辑图集及原件",assets:assets,evidence:evidence,workspaceID:"w")
        let scene=try ClassicSceneEditing.binding(art,character:"熟悉角色",to:Scene(kind:.simulation,title:"知识",body:"规则仅用于教学"),assets:assets,evidence:evidence,workspaceID:"w")
        XCTAssertEqual(scene.classicArtwork?.derivation,.qStyle)
        XCTAssertEqual(scene.characterProfile?.original,false)
        XCTAssertThrowsError(try ClassicArtworkRules.validateRights(scene:scene,workspaceID:"w",assets:assets,evidence:evidence,commercial:true))
    }
    func testNewMacBindingCannotPromoteOriginalFilesToQProduction()throws {
        let (assets,evidence)=fixture()
        let source=try ClassicSceneEditing.source(assetID:assets[0].id,assets:assets,evidence:evidence,workspaceID:"w")
        let original=ClassicArtwork.quadrants(assetID:assets[0].id,gameplay:.platformer,sources:[source])
        var draft=Scene(kind:.simulation,title:"知识",body:"实际原件")
        draft.simulation.unit=""
        XCTAssertThrowsError(try ClassicSceneEditing.binding(original,character:"熟悉角色原件",to:draft,assets:assets,evidence:evidence,workspaceID:"w",requireQStyle:true))
        let actual=try ClassicSceneEditing.derivedAtlas(assetID:assets[1].id,originalAssetIDs:[assets[0].id],gameplay:.sokoban,transformation:"已有实际处理图集",assets:assets,evidence:evidence,workspaceID:"w")
        let bound=try ClassicSceneEditing.binding(actual,character:"熟悉角色实际派生",to:draft,assets:assets,evidence:evidence,workspaceID:"w",requireQStyle:true)
        XCTAssertEqual(bound.classicArtwork?.derivation,.qStyle)
        XCTAssertTrue(bound.simulation.unit.isEmpty,"素材可先绑定为草稿；不伪造教学规则单位")
    }
    func testSourceCannotBorrowOtherWorkspaceOrUnrelatedAuthorization()throws {
        let (assets,evidence)=fixture()
        XCTAssertThrowsError(try ClassicSceneEditing.source(assetID:assets[0].id,assets:assets,evidence:evidence,workspaceID:"other"))
        XCTAssertThrowsError(try ClassicSceneEditing.source(assetID:assets[0].id,assets:assets,evidence:[],workspaceID:"w"))
    }
    func testDownloadedAudioNeverAutoTruncatesOrBecomesListened()throws {
        let (assets,evidence)=fixture()
        let art=try ClassicSceneEditing.derivedAtlas(assetID:assets[1].id,originalAssetIDs:[assets[0].id],gameplay:.sokoban,transformation:"实际派生",assets:assets,evidence:evidence,workspaceID:"w")
        var scene=Scene(kind:.simulation,title:"知识",body:"示例",durationFrames:60);scene.classicArtwork=art
        XCTAssertThrowsError(try ClassicSceneEditing.addingCue(assetID:assets[2].id,startFrame:30,gain:0.3,use:.prompt,extendScene:false,to:scene,assets:assets,evidence:evidence,workspaceID:"w"))
        let extended=try ClassicSceneEditing.addingCue(assetID:assets[2].id,startFrame:30,gain:0.3,use:.prompt,extendScene:true,to:scene,assets:assets,evidence:evidence,workspaceID:"w")
        XCTAssertEqual(extended.durationFrames,150)
        XCTAssertEqual(extended.classicArtwork?.audioCues.first?.durationFrames,120)
        XCTAssertFalse(extended.classicArtwork?.audioCues.first?.listened ?? true)
        XCTAssertEqual(extended.simulationRecordingConfirmed,false)
    }
    func testAudioExtensionRetainsSourceWindowAndPreviouslyRetimedWholeCues()throws {
        let (assets,evidence)=fixture()
        let art=try ClassicSceneEditing.derivedAtlas(assetID:assets[1].id,originalAssetIDs:[assets[0].id],gameplay:.sokoban,transformation:"实际派生",assets:assets,evidence:evidence,workspaceID:"w")
        var scene=Scene(kind:.simulation,title:"知识",body:"示例",durationFrames:240);scene.classicArtwork=art
        scene.simulationPresentation=SimulationPresentation(sourceStartFrame:60,sourceEndFrame:180,presentationFrames:240)
        scene=try ClassicSceneEditing.addingCue(assetID:assets[2].id,startFrame:30,gain:0.3,use:.effect,extendScene:false,to:scene,assets:assets,evidence:evidence,workspaceID:"w")
        scene.classicArtwork?.audioCues[0].listened=true
        let originalID=try XCTUnwrap(scene.classicArtwork?.audioCues.first?.id)
        let changed=try ClassicSceneEditing.addingCue(assetID:assets[2].id,startFrame:240,gain:0.4,use:.prompt,extendScene:true,to:scene,assets:assets,evidence:evidence,workspaceID:"w")
        XCTAssertEqual(changed.durationFrames,360)
        XCTAssertEqual(try changed.renderSimulationSourceFrame(atTimelineFrame:0),60)
        XCTAssertEqual(try changed.renderSimulationSourceFrame(atTimelineFrame:359),179)
        let cues=try XCTUnwrap(changed.classicArtwork?.audioCues)
        XCTAssertEqual(cues.count,2);XCTAssertEqual(cues[0].id,originalID)
        XCTAssertEqual(cues.map(\.startFrame),[45,240]);XCTAssertEqual(cues.map(\.durationFrames),[120,120])
        XCTAssertTrue(cues.allSatisfy{!$0.listened})
        XCTAssertEqual(changed.simulationRecordingConfirmed,false)
    }
    private func timedCueScene(durationFrames:Int,presentation:SimulationPresentation?,startFrame:Int,cueFrames:Int)throws->Scene {
        let (assets,evidence)=fixture()
        var art=try ClassicSceneEditing.derivedAtlas(assetID:assets[1].id,originalAssetIDs:[assets[0].id],gameplay:.sokoban,transformation:"已有实际派生",assets:assets,evidence:evidence,workspaceID:"w")
        art.sources.append(try ClassicSceneEditing.source(assetID:assets[2].id,assets:assets,evidence:evidence,workspaceID:"w"))
        art.audioCues=[ClassicAudioCue(assetID:assets[2].id,startFrame:startFrame,durationFrames:cueFrames,gain:0.27,use:.prompt,listened:true)]
        var scene=Scene(kind:.simulation,title:"声音与实际动作",body:"完整原音保持对应的源观察",durationFrames:durationFrames)
        scene.classicArtwork=art;scene.simulationPresentation=presentation
        try ClassicArtworkRules.validate(scene:scene,assets:assets)
        return scene
    }
    func testNarrationExtensionKeepsKnowledgeCueOnItsActualSourceFrame()throws {
        let scene=try timedCueScene(durationFrames:330,presentation:.init(sourceStartFrame:0,sourceEndFrame:90,presentationFrames:330),startFrame:222,cueFrames:20)
        let original=try XCTUnwrap(scene.classicArtwork?.audioCues.first),bytes=try Codec.data(scene)
        let extended=try StoryboardTiming.extending(scene:scene,to:660)
        let cue=try XCTUnwrap(extended.classicArtwork?.audioCues.first)
        XCTAssertEqual(try scene.renderSimulationSourceFrame(atTimelineFrame:222),60)
        XCTAssertEqual(try extended.renderSimulationSourceFrame(atTimelineFrame:444),59,"单纯比例会让行动声提前到前一源阶段")
        XCTAssertEqual(cue.startFrame,445)
        XCTAssertEqual(try extended.renderSimulationSourceFrame(atTimelineFrame:cue.startFrame),60)
        var expected=original;expected.startFrame=445;expected.listened=false
        XCTAssertEqual(cue,expected)
        XCTAssertEqual(extended.classicArtwork?.sources,scene.classicArtwork?.sources)
        XCTAssertEqual(try Codec.data(scene),bytes,"只返回待复核新稿，不改原片或授权")
    }
    func testNarrationExtensionRetainsIntentionalDelayWithinHeldSourceFrames()throws {
        let delayed=try timedCueScene(durationFrames:240,presentation:.init(sourceStartFrame:60,sourceEndFrame:180,presentationFrames:240),startFrame:30,cueFrames:20)
        let longer=try StoryboardTiming.extending(scene:delayed,to:360)
        let cue=try XCTUnwrap(longer.classicArtwork?.audioCues.first)
        XCTAssertEqual(cue.startFrame,45,"同源区间43—45中保留比例位置，不强制提前到首次展示")
        XCTAssertEqual(try longer.renderSimulationSourceFrame(atTimelineFrame:43),74)
        XCTAssertEqual(try longer.renderSimulationSourceFrame(atTimelineFrame:cue.startFrame),try delayed.renderSimulationSourceFrame(atTimelineFrame:30))
        let still=try timedCueScene(durationFrames:240,presentation:.init(sourceStartFrame:60,sourceEndFrame:61,presentationFrames:240),startFrame:100,cueFrames:20)
        let held=try StoryboardTiming.extending(scene:still,to:360)
        XCTAssertEqual(held.classicArtwork?.audioCues.first?.startFrame,150,"整段静止画面中的有意停顿不能被折叠到零帧")
    }
    func testNarrationExtensionKeepsCueOnSourceAxisAcrossPlaybackSpeedsAndPause()throws {
        for speed in [0.5,2.0] {
            var scene=try timedCueScene(durationFrames:330,presentation:.init(sourceStartFrame:0,sourceEndFrame:90,presentationFrames:330),startFrame:222,cueFrames:20)
            scene.speed=speed;scene.pauseFrames=30
            let extended=try StoryboardTiming.extending(scene:scene,to:660)
            let cue=try XCTUnwrap(extended.classicArtwork?.audioCues.first)
            XCTAssertEqual(cue.startFrame,445,"原音起点在源轴上，不能再次乘除播放倍率")
            XCTAssertEqual(cue.durationFrames,20);XCTAssertEqual(extended.speed,speed);XCTAssertEqual(extended.pauseFrames,30)
            let firstVideoFrame=Int((Double(cue.startFrame)/speed).rounded(.up))
            XCTAssertEqual(try extended.renderSimulationSourceFrame(atTimelineFrame:firstVideoFrame),60)
            XCTAssertEqual(try extended.renderSimulationSourceFrame(atTimelineFrame:firstVideoFrame-1),59)
            XCTAssertEqual(try extended.renderSimulationSourceFrame(atTimelineFrame:extended.timelineFrames-1),89)
        }
    }
    func testNarrationExtensionKeepsCueSourceInAnAlreadySlicedWindow()throws {
        let window=SimulationPresentation(sourceStartFrame:41,sourceEndFrame:153,presentationFrames:201,presentationOffsetFrames:60)
        for start in [0,20,89] {
            let scene=try timedCueScene(durationFrames:90,presentation:window,startFrame:start,cueFrames:1)
            let extended=try StoryboardTiming.extending(scene:scene,to:180)
            let cue=try XCTUnwrap(extended.classicArtwork?.audioCues.first)
            XCTAssertEqual(try extended.renderSimulationSourceFrame(atTimelineFrame:cue.startFrame),try scene.renderSimulationSourceFrame(atTimelineFrame:start))
            XCTAssertEqual(try extended.renderSimulationSourceFrame(atTimelineFrame:0),try scene.renderSimulationSourceFrame(atTimelineFrame:0))
            XCTAssertEqual(try extended.renderSimulationSourceFrame(atTimelineFrame:179),try scene.renderSimulationSourceFrame(atTimelineFrame:89))
        }
    }
    func testNarrationExtensionRejectsSkippedCueSourceWithoutChangingTheDraft()throws {
        let scene=try timedCueScene(durationFrames:3,presentation:.init(sourceStartFrame:0,sourceEndFrame:7,presentationFrames:3),startFrame:1,cueFrames:1)
        let bytes=try Codec.data(scene)
        XCTAssertEqual(try scene.renderSimulationSourceFrame(atTimelineFrame:1),3)
        XCTAssertThrowsError(try StoryboardTiming.extending(scene:scene,to:4),"新采样仅0、2、4、6，不能把源3的原音移到别的观察")
        XCTAssertEqual(try Codec.data(scene),bytes)
    }
    func testNarrationExtensionRejectsCueTailBeyondReframedSourceEndpoint()throws {
        let scene=try timedCueScene(durationFrames:90,presentation:.init(sourceStartFrame:0,sourceEndFrame:4,presentationFrames:100),startFrame:70,cueFrames:20)
        let bytes=try Codec.data(scene)
        XCTAssertEqual(try scene.renderSimulationSourceFrame(atTimelineFrame:70),2)
        XCTAssertThrowsError(try StoryboardTiming.extending(scene:scene,to:180),"新源窗口的源2仅出现在末帧，不能为了容纳20帧声音提前到源1或截尾")
        XCTAssertEqual(try Codec.data(scene),bytes)
    }
    func testNarrationExtensionPreservesOrdinaryCueTimingAndRejectsMalformedArithmetic()throws {
        let scene=try timedCueScene(durationFrames:240,presentation:nil,startFrame:30,cueFrames:120)
        let extended=try StoryboardTiming.extending(scene:scene,to:360)
        XCTAssertEqual(extended.classicArtwork?.audioCues.first?.startFrame,45)
        XCTAssertEqual(extended.classicArtwork?.audioCues.first?.durationFrames,120)
        for start in [Int.min,-1,240,Int.max] {
            var invalid=scene;invalid.classicArtwork?.audioCues[0].startFrame=start
            XCTAssertThrowsError(try StoryboardTiming.extending(scene:invalid,to:360))
        }
        var invalid=scene;invalid.classicArtwork?.audioCues[0].durationFrames=Int.max
        XCTAssertThrowsError(try StoryboardTiming.extending(scene:invalid,to:360))
    }
    func testSplitKeepsWholeAudioCuesOnTheirOwnSideAndRetimesTheRight()throws {
        var (assets,evidence)=fixture();assets[2].durationFrames=30
        var scene=try characterScene(assets:assets,evidence:evidence);scene.durationFrames=240
        scene.classicArtwork?.sources.append(try ClassicSceneEditing.source(assetID:assets[2].id,assets:assets,evidence:evidence,workspaceID:"w"))
        let cues=[ClassicAudioCue(assetID:assets[2].id,startFrame:10,durationFrames:30,gain:0.2,use:.effect,listened:true),
                  ClassicAudioCue(assetID:assets[2].id,startFrame:90,durationFrames:30,gain:0.4,use:.prompt,listened:true),
                  ClassicAudioCue(assetID:assets[2].id,startFrame:120,durationFrames:30,gain:0.3,use:.prompt,listened:true),
                  ClassicAudioCue(assetID:assets[2].id,startFrame:180,durationFrames:30,gain:0.5,use:.effect,listened:true)]
        scene.classicArtwork?.audioCues=cues
        scene.captions=[Caption(text:"拆分前后字幕重新核对",startFrame:90,endFrame:150,confirmed:true)]
        var (_,project)=versionDatabase(scene:scene,assets:assets,evidence:evidence)
        project.revisions[0].review.text=true;project.revisions[0].review.rights=true;project.revisions[0].review.fullPreview=true;project.revisions[0].review.sound=true;project.revisions[0].review.captions=true;project.revisions[0].review.digest="original-review"
        let before=try Codec.data(project),originalRevision=project.current
        let changed=try Editor.apply([.splitScene(scene.id,120)],to:project,baseRevision:originalRevision.id,assets:assets,message:"在完整原音之间拆分")
        XCTAssertEqual(changed.current.scenes.map(\.durationFrames),[120,120])
        let left=try XCTUnwrap(changed.current.scenes[0].classicArtwork),right=try XCTUnwrap(changed.current.scenes[1].classicArtwork)
        XCTAssertEqual(left.audioCues.map(\.id),Array(cues.prefix(2)).map(\.id));XCTAssertEqual(right.audioCues.map(\.id),Array(cues.suffix(2)).map(\.id))
        XCTAssertEqual(left.audioCues.map(\.startFrame),[10,90]);XCTAssertEqual(right.audioCues.map(\.startFrame),[0,60])
        for (index,cue) in (left.audioCues+right.audioCues).enumerated() {
            XCTAssertEqual(cue.assetID,cues[index].assetID);XCTAssertEqual(cue.durationFrames,30);XCTAssertEqual(cue.gain,cues[index].gain);XCTAssertEqual(cue.use,cues[index].use);XCTAssertFalse(cue.listened)
        }
        XCTAssertEqual(left.sources,scene.classicArtwork?.sources);XCTAssertEqual(right.sources,scene.classicArtwork?.sources)
        XCTAssertEqual(left.sprites,scene.classicArtwork?.sprites);XCTAssertEqual(right.sprites,scene.classicArtwork?.sprites)
        XCTAssertEqual(changed.current.scenes[0].captions[0].endFrame,120);XCTAssertEqual(changed.current.scenes[1].captions[0].startFrame,0);XCTAssertEqual(changed.current.scenes[1].captions[0].endFrame,30)
        XCTAssertFalse(changed.current.scenes[0].captions[0].confirmed);XCTAssertFalse(changed.current.scenes[1].captions[0].confirmed)
        XCTAssertFalse(changed.current.review.sound);XCTAssertFalse(changed.current.review.fullPreview);XCTAssertFalse(changed.current.review.captions);XCTAssertNil(changed.current.review.digest)
        XCTAssertTrue(changed.current.invalidated.contains("声音确认"));XCTAssertTrue(changed.revisions[0].review.complete)
        XCTAssertEqual(changed.revisions[0].scenes[0],scene);XCTAssertEqual(try Codec.data(project),before)
        for value in changed.current.scenes {try value.validate(assets:assets)}
    }
    func testSplitRejectsAnyCueCrossingTheBoundaryWithoutTruncationEvenWhenSilent()throws {
        var (assets,evidence)=fixture();assets[2].durationFrames=30
        var source=try characterScene(assets:assets,evidence:evidence);source.durationFrames=240
        source.classicArtwork?.sources.append(try ClassicSceneEditing.source(assetID:assets[2].id,assets:assets,evidence:evidence,workspaceID:"w"))
        for use in ClassicAudioCue.Use.allCases {for gain in [0.0,0.35] {for muted in [false,true] {
            var scene=source;scene.muted=muted
            scene.classicArtwork?.audioCues=[ClassicAudioCue(assetID:assets[2].id,startFrame:105,durationFrames:30,gain:gain,use:use,listened:true)]
            let (_,project)=versionDatabase(scene:scene,assets:assets,evidence:evidence),before=try Codec.data(project)
            try scene.validate(assets:assets)
            XCTAssertThrowsError(try Editor.apply([.splitScene(scene.id,120)],to:project,baseRevision:project.current.id,assets:assets,message:"不得截断原音")) { error in
                XCTAssertEqual((error as? VideoError)?.code,"needs_review")
                XCTAssertTrue(error.localizedDescription.contains("不会自动截断原音"))
            }
            XCTAssertEqual(try Codec.data(project),before)
        }}}
    }
    func testSplitRejectsMalformedCueBeforeFrameArithmetic()throws {
        let (assets,evidence)=fixture();var scene=try characterScene(assets:assets,evidence:evidence)
        scene.classicArtwork?.sources.append(try ClassicSceneEditing.source(assetID:assets[2].id,assets:assets,evidence:evidence,workspaceID:"w"))
        scene.classicArtwork?.audioCues=[ClassicAudioCue(assetID:assets[2].id,startFrame:Int.max,durationFrames:120)]
        let (_,project)=versionDatabase(scene:scene,assets:assets,evidence:evidence)
        XCTAssertThrowsError(try Editor.apply([.splitScene(scene.id,60)],to:project,baseRevision:project.current.id,assets:assets,message:"拒绝无效音效位置")) {error in XCTAssertEqual((error as? VideoError)?.code,"invalid_input")}
    }
    func testSameTickClampingUsesTheSameCausalInputOrderInSDKAndRecording()throws {
        var simulation=Simulation();simulation.initial=5;simulation.capacity=10;simulation.unit="箱"
        var first=RuleEvent(tick:1,delta:20,label:"先增加");first.id="z-first"
        var second=RuleEvent(tick:1,delta:-10,label:"后减少");second.id="a-second"
        simulation.events=[first,second]
        let trace=try SimulationReplay.record(simulation:simulation,throughTick:1)
        XCTAssertEqual(trace.transitions.map(\.after),[10,0])
        XCTAssertEqual(try simulation.state(at:1),trace.finalState)
        XCTAssertEqual(try SimulationReplay.frameState(simulation:simulation,frame:30).value,0)
        XCTAssertEqual(trace.transitions.map(\.clippedDelta),[15,0])
    }
    private func characterScene(assets:[Asset],evidence:[Evidence])throws->Scene {
        let artwork=try ClassicSceneEditing.derivedAtlas(assetID:assets[1].id,originalAssetIDs:[assets[0].id],gameplay:.sokoban,transformation:"已存在的实际派生过程",assets:assets,evidence:evidence,workspaceID:"w")
        return try ClassicSceneEditing.binding(artwork,character:"熟悉角色",to:Scene(kind:.cartoon,title:"角色讲解",body:"明确的教学内容"),assets:assets,evidence:evidence,workspaceID:"w",requireQStyle:true)
    }
    private func versionDatabase(scene:Scene,assets:[Asset],evidence:[Evidence])->(Database,Project) {
        var workspace=Workspace(name:"实际工作区",owner:"actual-owner");workspace.id="w"
        let revision=Revision(contentContext:ContentContext(workspaceID:"w",name:"历史角色"),aspect:.landscape,scenes:[scene])
        let project=Project(workspaceID:"w",name:"实际角色来源",revision:revision)
        var database=Database();database.workspaces=[workspace];database.assets=assets;database.evidence=evidence;database.projects=[project]
        return(database,project)
    }
    func testExpressionUsesAnActualBoundDerivativeAndKeepsOtherSceneData()throws {
        let (assets,evidence)=fixture();var original=try characterScene(assets:assets,evidence:evidence)
        original.kind = .simulation;original.simulationRecording=try SimulationReplay.record(scene:original);original.simulationRecordingConfirmed=true
        original.classicArtwork?.audioCues=[ClassicAudioCue(assetID:assets[2].id,startFrame:0,durationFrames:120,listened:false)]
        original.classicArtwork?.sources.append(try ClassicSceneEditing.source(assetID:assets[2].id,assets:assets,evidence:evidence,workspaceID:"w"))
        let before=try Codec.data(original)
        let expression=ClassicSprite(role:"惊喜",assetID:assets[1].id,x:0.5,y:0,width:0.5,height:0.5)
        let changed=try ClassicSceneEditing.settingExpressionSprite(expression,to:original,assets:assets,evidence:evidence,workspaceID:"w",commercial:false)
        XCTAssertEqual(changed.classicArtwork?.sprites.first{$0.role=="惊喜"},expression)
        XCTAssertEqual(changed.classicArtwork?.sprites.filter{$0.role != "惊喜"},original.classicArtwork?.sprites)
        XCTAssertEqual(changed.characterProfile?.expressions.last,"惊喜");XCTAssertEqual(changed.emotion,"惊喜")
        XCTAssertEqual(changed.classicArtwork?.audioCues,original.classicArtwork?.audioCues)
        XCTAssertEqual(changed.durationFrames,original.durationFrames);XCTAssertEqual(changed.simulation,original.simulation)
        XCTAssertEqual(changed.simulationRecording,original.simulationRecording);XCTAssertEqual(changed.simulationRecordingConfirmed,true)
        XCTAssertEqual(changed.title,original.title);XCTAssertEqual(changed.body,original.body)
        XCTAssertEqual(try Codec.data(original),before)
        XCTAssertThrowsError(try ClassicArtworkRules.validateRights(scene:changed,workspaceID:"w",assets:assets,evidence:evidence,commercial:true))
    }
    func testExpressionRejectsOriginalUnboundReservedAndInvalidCropWithoutRelabelling()throws {
        let (baseAssets,baseEvidence)=fixture();let original=try characterScene(assets:baseAssets,evidence:baseEvidence)
        var unbound=baseAssets[1];unbound.id=Codec.id();unbound.hash=String(repeating:"3",count:64)
        let assets=baseAssets+[unbound]
        let candidates=[ClassicSprite(role:"惊喜",assetID:assets[0].id),ClassicSprite(role:"惊喜",assetID:unbound.id),
                        ClassicSprite(role:"hero",assetID:assets[1].id),ClassicSprite(role:"floor",assetID:assets[1].id),
                        ClassicSprite(role:"惊喜",assetID:assets[1].id,x:0.8,width:0.3),
                        ClassicSprite(role:"惊喜",assetID:assets[1].id,width:Double.nan),
                        ClassicSprite(role:"惊\n喜",assetID:assets[1].id)]
        for sprite in candidates {XCTAssertThrowsError(try ClassicSceneEditing.settingExpressionSprite(sprite,to:original,assets:assets,evidence:baseEvidence,workspaceID:"w",commercial:false))}
        var locked=original;locked.locked=true
        XCTAssertThrowsError(try ClassicSceneEditing.settingExpressionSprite(ClassicSprite(role:"惊喜",assetID:assets[1].id),to:locked,assets:assets,evidence:baseEvidence,workspaceID:"w",commercial:false))
        XCTAssertThrowsError(try ClassicSceneEditing.settingExpressionSprite(ClassicSprite(role:"惊喜",assetID:assets[1].id),to:original,assets:assets,evidence:baseEvidence,workspaceID:"other",commercial:false))
    }
    func testExpressionReplacementIsUniqueAndCurrentRightsRemainRequired()throws {
        let (assets,evidence)=fixture();let original=try characterScene(assets:assets,evidence:evidence)
        let expression=ClassicSprite(role:"思考",assetID:assets[1].id,x:0,y:0,width:0.5,height:0.5)
        let first=try ClassicSceneEditing.settingExpressionSprite(expression,to:original,assets:assets,evidence:evidence,workspaceID:"w",commercial:false)
        let replacement=ClassicSprite(role:"思考",assetID:assets[1].id,x:0.5,y:0,width:0.5,height:0.5)
        let next=try ClassicSceneEditing.settingExpressionSprite(replacement,to:first,assets:assets,evidence:evidence,workspaceID:"w",commercial:false)
        XCTAssertEqual(next.classicArtwork?.sprites.filter{$0.role=="思考"},[replacement])
        XCTAssertEqual(next.characterProfile?.expressions.filter{$0=="思考"}.count,1)
        var expired=evidence;expired[1].expiresAt=Date().addingTimeInterval(-1)
        XCTAssertThrowsError(try ClassicSceneEditing.settingExpressionSprite(expression,to:original,assets:assets,evidence:expired,workspaceID:"w",commercial:false))
        var changed=evidence;changed[1].source="unrelated-source"
        XCTAssertThrowsError(try ClassicSceneEditing.settingExpressionSprite(expression,to:original,assets:assets,evidence:changed,workspaceID:"w",commercial:false))
    }
    func testHistoricalCharacterReuseUsesExactAuthorizedVersionAndKeepsHistory()throws {
        let (assets,evidence)=fixture();var source=try characterScene(assets:assets,evidence:evidence)
        source.characterProfile?.actions=["原版本点头"]
        var (database,project)=versionDatabase(scene:source,assets:assets,evidence:evidence)
        let revisionID=project.current.id
        var newer=project.current;newer.id=Codec.id();newer.parentID=revisionID;newer.number+=1;newer.scenes[0].characterProfile?.actions=["新版本跳跃"]
        project.revisions.append(newer);database.projects=[project]
        let sourceBefore=try Codec.data(project)
        var target=try characterScene(assets:assets,evidence:evidence);target.title="目标自己的标题";target.durationFrames=210;target.narration="自己的旁白";target.simulation.seed=99
        let result=try ClassicSceneEditing.reusingVisualCharacter(projectID:project.id,revisionID:revisionID,sceneID:source.id,to:target,access:WorkspaceAccessContext(workspaceID:"w",principal:"actual-owner"),database:database,commercial:false)
        XCTAssertEqual(result.characterProfile?.actions,["原版本点头"])
        XCTAssertEqual(result.title,target.title);XCTAssertEqual(result.narration,target.narration);XCTAssertEqual(result.durationFrames,target.durationFrames);XCTAssertEqual(result.simulation,target.simulation)
        for id in [project.id,revisionID,source.id]{XCTAssertTrue(result.classicArtwork?.transformation.contains(id)==true)}
        XCTAssertEqual(try Codec.data(project),sourceBefore)
        let reopened=try Codec.decoder().decode(Scene.self,from:Codec.data(result))
        XCTAssertEqual(reopened,result)
    }
    func testHistoricalReuseRequiresActualScopedReadAndCurrentPurposeRights()throws {
        let (assets,evidence)=fixture();let source=try characterScene(assets:assets,evidence:evidence)
        var (database,project)=versionDatabase(scene:source,assets:assets,evidence:evidence)
        let revisionID=project.current.id,target=try characterScene(assets:assets,evidence:evidence)
        func apply(_ principal:String,_ value:Database,_ commercial:Bool=false)throws->Scene {try ClassicSceneEditing.reusingVisualCharacter(projectID:project.id,revisionID:revisionID,sceneID:source.id,to:target,access:WorkspaceAccessContext(workspaceID:"w",principal:principal),database:value,commercial:commercial)}
        XCTAssertThrowsError(try apply("ungranted-name",database))
        var grant=Grant(principal:"scoped-reader",role:.reviewer,projectIDs:[project.id],revisionIDs:[revisionID],expiresAt:Date().addingTimeInterval(60))
        database.workspaces[0].grants=[grant];XCTAssertNoThrow(try apply("scoped-reader",database))
        grant.revoked=true;database.workspaces[0].grants=[grant];XCTAssertThrowsError(try apply("scoped-reader",database))
        grant.revoked=false;grant.expiresAt=Date().addingTimeInterval(-1);database.workspaces[0].grants=[grant];XCTAssertThrowsError(try apply("scoped-reader",database))
        XCTAssertThrowsError(try apply("actual-owner",database,true))
        var expired=database;expired.evidence[1].expiresAt=Date().addingTimeInterval(-1);XCTAssertThrowsError(try apply("actual-owner",expired))
        var foreign=database;foreign.assets[1].workspaceID="other";XCTAssertThrowsError(try apply("actual-owner",foreign))
        XCTAssertThrowsError(try ClassicSceneEditing.reusingVisualCharacter(projectID:project.id,revisionID:"unknown",sceneID:source.id,to:target,access:WorkspaceAccessContext(workspaceID:"w",principal:"actual-owner"),database:database,commercial:false))
    }
    func testVisualReuseDoesNotCopySourceAudioListeningOrReview()throws {
        var (assets,evidence)=fixture();var targetAudio=assets[2];targetAudio.id=Codec.id();targetAudio.hash=String(repeating:"4",count:64)
        var targetProof=evidence[2];targetProof.id=Codec.id();targetProof.source="isolated-target-sound";targetAudio.evidenceID=targetProof.id;assets.append(targetAudio);evidence.append(targetProof)
        var source=try characterScene(assets:assets,evidence:evidence)
        source=try ClassicSceneEditing.addingCue(assetID:assets[2].id,startFrame:0,gain:0.4,use:.prompt,extendScene:false,to:source,assets:assets,evidence:evidence,workspaceID:"w")
        source.classicArtwork?.audioCues[0].listened=true;source.characterProfile?.voiceAssetID=assets[2].id
        var (database,project)=versionDatabase(scene:source,assets:assets,evidence:evidence)
        project.revisions[0].review.text=true;project.revisions[0].review.rights=true;project.revisions[0].review.fullPreview=true;project.revisions[0].review.sound=true;project.revisions[0].review.captions=true;project.revisions[0].review.digest="isolated-reviewed-source";database.projects=[project]
        var target=try characterScene(assets:assets,evidence:evidence)
        target=try ClassicSceneEditing.addingCue(assetID:targetAudio.id,startFrame:0,gain:0.2,use:.effect,extendScene:false,to:target,assets:assets,evidence:evidence,workspaceID:"w")
        target.characterProfile?.voiceAssetID=targetAudio.id
        target.voice=VoiceTake(assetID:targetAudio.id,textDigest:"target-text",durationFrames:120,method:"existing-target",listened:false)
        let result=try ClassicSceneEditing.reusingVisualCharacter(projectID:project.id,revisionID:project.current.id,sceneID:source.id,to:target,access:WorkspaceAccessContext(workspaceID:"w",principal:"actual-owner"),database:database,commercial:false)
        XCTAssertEqual(result.classicArtwork?.audioCues,target.classicArtwork?.audioCues)
        XCTAssertEqual(result.characterProfile?.voiceAssetID,targetAudio.id);XCTAssertEqual(result.voice,target.voice)
        XCTAssertFalse(result.classicArtwork?.sources.contains{$0.assetID==assets[2].id} ?? true)
        var untouched=Scene(title:"已锁定的其他镜头",body:"保持原画面");untouched.locked=true
        let originalRevision=Revision(contentContext:ContentContext(workspaceID:"w",name:"目标"),aspect:.landscape,scenes:[target,untouched])
        let targetProject=Project(workspaceID:"w",name:"目标",revision:originalRevision)
        let saved=try Editor.apply([.replaceScene(target.id,result)],to:targetProject,baseRevision:originalRevision.id,assets:assets,message:"复用明确角色版本")
        XCTAssertEqual(saved.revisions.count,2);XCTAssertEqual(saved.revisions[0].scenes[0],target)
        XCTAssertEqual(saved.current.scenes[1],untouched)
        XCTAssertFalse(saved.current.review.complete);XCTAssertTrue(project.current.review.complete)
        var locked=target;locked.locked=true
        XCTAssertThrowsError(try ClassicSceneEditing.reusingVisualCharacter(projectID:project.id,revisionID:project.current.id,sceneID:source.id,to:locked,access:WorkspaceAccessContext(workspaceID:"w",principal:"actual-owner"),database:database,commercial:false))
    }
}

final class KnowledgeSoundTests:XCTestCase {
    private func scene()throws->Scene {
        var s=Scene(kind:.simulation,title:"公共品",body:"实际选择与后果",durationFrames:180)
        s.simulation.knowledge=KnowledgeSimulation(knowledgeLabel:"公共品",participants:[
            .init(id:"a",name:"甲",strategy:.contribute),.init(id:"b",name:"乙",strategy:.freeRide)
        ],rounds:1,threshold:1)
        s.simulationRecording=try SimulationReplay.record(scene:s)
        return s
    }
    private func tableScene()throws->Scene {
        var s=try scene()
        s.simulation.knowledge=KnowledgeSimulation(knowledgeLabel:"交易条件",participants:[
            .init(id:"a",name:"甲",strategy:.contribute,initialResources:4),.init(id:"b",name:"乙",strategy:.contribute,initialResources:4)
        ],rounds:1,ruleTable:KnowledgeRuleTable(
            actions:[.init(id:"act",label:"提交",cost:1,pose:.act)],
            states:[.init(id:"open",label:"待定"),.init(id:"closed",label:"达成",pose:.celebrate)],
            plans:["a","b"].map{.init(actorID:$0,initialStateID:"open",defaultActionID:"act")},
            rules:[.init(id:"match",label:"双方提交后",conditions:[.init(kind:.actionCount,actionID:"act",minimum:2,maximum:2)],effects:[.transfer(from:nil,to:"a",amount:1),.setState(actorID:"a",stateID:"closed")])]))
        s.simulationRecording=try SimulationReplay.record(scene:s)
        return s
    }
    func testPublicGoodsOnlyActualContributionsAndSettledBenefitsProduceMoments()throws {
        let s=try scene(), moments=try ClassicSceneEditing.knowledgeSoundMoments(scene:s)
        XCTAssertEqual(moments.map(\.kind),[.action,.outcome]);XCTAssertEqual(moments.map(\.sourceTick),[2,5])
        XCTAssertEqual(moments.map(\.sceneFrame),[60,150])
        XCTAssertTrue(moments[0].summary.contains("甲"));XCTAssertFalse(moments[0].summary.contains("乙"))
        XCTAssertFalse(s.simulationRecordingConfirmed ?? false)
        var constrained=s;constrained.simulation.knowledge?.participants[0].initialResources=0
        constrained.simulationRecording=try SimulationReplay.record(scene:constrained)
        let blocked=try ClassicSceneEditing.knowledgeSoundMoments(scene:constrained)
        XCTAssertEqual(blocked.map(\.kind),[.constrained,.outcome]);XCTAssertEqual(blocked.map(\.sceneFrame),[30,150])
        XCTAssertTrue(blocked[1].summary.contains("未达共享门槛1"))
    }
    private func failedPublicGoodsScene(rounds:Int=2)throws->Scene {
        var s=try scene();s.durationFrames=rounds*180
        s.simulation.knowledge=KnowledgeSimulation(knowledgeLabel:"共享通路的门槛与参与",resourceLabel:"精力",participants:[
            .init(id:"actor-a",name:"甲",strategy:.contribute,initialResources:5),
            .init(id:"actor-b",name:"乙",strategy:.contribute,initialResources:5),
            .init(id:"actor-c",name:"丙",strategy:.freeRide,initialResources:5)
        ],rounds:rounds,threshold:3)
        s.simulation.seed=24
        s.simulationPresentation=SimulationPresentation(sourceStartFrame:0,sourceEndFrame:s.durationFrames,presentationFrames:s.durationFrames)
        s.simulationRecording=try SimulationReplay.record(scene:s)
        return s
    }
    func testCompletedPublicGoodFailureProducesItsActualOutcomeInBothRounds()throws {
        let s=try failedPublicGoodsScene(),bytes=try Codec.data(s)
        let moments=try ClassicSceneEditing.knowledgeSoundMoments(scene:s)
        XCTAssertEqual(moments.map(\.kind),[.action,.outcome,.action,.outcome])
        XCTAssertEqual(moments.map(\.sourceFrame),[60,150,240,330])
        let outcomes=moments.filter{$0.kind == .outcome}
        XCTAssertEqual(outcomes.map(\.round),[1,2]);XCTAssertEqual(outcomes.map(\.sourceTick),[5,11])
        for moment in outcomes {
            XCTAssertTrue(moment.summary.contains("实际投入2，未达共享门槛3"))
            XCTAssertTrue(moment.summary.contains("甲、乙、丙均未通行，实际收益均为0"))
        }
        XCTAssertEqual(try Codec.data(s),bytes)
        var replay=s;replay.simulationRecording=try SimulationReplay.record(scene:replay)
        XCTAssertEqual(try ClassicSceneEditing.knowledgeSoundMoments(scene:replay),moments,"重复录制同一模型不能重建声音事件身份")
    }
    func testFailedOutcomeRequiresVisibleSettlementAndNeverReplaysAfterItsOnset()throws {
        let original=try failedPublicGoodsScene(rounds:1)
        for (start,end,expected) in [(90,150,0),(150,180,1),(151,180,0)] {
            var shot=original;shot.durationFrames=60
            shot.simulationPresentation=SimulationPresentation(sourceStartFrame:start,sourceEndFrame:end,presentationFrames:60)
            shot.simulationRecording=try SimulationReplay.record(scene:shot)
            let moments=try ClassicSceneEditing.knowledgeSoundMoments(scene:shot)
            XCTAssertEqual(moments.count,expected)
            if expected==1 {XCTAssertEqual(moments[0].kind,.outcome);XCTAssertEqual(moments[0].sceneFrame,0);XCTAssertEqual(moments[0].sourceFrame,150)}
        }
    }
    func testFailedOutcomeKeepsOneOwnerAcrossSplitAndRetimedSourceWindow()throws {
        let s=try failedPublicGoodsScene(),moments=try ClassicSceneEditing.knowledgeSoundMoments(scene:s)
        let project=Project(workspaceID:"w",name:"真实未达门槛",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"按实际结算定位声音"),aspect:.landscape,scenes:[s]))
        let split=try Editor.apply([.splitScene(s.id,150)],to:project,baseRevision:project.current.id,assets:[],message:"在失败结算源时点拆分")
        var after:[KnowledgeSoundMoment]=[]
        for var shot in split.current.scenes {shot.simulationRecording=try SimulationReplay.record(scene:shot);after += try ClassicSceneEditing.knowledgeSoundMoments(scene:shot)}
        XCTAssertEqual(after.map(\.id),moments.map(\.id));XCTAssertEqual(after.map(\.sourceFrame),moments.map(\.sourceFrame))
        XCTAssertEqual(after.map(\.sceneFrame),[60,0,90,180])
        var retimed=try failedPublicGoodsScene(rounds:1);retimed=try StoryboardTiming.extending(scene:retimed,to:360)
        retimed.simulationRecording=try SimulationReplay.record(scene:retimed)
        let outcome=try XCTUnwrap(ClassicSceneEditing.knowledgeSoundMoments(scene:retimed).first{$0.kind == .outcome})
        XCTAssertEqual(outcome.sceneFrame,301);XCTAssertEqual(outcome.sourceFrame,150)
        XCTAssertEqual(outcome.id,moments[1].id,"展示延长不改变实际轮次/结算事件身份")
    }
    func testZeroPayoutMatrixAndUnappliedTableDoNotBecomePublicGoodFailures()throws {
        var matrix=KnowledgePayoffMatrix.prisonersDilemma();matrix.stake=0;matrix.externalBudget=0
        matrix.cells=matrix.cells.map{var cell=$0;cell.rowPayout=0;cell.columnPayout=0;return cell}
        var s=try scene()
        s.simulation.knowledge=KnowledgeSimulation(knowledgeLabel:"零发放矩阵",participants:[
            .init(id:"a",name:"甲",strategy:.contribute,matrixStrategy:.alwaysFirst),
            .init(id:"b",name:"乙",strategy:.contribute,matrixStrategy:.alwaysFirst)
        ],rounds:1,payoffMatrix:matrix)
        s.simulationRecording=try SimulationReplay.record(scene:s)
        XCTAssertTrue(try ClassicSceneEditing.knowledgeSoundMoments(scene:s).isEmpty,"矩阵未发放不等于公共品未达门槛")
        var table=try tableScene()
        table.simulation.knowledge?.ruleTable?.rules[0].conditions=[.init(kind:.actionCount,actionID:"act",minimum:0,maximum:0)]
        table.simulationRecording=try SimulationReplay.record(scene:table)
        XCTAssertFalse(try ClassicSceneEditing.knowledgeSoundMoments(scene:table).contains{$0.kind == .outcome},"未应用规则不能编造实际状态变化或失败后果")
    }
    func testFailedOutcomeBindsWholeSourceWithoutApprovingAndRetimesToTheSameSettlement()throws {
        let(s,assets,evidence)=try audioFixture(failedPublicGoodsScene(rounds:1),frames:10)
        let moment=try XCTUnwrap(ClassicSceneEditing.knowledgeSoundMoments(scene:s).first{$0.kind == .outcome})
        let bound=try ClassicSceneEditing.addingKnowledgeCue(moment,assetID:assets[1].id,gain:0.3,to:s,assets:assets,evidence:evidence,workspaceID:"w")
        let cue=try XCTUnwrap(bound.classicArtwork?.audioCues.first)
        XCTAssertEqual(cue.startFrame,150);XCTAssertEqual(cue.durationFrames,10);XCTAssertFalse(cue.listened)
        XCTAssertEqual(bound.simulationRecording,s.simulationRecording);XCTAssertEqual(bound.durationFrames,180)
        let extended=try StoryboardTiming.extending(scene:bound,to:360)
        XCTAssertEqual(extended.classicArtwork?.audioCues.first?.startFrame,301)
        XCTAssertEqual(try extended.renderSimulationSourceFrame(atTimelineFrame:301),150)
        XCTAssertEqual(extended.classicArtwork?.audioCues.first?.id,cue.id)
        XCTAssertThrowsError(try ClassicSceneEditing.knowledgeSoundMoments(scene:extended),"扩时后仍须实际重新录制")
        let(tooLong,longAssets,longEvidence)=try audioFixture(failedPublicGoodsScene(rounds:1),frames:31)
        let late=try XCTUnwrap(ClassicSceneEditing.knowledgeSoundMoments(scene:tooLong).first{$0.kind == .outcome})
        XCTAssertThrowsError(try ClassicSceneEditing.addingKnowledgeCue(late,assetID:longAssets[1].id,gain:0.3,to:tooLong,assets:longAssets,evidence:longEvidence,workspaceID:"w"),"失败音效也不能截断完整原音句尾")
    }
    func testTableEffectsAreSoundMomentsOnlyWhenActuallySettled()throws {
        var s=try tableScene()
        let moments=try ClassicSceneEditing.knowledgeSoundMoments(scene:s)
        XCTAssertEqual(moments.map(\.sceneFrame),[68,83,165]);XCTAssertTrue(moments[2].summary.contains("实际转移：公共池→甲，1"))
        s.simulation.knowledge?.ruleTable?.rules[0].conditions=[.init(kind:.actionCount,actionID:"act",minimum:0,maximum:0)]
        s.simulationRecording=try SimulationReplay.record(scene:s)
        XCTAssertEqual(try ClassicSceneEditing.knowledgeSoundMoments(scene:s).map(\.kind),[.action,.action],"真实扣费仍有两项交接；规则声明不是已应用的后果")
    }
    func testMatrixPayoutUsesSettlementAndNotEarlyBalanceOrPublicGoodPhase()throws {
        var s=try scene()
        s.simulation.knowledge=KnowledgeSimulation(knowledgeLabel:"博弈",participants:[
            .init(id:"a",name:"甲",strategy:.contribute,initialResources:20,matrixStrategy:.alwaysFirst),
            .init(id:"b",name:"乙",strategy:.contribute,initialResources:20,matrixStrategy:.alwaysSecond)
        ],rounds:1,payoffMatrix:.prisonersDilemma())
        s.simulationRecording=try SimulationReplay.record(scene:s)
        let moments=try ClassicSceneEditing.knowledgeSoundMoments(scene:s)
        XCTAssertEqual(moments.map(\.sourceTick),[2,2,5]);XCTAssertEqual(moments.map(\.sourceFrame),[75,75,165])
        XCTAssertTrue(moments[2].summary.contains("乙：实际收益7"))
    }
    func testEachAppliedTableRouteHasAStableSoundAtItsVisibleHandoffAndSplitKeepsItOnce()throws {
        var s=try tableScene()
        s.simulation.knowledge?.ruleTable?.rules[0].effects=[.transfer(from:nil,to:"a",amount:1),.transfer(from:nil,to:"b",amount:1)]
        s.simulationRecording=try SimulationReplay.record(scene:s)
        let moments=try ClassicSceneEditing.knowledgeSoundMoments(scene:s)
        XCTAssertEqual(moments.map(\.sourceFrame),[68,83,158,173])
        XCTAssertEqual(Set(moments.map(\.id)).count,4)
        XCTAssertTrue(moments[2].summary.contains("公共池→甲"));XCTAssertTrue(moments[3].summary.contains("公共池→乙"))
        let project=Project(workspaceID:"w",name:"逐项交接",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"逐项交接"),aspect:.landscape,scenes:[s]))
        let split=try Editor.apply([.splitScene(s.id,160)],to:project,baseRevision:project.current.id,assets:[],message:"交接中切镜头")
        var after:[KnowledgeSoundMoment]=[]
        for var cut in split.current.scenes {
            cut.simulationRecording=try SimulationReplay.record(scene:cut)
            after += try ClassicSceneEditing.knowledgeSoundMoments(scene:cut)
        }
        XCTAssertEqual(after.map(\.id),moments.map(\.id));XCTAssertEqual(after.map(\.sourceFrame),moments.map(\.sourceFrame))
        XCTAssertEqual(after.map(\.sceneFrame),[68,83,158,13])
    }
    func testRetimedWindowMapsPerRouteHandoffsAndRejectsSkippedVisibleBeat()throws {
        var s=try tableScene();s.durationFrames=360
        s.simulationPresentation=SimulationPresentation(sourceStartFrame:0,sourceEndFrame:180,presentationFrames:360)
        s.simulationRecording=try SimulationReplay.record(scene:s)
        let moments=try ClassicSceneEditing.knowledgeSoundMoments(scene:s)
        XCTAssertEqual(moments.map(\.sourceFrame),[68,83,165])
        for moment in moments {XCTAssertEqual(try s.renderSimulationSourceFrame(atTimelineFrame:moment.sceneFrame),moment.sourceFrame)}
        s.durationFrames=2;s.simulationPresentation=SimulationPresentation(sourceStartFrame:60,sourceEndFrame:90,presentationFrames:2)
        s.simulationRecording=try SimulationReplay.record(scene:s)
        XCTAssertThrowsError(try ClassicSceneEditing.knowledgeSoundMoments(scene:s),"不能将第一项交接声音放到另一项或回位帧")
    }
    func testRetimedDuplicateSourceFrameBelongsOnlyToItsFirstAbsolutePresentationPosition()throws {
        var s=try tableScene();s.durationFrames=360
        s.simulationPresentation=SimulationPresentation(sourceStartFrame:0,sourceEndFrame:180,presentationFrames:360)
        s.simulationRecording=try SimulationReplay.record(scene:s)
        let original=try ClassicSceneEditing.knowledgeSoundMoments(scene:s)
        XCTAssertEqual(original.map(\.sceneFrame),[137,167,331])
        XCTAssertEqual(try s.renderSimulationSourceFrame(atTimelineFrame:137),68)
        XCTAssertEqual(try s.renderSimulationSourceFrame(atTimelineFrame:138),68)
        for boundary in [137,138,139,332] {
            let project=Project(workspaceID:"w",name:"重定时交接",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"重定时交接"),aspect:.landscape,scenes:[s]))
            let split=try Editor.apply([.splitScene(s.id,boundary)],to:project,baseRevision:project.current.id,assets:[],message:"保留绝对展示归属")
            var after:[KnowledgeSoundMoment]=[],positions:[Int]=[]
            for var cut in split.current.scenes {
                cut.simulationRecording=try SimulationReplay.record(scene:cut)
                let moments=try ClassicSceneEditing.knowledgeSoundMoments(scene:cut)
                after += moments
                positions += moments.map{$0.sceneFrame+(cut.simulationPresentation?.presentationOffsetFrames ?? 0)}
            }
            XCTAssertEqual(after.map(\.id),original.map(\.id));XCTAssertEqual(after.map(\.sourceFrame),original.map(\.sourceFrame))
            XCTAssertEqual(positions,original.map(\.sceneFrame),"重复的源帧不能让左右两片各产生同一声音候选")
        }
    }
    func testCompressedFirstVisibleHandoffStaysOwnedByRightCutEvenWhenItSkipsNominalSourceCenter()throws {
        var s=try tableScene();s.durationFrames=120
        s.simulationPresentation=SimulationPresentation(sourceStartFrame:0,sourceEndFrame:180,presentationFrames:120)
        s.simulationRecording=try SimulationReplay.record(scene:s)
        let original=try ClassicSceneEditing.knowledgeSoundMoments(scene:s)
        let first=try XCTUnwrap(original.first)
        XCTAssertGreaterThan(first.sourceFrame,68)
        let project=Project(workspaceID:"w",name:"压缩展示",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"压缩展示"),aspect:.landscape,scenes:[s]))
        let split=try Editor.apply([.splitScene(s.id,first.sceneFrame)],to:project,baseRevision:project.current.id,assets:[],message:"在真实首次展示处拆分")
        var after:[KnowledgeSoundMoment]=[]
        for var cut in split.current.scenes {cut.simulationRecording=try SimulationReplay.record(scene:cut);after += try ClassicSceneEditing.knowledgeSoundMoments(scene:cut)}
        XCTAssertEqual(after.map(\.id),original.map(\.id));XCTAssertEqual(after.map(\.sourceFrame),original.map(\.sourceFrame))
        XCTAssertEqual(after.first?.sceneFrame,0)
    }
    func testRightSplitReframingRejectsAmbiguousOnsetAncestryAndOtherSpeedsRemainExplicitlyUnsupported()throws {
        var s=try tableScene();s.durationFrames=360
        s.simulationPresentation=SimulationPresentation(sourceStartFrame:0,sourceEndFrame:180,presentationFrames:360)
        s.simulationRecording=try SimulationReplay.record(scene:s)
        let project=Project(workspaceID:"w",name:"延长右片",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"延长右片"),aspect:.landscape,scenes:[s]))
        let split=try Editor.apply([.splitScene(s.id,138)],to:project,baseRevision:project.current.id,assets:[],message:"后续延长")
        var right=try XCTUnwrap(split.current.scenes.last)
        right=try StoryboardTiming.extending(scene:right,to:300)
        right.simulationRecording=try SimulationReplay.record(scene:right)
        XCTAssertEqual(right.simulationPresentation?.presentationOffsetFrames,0)
        XCTAssertGreaterThan(right.sourceStartFrame,0)
        XCTAssertThrowsError(try ClassicSceneEditing.knowledgeSoundMoments(scene:right),"现有持久字段丢失首次展示归属时必须明确拒绝，不能重复生成声音")
        for speed in [0.5,2.0] {
            var changed=s;changed.speed=speed
            XCTAssertThrowsError(try ClassicSceneEditing.knowledgeSoundMoments(scene:changed))
        }
    }
    func testZeroCostActionAndStateOnlyOutcomeKeepTheirActualOnsetsWithoutFakeTransfer()throws {
        var s=try tableScene();s.simulation.knowledge?.ruleTable?.actions[0].cost=0
        s.simulation.knowledge?.ruleTable?.rules[0].effects=[.setState(actorID:"a",stateID:"closed")]
        s.simulationRecording=try SimulationReplay.record(scene:s)
        let moments=try ClassicSceneEditing.knowledgeSoundMoments(scene:s)
        XCTAssertEqual(moments.map(\.kind),[.action,.outcome]);XCTAssertEqual(moments.map(\.sourceFrame),[60,150])
        XCTAssertTrue(moments[0].summary.contains("提交，扣费0"))
        XCTAssertTrue(moments[1].summary.contains("没有实际资金转移"))
    }
    func testReadingNewScheduleLeavesExistingAudioCueFramesListeningAndRecordingBytesUnchanged()throws {
        var(s,_,_)=try audioFixture(tableScene(),frames:5)
        s.classicArtwork?.audioCues=[ClassicAudioCue(assetID:"previous-audio",startFrame:60,durationFrames:5,gain:0.25,listened:true)]
        let bytes=try Codec.data(s)
        _=try ClassicSceneEditing.knowledgeSoundMoments(scene:s)
        XCTAssertEqual(try Codec.data(s),bytes)
    }
    func testWindowRetimingUsesFirstActualVisibleFrameOfEachEvent()throws {
        var s=try scene();s.durationFrames=240
        s.simulationPresentation=SimulationPresentation(sourceStartFrame:60,sourceEndFrame:180,presentationFrames:240)
        s.simulationRecording=try SimulationReplay.record(scene:s)
        let moments=try ClassicSceneEditing.knowledgeSoundMoments(scene:s)
        XCTAssertEqual(moments.map(\.sceneFrame),[0,181])
        for m in moments {
            XCTAssertEqual(try s.renderSimulationSourceFrame(atTimelineFrame:m.sceneFrame)/30,m.sourceTick)
            if m.sceneFrame>0 {XCTAssertLessThan(try s.renderSimulationSourceFrame(atTimelineFrame:m.sceneFrame-1),m.sourceTick*30)}
        }
        s.simulationPresentation=SimulationPresentation(sourceStartFrame:61,sourceEndFrame:180,presentationFrames:240)
        s.simulationRecording=try SimulationReplay.record(scene:s)
        XCTAssertEqual(try ClassicSceneEditing.knowledgeSoundMoments(scene:s).map(\.kind),[.outcome],"切在行动开始之后不能在切口重放行动声")
    }
    func testSplitDoesNotDuplicateSoundOnsetAndPauseDoesNotReplaySettlement()throws {
        let s=try scene(), p=Project(workspaceID:"w",name:"声音分镜",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"分镜"),aspect:.landscape,scenes:[s]))
        let split=try Editor.apply([.splitScene(s.id,61)],to:p,baseRevision:p.current.id,assets:[],message:"保真实源事件")
        var moments:[KnowledgeSoundMoment]=[]
        for var cut in split.current.scenes {cut.simulationRecording=try SimulationReplay.record(scene:cut);moments += try ClassicSceneEditing.knowledgeSoundMoments(scene:cut)}
        XCTAssertEqual(moments.map(\.kind),[.action,.outcome]);XCTAssertEqual(moments.map(\.sceneFrame),[60,89])
        var legacy=s;legacy.pauseFrames=180;legacy.simulation.knowledge?.rounds=2;legacy.simulationRecording=try SimulationReplay.record(scene:legacy)
        XCTAssertEqual(legacy.simulationRecording?.throughTick,11)
        XCTAssertThrowsError(try ClassicSceneEditing.knowledgeSoundMoments(scene:legacy),"旧式停顿推进的新一轮事件不能静默漏掉")
        var paused=s;paused.pauseFrames=120;paused.simulationPresentation=SimulationPresentation(sourceStartFrame:0,sourceEndFrame:180,presentationFrames:180);paused.simulationRecording=try SimulationReplay.record(scene:paused)
        XCTAssertEqual(try ClassicSceneEditing.knowledgeSoundMoments(scene:paused).map(\.sceneFrame),[60,150])
    }
    func testChangedModelOrUnrecordedTimingCannotReuseOldSoundSelection()throws {
        let s=try scene(), old=try XCTUnwrap(ClassicSceneEditing.knowledgeSoundMoments(scene:s).first)
        var changed=s;changed.simulation.seed += 1
        XCTAssertThrowsError(try ClassicSceneEditing.knowledgeSoundMoments(scene:changed))
        changed.simulationRecording=try SimulationReplay.record(scene:changed)
        XCTAssertFalse(try ClassicSceneEditing.knowledgeSoundMoments(scene:changed).contains(old))
        var fast=s;fast.speed=2
        XCTAssertThrowsError(try ClassicSceneEditing.knowledgeSoundMoments(scene:fast))
        var skipped=s;skipped.durationFrames=2;skipped.simulationPresentation=SimulationPresentation(sourceStartFrame:0,sourceEndFrame:180,presentationFrames:2)
        skipped.simulationRecording=try SimulationReplay.record(scene:skipped)
        XCTAssertThrowsError(try ClassicSceneEditing.knowledgeSoundMoments(scene:skipped),"不能把未显示的行动声移到结算帧")
    }
    private func audioFixture(_ s:Scene,frames:Int)throws->(Scene,[Asset],[Evidence]) {
        var image=Asset(workspaceID:"w",name:"derived.png",hash:String(repeating:"a",count:64),ext:"png",bytes:10,mediaType:"image")
        let imageProof=Evidence(workspaceID:"w",title:"图块原件",source:"isolated-image",claim:"具体原件",owner:"原作者",commercialAllowed:false,verified:true);image.evidenceID=imageProof.id
        var audio=Asset(workspaceID:"w",name:"original.wav",hash:String(repeating:"b",count:64),ext:"wav",bytes:10,mediaType:"audio",durationFrames:frames)
        let audioProof=Evidence(workspaceID:"w",title:"原音",source:"isolated-audio",claim:"具体原音",owner:"原作者",commercialAllowed:false,verified:true);audio.evidenceID=audioProof.id
        let assets=[image,audio],evidence=[imageProof,audioProof]
        var scene=s
        let source=try ClassicSceneEditing.source(assetID:image.id,assets:assets,evidence:evidence,workspaceID:"w")
        let roles=["hero","floor","knowledge_backdrop","obstacle","hero_idle","hero_walk","hero_contribute","hero_success","hero_blocked"]
        scene.classicArtwork=ClassicArtwork(gameplay:.platformer,sprites:roles.map{ClassicSprite(role:$0,assetID:image.id)},sources:[source])
        return(scene,assets,evidence)
    }
    func testApplyingMomentKeepsWholeSourceAndNeverGrantsListeningOrRights()throws {
        let (s,assets,evidence)=try audioFixture(scene(),frames:10),moment=try XCTUnwrap(ClassicSceneEditing.knowledgeSoundMoments(scene:s).first)
        let result=try ClassicSceneEditing.addingKnowledgeCue(moment,assetID:assets[1].id,gain:0.25,to:s,assets:assets,evidence:evidence,workspaceID:"w")
        let cue=try XCTUnwrap(result.classicArtwork?.audioCues.first)
        XCTAssertEqual(cue.startFrame,60);XCTAssertEqual(cue.durationFrames,10);XCTAssertEqual(cue.gain,0.25);XCTAssertEqual(cue.use,.effect);XCTAssertFalse(cue.listened)
        XCTAssertEqual(result.simulationRecording,s.simulationRecording);XCTAssertEqual(result.durationFrames,180)
        XCTAssertEqual(s.classicArtwork?.audioCues.count,0)
        XCTAssertThrowsError(try ClassicArtworkRules.validateRights(scene:result,workspaceID:"w",assets:assets,evidence:evidence,commercial:true))
        XCTAssertThrowsError(try ClassicSceneEditing.addingKnowledgeCue(moment,assetID:assets[1].id,gain:0.25,to:s,assets:assets,evidence:[],workspaceID:"w"))
    }
    func testLongCueAndStaleMomentRejectWithoutMovingEventOrExtending()throws {
        let (s,assets,evidence)=try audioFixture(scene(),frames:31),moment=try XCTUnwrap(ClassicSceneEditing.knowledgeSoundMoments(scene:s).last)
        XCTAssertThrowsError(try ClassicSceneEditing.addingKnowledgeCue(moment,assetID:assets[1].id,gain:0.3,to:s,assets:assets,evidence:evidence,workspaceID:"w"))
        XCTAssertEqual(s.durationFrames,180);XCTAssertEqual(s.classicArtwork?.audioCues.count,0)
        var changed=s;changed.simulation.seed += 1;changed.simulationRecording=try SimulationReplay.record(scene:changed)
        XCTAssertThrowsError(try ClassicSceneEditing.addingKnowledgeCue(moment,assetID:assets[1].id,gain:0.3,to:changed,assets:assets,evidence:evidence,workspaceID:"w"))
        var locked=s;locked.locked=true
        XCTAssertThrowsError(try ClassicSceneEditing.addingKnowledgeCue(try XCTUnwrap(ClassicSceneEditing.knowledgeSoundMoments(scene:s).first),assetID:assets[1].id,gain:0.3,to:locked,assets:assets,evidence:evidence,workspaceID:"w"))
    }
}
