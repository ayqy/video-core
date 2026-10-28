import XCTest
@testable import VideoCore

final class CartoonPerformanceTests: XCTestCase {
    func testCreationRejectsExtremeDurationBeforeAnyArithmeticOrAllocation() throws {
        for frames in [Int.max,Int.min,-1,5,54001] {XCTAssertThrowsError(try CartoonPerformance.conversation(durationFrames:frames))}
        for frames in [6,54000] {try CartoonPerformance.conversation(durationFrames:frames).validate(durationFrames:frames)}
    }
    private func fixture() throws -> (Scene,[Asset],Project) {
        var source=Asset(workspaceID:"w",name:"original.png",hash:String(repeating:"0",count:64),ext:"png",bytes:10,mediaType:"image")
        var derived=Asset(workspaceID:"w",name:"actual-poses.png",hash:String(repeating:"1",count:64),ext:"png",bytes:10,mediaType:"image")
        source.evidenceID="original-proof";derived.evidenceID="derived-proof"
        let roles=Array(Set(CartoonActor.dinoRoles.values)).sorted()+["hero","floor","backdrop"]
        let sprites=roles.enumerated().map{ClassicSprite(role:$0.element,assetID:derived.id,x:Double($0.offset%3)/3,y:Double($0.offset/3)/3,width:0.25,height:0.25)}
        let sources=[source,derived].map{ClassicSource(assetID:$0.id,hash:$0.hash,source:"isolated://"+$0.name,owner:"隔离图块规则",license:"隔离开发规则，不是传播授权",evidenceID:$0.evidenceID!)}
        var scene=Scene(kind:.cartoon,title:"对同一问题的不同看法",body:"角色表演由当前节拍决定",narration:"先听对方，再检验观点。",durationFrames:90)
        scene.classicArtwork=ClassicArtwork(gameplay:.platformer,sprites:sprites,sources:sources,derivation:.qStyle,transformation:"隔离派生与分区",originalAssetIDs:[source.id])
        scene.cartoonPerformance=try .conversation(durationFrames:90)
        let context=ContentContext(workspaceID:"w",name:"本地表演工程")
        let project=Project(workspaceID:"w",name:"本地表演工程",revision:Revision(contentContext:context,aspect:.landscape,scenes:[scene]))
        return(scene,[source,derived],project)
    }
    func testSourceFramesSelectActualSpeakerPoseCameraAndAlternatingWalk() throws {
        let (scene,assets,_)=try fixture(),p=try XCTUnwrap(scene.cartoonPerformance)
        try scene.validate(assets:assets)
        let first=try p.frameState(frame:0,fps:30,durationFrames:90)
        XCTAssertEqual(first.speakerID,"actor-a");XCTAssertEqual(first.actors[0].pose,.speak)
        let second=try p.frameState(frame:30,fps:30,durationFrames:90)
        XCTAssertEqual(second.speakerID,"actor-b");XCTAssertEqual(second.camera,.speaker);XCTAssertEqual(second.actors[1].pose,.object)
        let a=try p.frameState(frame:60,fps:30,durationFrames:90),b=try p.frameState(frame:65,fps:30,durationFrames:90)
        XCTAssertNotEqual(a.actors[0].role,b.actors[0].role);XCTAssertGreaterThan(b.actors[0].x,a.actors[0].x)
        XCTAssertFalse(a.actors[0].mirrored);XCTAssertTrue(a.actors[1].mirrored)
        XCTAssertEqual(try p.frameState(frame:89,fps:30,durationFrames:90),try p.frameState(frame:200,fps:30,durationFrames:90),"镜头停顿只保终态，不重新循环表演")
    }
    func testTrimPreservesEveryPositionPoseSpeakerAndWalkingPhaseAcrossBoundaries() throws {
        let (scene,_,_)=try fixture(),p=try XCTUnwrap(scene.cartoonPerformance)
        for (start,end) in [(0,45),(45,90),(63,84),(64,65)] {
            let part=try p.trimmed(from:start,to:end,durationFrames:90)
            for frame in 0..<(end-start) {
                let original=try p.frameState(frame:start+frame,fps:30,durationFrames:90),actual=try part.frameState(frame:frame,fps:30,durationFrames:end-start)
                XCTAssertEqual(actual.speakerID,original.speakerID);XCTAssertEqual(actual.camera,original.camera)
                XCTAssertEqual(actual.localAnimationFrame,original.localAnimationFrame)
                for (a,b) in zip(actual.actors,original.actors) {
                    XCTAssertEqual(a.x,b.x,accuracy:1e-12);XCTAssertEqual(a.role,b.role);XCTAssertEqual(a.pose,b.pose);XCTAssertEqual(a.mirrored,b.mirrored)
                }
            }
        }
    }
    func testRejectsMissingActorsCuesGapsOverlapUnknownSpeakerAndNonfinitePositions() throws {
        let p=try CartoonPerformance.conversation(durationFrames:90)
        var variants:[CartoonPerformance]=[]
        var x=p;x.version=2;variants.append(x)
        x=p;x.actors[1].id=x.actors[0].id;variants.append(x)
        x=p;x.beats[0].cues.removeLast();variants.append(x)
        x=p;x.beats[1].startFrame+=1;variants.append(x)
        x=p;x.beats[1].startFrame-=1;variants.append(x)
        x=p;x.beats[0].speakerID="unknown";variants.append(x)
        x=p;x.beats[0].camera = .speaker;x.beats[0].speakerID=nil;variants.append(x)
        x=p;x.beats[0].cues[0].fromX = .nan;variants.append(x)
        x=p;x.beats[0].cues[0].toX = .infinity;variants.append(x)
        x=p;x.beats[0].cues[0].lookAtID=x.beats[0].cues[0].actorID;variants.append(x)
        x=p;x.beats[2].endFrame=89;variants.append(x)
        for (index,v) in variants.enumerated(){XCTAssertThrowsError(try v.validate(durationFrames:90),"拒绝无效变体\(index)")}
        XCTAssertThrowsError(try p.frameState(frame:-1,fps:30,durationFrames:90))
        XCTAssertThrowsError(try p.frameState(frame:0,fps:0,durationFrames:90))
    }
    func testRejectsMissingPoseOrTwoNamesPointingToOneActualWalkingRegion() throws {
        let (scene,_,_)=try fixture(),p=try XCTUnwrap(scene.cartoonPerformance),sprites=try XCTUnwrap(scene.classicArtwork).sprites
        XCTAssertThrowsError(try p.validate(durationFrames:90,sprites:sprites.filter{$0.role != "hero_walk_alt"}))
        var aliases=sprites
        let a=try XCTUnwrap(aliases.firstIndex(where:{$0.role=="hero_walk"})),b=try XCTUnwrap(aliases.firstIndex(where:{$0.role=="hero_walk_alt"}))
        let old=aliases[a];aliases[b]=ClassicSprite(role:"hero_walk_alt",assetID:old.assetID,x:old.x,y:old.y,width:old.width,height:old.height)
        XCTAssertThrowsError(try p.validate(durationFrames:90,sprites:aliases))
        var missing=p;missing.actors[0].poseRoles["walkAlternate"]=nil
        XCTAssertThrowsError(try missing.validate(durationFrames:90))
    }
    func testNormalEditorRejectsTwoImportsOfOneWalkingRegionWithoutBanningAtlasReuse() throws {
        let (original,assets,project)=try fixture(),before=try Codec.data(project)
        var duplicate=assets[1];duplicate.id=Codec.id();duplicate.name="same-poses-imported-again.png"
        let completeAssets=assets+[duplicate]
        var changed=original,artwork=try XCTUnwrap(changed.classicArtwork)
        let walk=try XCTUnwrap(artwork.sprites.first{$0.role=="hero_walk"})
        let alternate=try XCTUnwrap(artwork.sprites.firstIndex{$0.role=="hero_walk_alt"})
        let actualAlternate=artwork.sprites[alternate]
        artwork.sources.append(ClassicSource(assetID:duplicate.id,hash:duplicate.hash,source:"isolated://second-import",owner:"隔离图块规则",license:"隔离开发规则，不是传播授权",evidenceID:try XCTUnwrap(duplicate.evidenceID)))
        artwork.sprites[alternate]=ClassicSprite(role:"hero_walk_alt",assetID:duplicate.id,x:walk.x,y:walk.y,width:walk.width,height:walk.height)
        changed.classicArtwork=artwork
        // Historical metadata remains readable. Only new work/production adds
        // the source-byte identity check, so an old project can be repaired.
        XCTAssertNoThrow(try changed.validate(assets:completeAssets))
        XCTAssertThrowsError(try Planner.create(workspaceID:"w",name:"新表演",scenes:[changed],assets:completeAssets))
        XCTAssertThrowsError(try ClassicArtworkRules.validateRights(scene:changed,workspaceID:"w",assets:completeAssets,evidence:[],commercial:false)) {error in
            XCTAssertEqual((error as? VideoError)?.code,"invalid_input")
        }
        XCTAssertThrowsError(try Editor.apply([.replaceScene(original.id,changed)],to:project,baseRevision:project.current.id,assets:completeAssets,message:"重复导入不能充当第二步态"))
        XCTAssertEqual(try Codec.data(project),before)
        let historicalAlias=changed
        // A second imported identity remains usable for a genuinely different
        // region of the same atlas, and ordinary revision/history rules apply.
        var differentRegion=actualAlternate;differentRegion.assetID=duplicate.id
        artwork.sprites[alternate]=differentRegion;changed.classicArtwork=artwork
        let edited=try Editor.apply([.replaceScene(original.id,changed)],to:project,baseRevision:project.current.id,assets:completeAssets,message:"保留同图集的不同真实步态区域")
        XCTAssertEqual(try Codec.data(edited.revisions[0]),try Codec.data(project.current))
        XCTAssertEqual(edited.current.scenes[0].classicArtwork?.sprites[alternate],differentRegion)
        XCTAssertEqual(edited.current.scenes[0].cartoonPerformance,original.cartoonPerformance)
        XCTAssertFalse(edited.current.review.complete)
        XCTAssertNoThrow(try Planner.create(workspaceID:"w",name:"新表演",scenes:[changed],assets:completeAssets))

        // Persist an isolated pre-fix snapshot with actual CAS bytes. It is
        // historical test data, not an acceptance hook or a product migration.
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cartoon-history-"+UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let repository=try Repository(root:root.appendingPathComponent("source"))
        var storedAssets:[Asset]=[]
        for asset in completeAssets {
            var stored=try repository.ingest(Data(("isolated-core-image-"+asset.hash).utf8),name:asset.name,workspaceID:"w",mediaType:"image")
            stored.id=asset.id;stored.evidenceID=asset.evidenceID;storedAssets.append(stored)
        }
        var legacyScene=historicalAlias
        let legacySources=try XCTUnwrap(legacyScene.classicArtwork).sources.map{source in
            var value=source;value.hash=storedAssets.first{$0.id==source.assetID}!.hash;return value
        }
        legacyScene.classicArtwork?.sources=legacySources
        let legacyRevision=Revision(contentContext:ContentContext(workspaceID:"w",name:"旧角色工程"),aspect:.landscape,scenes:[legacyScene])
        let legacyProject=Project(workspaceID:"w",name:"旧角色工程",revision:legacyRevision)
        var workspace=Workspace(name:"隔离历史",owner:"owner");workspace.id="w"
        try repository.transaction{state in state.workspaces=[workspace];state.assets=storedAssets;state.projects=[legacyProject]}
        try repository.read().validate()
        let opened=try Repository(root:repository.root,readOnly:true)
        XCTAssertEqual(try Codec.data(opened.read().projects[0]),try Codec.data(legacyProject))
        let oldBackup=try repository.backup()
        let restored=try Repository.restore(oldBackup,to:root.appendingPathComponent("restored"))
        XCTAssertEqual(try Codec.data(restored.read().projects[0]),try Codec.data(legacyProject))
        XCTAssertThrowsError(try Editor.apply([.cta("新修订不能带入旧步态别名")],to:legacyProject,baseRevision:legacyRevision.id,assets:storedAssets,message:"检查整版结果"))
        let issues=try Quality.inspect(legacyRevision,database:restored.read(),requireReview:false)
        XCTAssertTrue(issues.contains{$0.message.contains("行走的两个动作名称")},"实际制作预检必须拒绝旧别名，而非靠源文件不可读拒绝")
        var repaired=legacyScene
        repaired.classicArtwork?.sprites[alternate].x=actualAlternate.x
        repaired.classicArtwork?.sprites[alternate].y=actualAlternate.y
        repaired.classicArtwork?.sprites[alternate].width=actualAlternate.width
        repaired.classicArtwork?.sprites[alternate].height=actualAlternate.height
        let fixed=try Editor.apply([.replaceScene(legacyScene.id,repaired)],to:legacyProject,baseRevision:legacyRevision.id,assets:storedAssets,message:"明确修复第二步态区域")
        XCTAssertEqual(try Codec.data(fixed.revisions[0]),try Codec.data(legacyRevision))
        try restored.transaction{$0.projects=[fixed]}
        try restored.read().validate()
        let repairedBackup=try restored.backup()
        let repairedRestore=try Repository.restore(repairedBackup,to:root.appendingPathComponent("repaired-restored"))
        XCTAssertEqual(try Codec.data(repairedRestore.read().projects[0]),try Codec.data(fixed))
        XCTAssertThrowsError(try Editor.apply([.restore(legacyRevision.id)],to:fixed,baseRevision:fixed.current.id,assets:storedAssets,message:"恢复历史也须生成有效新结果"))
        let legacyAndRepair=try Editor.apply([.restore(legacyRevision.id),.replaceScene(legacyScene.id,repaired)],to:fixed,baseRevision:fixed.current.id,assets:storedAssets,message:"同批恢复并明确修复")
        XCTAssertEqual(try Codec.data(legacyAndRepair.revisions[0]),try Codec.data(legacyRevision))
        XCTAssertEqual(try Codec.data(legacyAndRepair.revisions[1]),try Codec.data(fixed.current))
        XCTAssertNoThrow(try ClassicArtworkRules.validateWalkingSources(scene:legacyAndRepair.current.scenes[0],assets:storedAssets))
    }
    func testOldSceneNilOmissionAndNewPerformanceRoundTripBindDigest() throws {
        var (scene,_,_)=try fixture();scene.cartoonPerformance=nil
        let old=try Codec.data(scene)
        XCTAssertFalse(String(decoding:old,as:UTF8.self).contains("cartoonPerformance"))
        XCTAssertEqual(try Codec.data(Codec.decoder().decode(Scene.self,from:old)),old)
        scene.cartoonPerformance=try .conversation(durationFrames:90)
        let digest=try Codec.digest(scene);scene.cartoonPerformance?.beats[0].speakerID="actor-b"
        XCTAssertNotEqual(try Codec.digest(scene),digest)
        XCTAssertEqual(try Codec.decoder().decode(Scene.self,from:Codec.data(scene)),scene)
    }
    func testNormalEditorPreservesHistoryAndInvalidatesListeningAndCaptions() throws {
        var (scene,assets,project)=try fixture()
        scene.speechPlan=try ChineseSpeech.normalize(scene.narration);scene.speechPlan?.confirmed=true
        scene.voice=VoiceTake(assetID:"existing-voice",textDigest:try scene.speechDigest(),durationFrames:90,method:"imported_audio",listened:true)
        scene.captions=[Caption(text:"先听对方",startFrame:0,endFrame:90,confirmed:true)]
        project.revisions[0].scenes=[scene]
        var changed=scene;changed.cartoonPerformance?.beats[0].speakerID="actor-b"
        let edited=try Editor.apply([.replaceScene(scene.id,changed)],to:project,baseRevision:project.current.id,assets:assets,message:"修改发言节拍")
        XCTAssertEqual(edited.revisions[0].scenes[0],scene)
        XCTAssertEqual(edited.current.scenes[0].voice?.assetID,"existing-voice")
        XCTAssertEqual(edited.current.scenes[0].voice?.listened,false)
        XCTAssertFalse(edited.current.scenes[0].captions[0].confirmed)
        XCTAssertTrue(edited.current.invalidated.contains("多角色表演、发言时点、镜头与声音字幕重新复核"))
        XCTAssertFalse(edited.current.review.complete)
    }
    func testNormalSplitTrimsBothPerformancesAndKeepsOriginalVersion() throws {
        let (scene,assets,project)=try fixture()
        let edited=try Editor.apply([.splitScene(scene.id,63)],to:project,baseRevision:project.current.id,assets:assets,message:"表演源帧拆分")
        XCTAssertEqual(edited.revisions[0].scenes[0],scene);XCTAssertEqual(edited.current.scenes.map(\.durationFrames),[63,27])
        let original=try XCTUnwrap(scene.cartoonPerformance),right=try XCTUnwrap(edited.current.scenes[1].cartoonPerformance)
        for frame in 0..<27 {
            let a=try right.frameState(frame:frame,fps:30,durationFrames:27),b=try original.frameState(frame:63+frame,fps:30,durationFrames:90)
            XCTAssertEqual(a.localAnimationFrame,b.localAnimationFrame)
            for (x,y) in zip(a.actors,b.actors){XCTAssertEqual(x.x,y.x,accuracy:1e-12);XCTAssertEqual(x.role,y.role)}
        }
    }
    func testModuleSchemaIsolationAndVisualDtoNeverCopiesNarrationOrSources() throws {
        var (scene,_,_)=try fixture();scene.narration="PRIVATE-NARRATION-NEVER-CROSS";scene.body="PRIVATE-MATERIAL"
        scene.classicArtwork?.transformation="PRIVATE-DERIVATION-NOTES"
        let dto=PluginVisualProps(scene:scene),json=String(decoding:try Codec.data(dto),as:UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE-"));XCTAssertEqual(dto.drawingScene().cartoonPerformance,scene.cartoonPerformance)
        XCTAssertThrowsError(try PluginInputCompatibility.requireCartoonSupport(scene.cartoonPerformance,pluginID:"video.cartoon",inputSchema:1))
        XCTAssertThrowsError(try PluginInputCompatibility.requireCartoonSupport(scene.cartoonPerformance,pluginID:"video.game",inputSchema:3))
        XCTAssertNoThrow(try PluginInputCompatibility.requireCartoonSupport(scene.cartoonPerformance,pluginID:"video.cartoon",inputSchema:4))
        let old=PluginRPCSchemas.definitions(inputSchemaVersion:1),new=PluginRPCSchemas.definitions(inputSchemaVersion:4)
        XCTAssertNil(old["CartoonPerformance"]);XCTAssertNotNil(new["CartoonPerformance"])
        XCTAssertNotNil(AgentSchemas.definitions()["CartoonPerformance"])
    }
}
