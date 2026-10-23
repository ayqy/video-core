import XCTest
@testable import VideoCore

final class MacCommerceRulesTests:XCTestCase{
    private let now=Date(timeIntervalSince1970:1_790_000_000)
    private func metadata(_ product:MacCommerceProduct = .editor)->MacTransactionMetadata{
        MacTransactionMetadata(productID:product.rawValue,bundleID:MacCommerceRules.bundleID,productType:"nonConsumable",purchaseDate:now.addingTimeInterval(-60))
    }
    func testThreeIndependentMacProductsDoNotRecognizeLegacyIOSBundleOrProduct()throws{
        XCTAssertEqual(MacCommerceRules.productIDs.count,3)
        for product in MacCommerceProduct.allCases{XCTAssertTrue(MacCommerceRules.current(metadata(product),runningBundleID:MacCommerceRules.bundleID,now:now))}
        var old=metadata();old.bundleID="com.ayqy.video";XCTAssertFalse(MacCommerceRules.current(old,runningBundleID:MacCommerceRules.bundleID,now:now))
        old=metadata();old.productID="com.ayqy.video.editor";XCTAssertFalse(MacCommerceRules.current(old,runningBundleID:MacCommerceRules.bundleID,now:now))
        XCTAssertFalse(MacCommerceRules.current(metadata(),runningBundleID:"other.app",now:now))
        XCTAssertFalse(MacCommerceRules.current(metadata(),runningBundleID:nil,now:now))
    }
    func testRefundExpirationUpgradeAndFutureTransactionNeverGrantMetadataEligibility()throws{
        for value in 0..<4{
            var data=metadata()
            switch value{case 0:data.revokedAt=now;case 1:data.expiresAt=now;case 2:data.upgraded=true;default:data.purchaseDate=now.addingTimeInterval(61)}
            XCTAssertFalse(MacCommerceRules.current(data,runningBundleID:MacCommerceRules.bundleID,now:now))
        }
    }
    func testEditorIsOneTimeButModulesCanUseAnExplicitRealSubscription()throws{
        var editor=metadata();editor.productType="autoRenewable";editor.expiresAt=now.addingTimeInterval(120)
        XCTAssertFalse(MacCommerceRules.current(editor,runningBundleID:MacCommerceRules.bundleID,now:now))
        var game=metadata(.game);game.productType="autoRenewable";game.expiresAt=now.addingTimeInterval(120)
        XCTAssertTrue(MacCommerceRules.current(game,runningBundleID:MacCommerceRules.bundleID,now:now))
        game.productType="consumable";XCTAssertFalse(MacCommerceRules.current(game,runningBundleID:MacCommerceRules.bundleID,now:now))
    }
    func testModuleMetadataNeverProvidesEditorOrCLIEntitlement()throws{
        let revision=Revision(contentContext:ContentContext(workspaceID:"w",name:"真实视频"),aspect:.landscape,scenes:[Scene(title:"自己的片段",body:"真实内容")])
        let project=Project(workspaceID:"w",name:"真实视频",revision:revision)
        XCTAssertThrowsError(try MacCommerceRules.authorizeEditor(entitledProductIDs:[MacCommerceProduct.game.rawValue,MacCommerceProduct.cartoon.rawValue],checking:false,project:project,assets:[]))
        XCTAssertThrowsError(try MacCommerceRules.authorizeEditor(entitledProductIDs:[MacCommerceProduct.editor.rawValue],checking:true,project:project,assets:[]))
        XCTAssertNoThrow(try MacCommerceRules.authorizeEditor(entitledProductIDs:[MacCommerceProduct.editor.rawValue],checking:false,project:project,assets:[]))
    }
    @MainActor func testOverlappingRefreshWaitsForNewestSnapshotAndDoesNotExposeStaleGrant()async{
        var reads=0,applied:[Int]=[]
        let cycle=CommerceRefreshCycle<Int>(read:{reads+=1;let value=reads;await Task.yield();return value},apply:{applied.append($0)})
        async let first:Void=cycle.refresh()
        await Task.yield()
        async let second:Void=cycle.refresh()
        _ = await(first,second)
        XCTAssertEqual(applied.last,reads)
        XCTAssertGreaterThanOrEqual(reads,1)
    }
    @MainActor func testUndeliveredPurchaseRemainsUnfinishedUntilRealDeliverySucceeds()async{
        var canDeliver=false,finished:[Int]=[]
        let processor=CommerceDeliveryCoordinator<Int,Int>(identity:{$0},deliver:{_ in canDeliver},finish:{finished.append($0)})
        let first=await processor.process(1);XCTAssertFalse(first);XCTAssertTrue(finished.isEmpty)
        canDeliver=true
        let delivered=await processor.process(1);XCTAssertTrue(delivered);XCTAssertEqual(finished,[1])
        let duplicate=await processor.process(1);XCTAssertTrue(duplicate);XCTAssertEqual(finished,[1])
    }
    func testEveryNewMacProjectOrVersionNeedsEditorWhileReadOnlyAndJobUpdatesDoNot()throws {
        let revision=try Planner.create(workspaceID:"w",name:"实际材料工程",aspect:.landscape,scenes:[Scene(title:"真实讲解",body:"来自实际材料")])
        let project=Project(workspaceID:"w",name:"实际材料工程",revision:revision)
        XCTAssertNoThrow(try MacCommerceRules.authorizeProjectChanges(before:[project],after:[project],assets:[],entitledProductIDs:[],checking:true))
        XCTAssertThrowsError(try MacCommerceRules.authorizeProjectChanges(before:[],after:[project],assets:[],entitledProductIDs:[MacCommerceProduct.game.rawValue],checking:false))
        var next=project;var second=revision;second.id=Codec.id();second.number=2;second.parentID=revision.id;next.revisions.append(second)
        XCTAssertThrowsError(try MacCommerceRules.authorizeProjectChanges(before:[project],after:[next],assets:[],entitledProductIDs:[],checking:false))
        XCTAssertNoThrow(try MacCommerceRules.authorizeProjectChanges(before:[project],after:[next],assets:[],entitledProductIDs:[MacCommerceProduct.editor.rawValue],checking:false))
    }
    func testDeclaredOfflinePracticeMayChangeTextButCannotBecomeRealMediaProject()throws {
        let text=EditorPracticeRules.sourceText
        let source=Asset(workspaceID:"w",name:"明确离线练习",hash:Codec.hash(Data(text.utf8)),ext:"txt",bytes:Data(text.utf8).count,mediaType:"text")
        let practice=try LearningExample.project(workspaceID:"w",asset:source)
        XCTAssertNoThrow(try MacCommerceRules.authorizeProjectChanges(before:[],after:[practice],assets:[source],entitledProductIDs:[],checking:false))
        let external=Asset(workspaceID:"w",name:"自己的实拍",hash:String(repeating:"d",count:64),ext:"mp4",bytes:1,mediaType:"video",durationFrames:180)
        var next=practice;var scene=practice.current.scenes[0];scene.assetID=external.id
        next=try Editor.apply([.replaceScene(scene.id,scene)],to:next,baseRevision:next.current.id,assets:[source,external],message:"改为实拍内容")
        XCTAssertThrowsError(try MacCommerceRules.authorizeProjectChanges(before:[practice],after:[next],assets:[source,external],entitledProductIDs:[],checking:false))
    }

}
