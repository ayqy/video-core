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
