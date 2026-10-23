import XCTest
@testable import VideoCore

final class EditorPracticeTests:XCTestCase {
    private func fixture() throws -> (Project,Asset) {
        let bytes=Data(EditorPracticeRules.sourceText.utf8)
        let source=Asset(workspaceID:"practice",name:"离线练习.txt",hash:Codec.hash(bytes),ext:"txt",bytes:bytes.count,mediaType:"text")
        return(try LearningExample.project(workspaceID:"practice",asset:source),source)
    }
    private func contentFixture()throws->(Project,Asset) {
        let bytes=Data(LearningExample.contentSourceText.utf8)
        var source=Asset(workspaceID:"practice",name:LearningExample.contentSourceName,hash:Codec.hash(bytes),ext:"txt",bytes:bytes.count,mediaType:"text")
        source.pages=[CoursePage(number:1,text:LearningExample.contentSourceText)]
        return(try LearningExample.contentProject(workspaceID:"practice",asset:source),source)
    }
    func testBuiltInExercisePermitsTextTimingAndLayoutPracticeWithoutClaimingPaidRights() throws {
        var(project,source)=try fixture();XCTAssertTrue(EditorPracticeRules.allows(project:project,assets:[source]))
        var revision=project.current;revision.id=Codec.id();revision.number += 1;revision.scenes[0].body="自己试着改一句练习文案";revision.scenes[0].durationFrames=150;revision.scenes[0].x=0.2;project.revisions.append(revision)
        XCTAssertTrue(EditorPracticeRules.allows(project:project,assets:[source]))
    }
    func testEditableExampleFlagCannotAuthorizeARealProduct() throws {
        var(project,source)=try fixture();project.revisions[0].product!.checkout="https://example.org/real-product";project.revisions[0].product!.isExample=true
        XCTAssertFalse(EditorPracticeRules.allows(project:project,assets:[source]))
    }
    func testPracticeStopsWhenItsProductFactsBecomeCommercialOrItsCTAChanges() throws {
        let(original,source)=try fixture();var cases:[Project]=[]
        var project=original;var revision=project.current;revision.id=Codec.id();revision.product!.prices[0].money=Money(99);project.revisions.append(revision);cases.append(project)
        project=original;revision=project.current;revision.id=Codec.id();revision.purpose = .course;project.revisions.append(revision);cases.append(project)
        project=original;revision=project.current;revision.id=Codec.id();revision.cta="购买真实商品";project.revisions.append(revision);cases.append(project)
        for value in cases{XCTAssertFalse(EditorPracticeRules.allows(project:value,assets:[source]))}
    }
    func testOtherCustomerMediaOrForgedSourceHashDoesNotReceiveTheExerciseException() throws {
        var(project,source)=try fixture();source.hash=Codec.hash(Data("用户真实素材".utf8));XCTAssertFalse(EditorPracticeRules.allows(project:project,assets:[source]))
        (project,source)=try fixture();let media=Asset(workspaceID:"practice",name:"用户录屏",hash:"real-media",ext:"mp4",bytes:100,mediaType:"video/mp4");project.revisions[0].scenes[0].assetID=media.id
        XCTAssertFalse(EditorPracticeRules.allows(project:project,assets:[source,media]))
    }
    func testEveryClassicArtworkReferenceLeavesTheSyntheticPracticeException() throws {
        let(original,source)=try fixture()
        let external=Asset(workspaceID:"practice",name:"外部真实图像或录音",hash:"external",ext:"png",bytes:100,mediaType:"image")
        let blank=ClassicArtwork(gameplay:.platformer,sprites:[],sources:[])
        var variants:[ClassicArtwork]=[]
        var art=blank;art.sprites=[ClassicSprite(role:"hero",assetID:external.id)];variants.append(art)
        art=blank;art.sources=[ClassicSource(assetID:external.id,hash:external.hash,source:"真实外部素材",owner:"author",license:"test",evidenceID:"proof")];variants.append(art)
        art=blank;art.originalAssetIDs=[external.id];variants.append(art)
        art=blank;art.audioCues=[ClassicAudioCue(assetID:external.id,startFrame:0,durationFrames:30)];variants.append(art)
        for artwork in variants {
            var project=original,revision=project.current;revision.id=Codec.id();revision.scenes[0].classicArtwork=artwork;project.revisions.append(revision)
            XCTAssertFalse(EditorPracticeRules.allows(project:project,assets:[source,external]))
        }
    }
    func testTagsDoNotTurnPracticeIntoPaidRightsOrInvalidateIt() throws {
        var(project,source)=try fixture();project.revisions[0].product!.tags=["练习分类"];project.tags=["首次操作"]
        XCTAssertTrue(EditorPracticeRules.allows(project:project,assets:[source]))
        project.revisions[0].product!.isExample=false;XCTAssertFalse(EditorPracticeRules.allows(project:project,assets:[source]))
    }
    func testSchemaTwoWalkthroughUsesFixedRealSourceWithoutProductOrHumanConfirmation()throws {
        let (project,source)=try contentFixture(),revision=project.current
        XCTAssertEqual(revision.schemaVersion,2);XCTAssertNil(revision.product)
        XCTAssertEqual(revision.contentContext?.name,LearningExample.contentProjectName)
        XCTAssertEqual(revision.contentContext?.assetIDs,[source.id]);XCTAssertNil(revision.contentContext?.courseMappings)
        XCTAssertEqual(revision.scenes.map(\.title),["从时间轴开始","让改动有据可查"])
        XCTAssertEqual(revision.scenes.map(\.body),["镜头按顺序组成作品。选中一个镜头，可以修改文字、位置与时长。","应用修改后会保存新版本。观看倍率仅影响预览；修改镜头速度才会改变成片时轴。"])
        XCTAssertEqual(revision.purpose,.education);XCTAssertTrue(revision.cta.isEmpty)
        XCTAssertFalse(source.pages[0].confirmed);XCTAssertFalse(revision.review.text);XCTAssertFalse(revision.review.rights)
        XCTAssertFalse(revision.review.fullPreview);XCTAssertFalse(revision.review.sound);XCTAssertFalse(revision.review.captions)
        XCTAssertTrue(revision.scenes.allSatisfy{$0.narrativeSources==nil && $0.voice==nil && $0.narration.isEmpty})
        XCTAssertTrue(EditorPracticeRules.allows(project:project,assets:[source]))
        XCTAssertNoThrow(try MacCommerceRules.authorizeProjectChanges(before:[],after:[project],assets:[source],entitledProductIDs:[],checking:false))
        XCTAssertNoThrow(try MacCommerceRules.authorizeProjectChanges(before:[],after:[project],assets:[source],entitledProductIDs:[],checking:true))
    }
    func testSchemaTwoPracticeAllowsTextTimingLayoutAndRandomOriginalContextIDs()throws {
        let (original,source)=try contentFixture()
        let another=try LearningExample.contentProject(workspaceID:"practice",asset:source)
        XCTAssertNotEqual(original.current.contentContext?.id,another.current.contentContext?.id)
        XCTAssertTrue(EditorPracticeRules.allows(project:another,assets:[source]))
        var scene=original.current.scenes[0]
        scene.title="自己修改标题";scene.body="练习修改正文";scene.durationFrames=150
        scene.x=0.3;scene.y=0.6;scene.scale=0.9;scene.speed=1.25;scene.pauseFrames=15;scene.color="2468AC"
        scene.keyframes=[Keyframe(frame:0,x:0.3,y:0.6,scale:0.9),Keyframe(frame:149,x:0.4,y:0.6,scale:1)]
        scene.captions=[Caption(text:"自己校对的练习字幕",startFrame:0,endFrame:100)]
        scene.layers=[SceneLayer(kind:.text,text:"文字元素位置练习",endFrame:150)]
        let changed=try Editor.apply([.replaceScene(scene.id,scene),.aspect(.portrait)],to:original,baseRevision:original.current.id,assets:[source],message:"实际文字时间与布局练习")
        XCTAssertTrue(EditorPracticeRules.allows(project:changed,assets:[source]))
        XCTAssertNoThrow(try MacCommerceRules.authorizeProjectChanges(before:[original],after:[changed],assets:[source],entitledProductIDs:[],checking:false))
    }
    func testSchemaTwoPracticeRequiresExactSourceBytesTextTypeAndWorkspace()throws {
        let (project,source)=try contentFixture()
        let changes:[(String,(inout Asset)->Void)]=[
            ("hash",{$0.hash=Codec.hash(Data("不是自带说明".utf8))}),
            ("bytes",{$0.bytes+=1}),("text",{$0.pages[0].text+="真实客户内容"}),
            ("workspace",{$0.workspaceID="foreign"}),("type",{$0.mediaType="audio"}),
            ("extension",{$0.ext="wav"}),("missing page",{$0.pages=[]}),
            ("source notes",{$0.pages[0].notes="外部资料"}),("OCR",{$0.pages[0].requiresOCR=true}),
            ("source evidence",{$0.evidenceID="foreign-proof"})
        ]
        for (label,change) in changes {
            var forged=source;change(&forged)
            XCTAssertFalse(EditorPracticeRules.allows(project:project,assets:[forged]),label)
            XCTAssertThrowsError(try LearningExample.contentProject(workspaceID:"practice",asset:forged),label)
        }
        var renamed=source;renamed.name="名字和标签不是许可";renamed.tags=["普通资料"]
        XCTAssertTrue(EditorPracticeRules.allows(project:project,assets:[renamed]))
    }
    func testSchemaTwoNameAndTagsCannotAuthorizeForgedOriginalOrOrdinaryProject()throws {
        let (original,source)=try contentFixture()
        var forged=original;forged.tags=["免费练习"];forged.revisions[0].scenes[0].body="这是客户实际作品，不是固定原始练习"
        XCTAssertFalse(EditorPracticeRules.allows(project:forged,assets:[source]))
        let normal=try Planner.create(workspaceID:"practice",name:LearningExample.contentProjectName,scenes:[Scene(title:"从时间轴开始",body:"自己的真实视频")])
        var sameName=Project(workspaceID:"practice",name:LearningExample.contentProjectName,revision:normal);sameName.tags=["练习"]
        XCTAssertFalse(EditorPracticeRules.allows(project:sameName,assets:[source]))
        XCTAssertThrowsError(try MacCommerceRules.authorizeEditor(entitledProductIDs:[],checking:false,project:sameName,assets:[source]))
        let empty=Project(workspaceID:"practice",name:LearningExample.contentProjectName,revision:try Planner.create(workspaceID:"practice",name:LearningExample.contentProjectName,scenes:[]))
        XCTAssertThrowsError(try MacCommerceRules.authorizeProjectChanges(before:[],after:[empty],assets:[source],entitledProductIDs:[],checking:false))
        forged=original;forged.revisions[0].contentContext!.assetIDs=[]
        XCTAssertFalse(EditorPracticeRules.allows(project:forged,assets:[source]))
    }
    func testSchemaTwoPurposeCTAContextOrBriefCannotBecomeRealProduction()throws {
        let (original,source)=try contentFixture()
        let changes:[(String,(inout Revision)->Void)]=[
            ("purpose",{$0.purpose = .course}),("CTA",{$0.cta="联系客户交付"}),
            ("context name",{$0.contentContext!.name="真实作品"}),
            ("context ID",{$0.contentContext!.id=Codec.id()}),
            ("context assets",{$0.contentContext!.assetIDs.append("external")}),
            ("course mapping",{$0.contentContext!.courseMappings=[]}),
            ("commercial brief",{$0.productionBrief=ProductionBrief(objective:"真实客户制作",intendedUse:"商业交付",commercialDisclosure:"商业内容")}),
            ("music even using source ID",{$0.musicAssetID=source.id})
        ]
        for (label,change) in changes {
            var project=original,revision=project.current;revision.id=Codec.id();revision.number+=1;change(&revision);project.revisions.append(revision)
            XCTAssertFalse(EditorPracticeRules.allows(project:project,assets:[source]),label)
            XCTAssertThrowsError(try MacCommerceRules.authorizeProjectChanges(before:[original],after:[project],assets:[source],entitledProductIDs:[],checking:false),label)
        }
    }
    func testSchemaTwoPracticeRejectsMediaVoicesAdvancedScenesAndHiddenSources()throws {
        let (original,source)=try contentFixture()
        let changes:[(String,(inout Scene)->Void)]=[
            ("real asset",{$0.assetID="external-media"}),
            ("voice",{$0.voice=VoiceTake(assetID:source.id,textDigest:"synthetic",durationFrames:30,method:"external")}),
            ("narration",{$0.narration="需要真实声音的正文"}),
            ("cartoon",{$0.kind = .cartoon}),("simulation",{$0.kind = .simulation}),
            ("hidden simulation",{$0.simulation.initial+=1}),
            ("classic artwork",{$0.classicArtwork=ClassicArtwork(gameplay:.platformer,sprites:[],sources:[])}),
            ("character",{$0.characterProfile=CharacterProfile(name:"真实角色",voiceAssetID:source.id)}),
            ("narrative",{$0.narrativeSources=[NarrativeSource(assetID:source.id,excerpt:"另一个摘录")]}),
            ("course",{$0.courseMappingIDs=["external-mapping"]}),
            ("evidence",{$0.evidenceIDs=["external-evidence"]}),
            ("hidden layer source",{$0.layers=[SceneLayer(kind:.rectangle,assetID:source.id,endFrame:30)]})
        ]
        for (label,change) in changes {
            var project=original,revision=project.current;revision.id=Codec.id();revision.number+=1;change(&revision.scenes[0]);project.revisions.append(revision)
            XCTAssertFalse(EditorPracticeRules.allows(project:project,assets:[source]),label)
        }
    }
    func testSchemaTwoSyntheticLastVersionCannotHideEarlierRealMediaVersion()throws {
        let (original,source)=try contentFixture()
        var project=original,hidden=original.current;hidden.id=Codec.id();hidden.number=2;hidden.scenes[0].kind = .video;hidden.scenes[0].assetID="external"
        project.revisions.append(hidden)
        var synthetic=original.current;synthetic.id=Codec.id();synthetic.number=3;project.revisions.append(synthetic)
        XCTAssertFalse(EditorPracticeRules.allows(project:project,assets:[source]))
        XCTAssertThrowsError(try MacCommerceRules.authorizeProjectChanges(before:[original],after:[project],assets:[source],entitledProductIDs:[],checking:false))
    }
}
