import XCTest
@testable import VideoCore

final class EditorPracticeTests:XCTestCase {
    private func fixture() throws -> (Project,Asset) {
        let bytes=Data(EditorPracticeRules.sourceText.utf8)
        let source=Asset(workspaceID:"practice",name:"离线练习.txt",hash:Codec.hash(bytes),ext:"txt",bytes:bytes.count,mediaType:"text")
        return(try LearningExample.project(workspaceID:"practice",asset:source),source)
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
}
