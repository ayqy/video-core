import XCTest
@testable import VideoCore

final class DependencyTests: XCTestCase {
    private func fixtures() throws -> (Product, Asset, Evidence, CourseMapping) {
        let workspace="materials-workspace"
        var asset=Asset(workspaceID:workspace,name:"course.pdf",hash:String(repeating:"a",count:64),ext:"pdf",bytes:100,mediaType:"application/pdf")
        var page1=CoursePage(number:1,text:"使用可观察输入和输出解释上下文边界");page1.confirmed=true
        var page2=CoursePage(number:2,text:"第二个独立知识点");page2.confirmed=true;asset.pages=[page1,page2]
        let evidence=Evidence(workspaceID:workspace,title:"课程作者授权",source:"已签署课程使用许可",claim:"允许引用课程说明与演示",owner:"原作者",commercialAllowed:true,verified:true)
        asset.evidenceID=evidence.id
        let mapping=CourseMapping(title:"上下文边界",knowledge:"上下文容量有限",audience:"初学者",task:"辨别输入是否超限",outcome:"正确指出容量边界",prerequisite:"会使用聊天界面",assetID:asset.id,rangeKind:.pages,start:1,end:1,evidenceIDs:[evidence.id],confirmed:true)
        var product=Product(workspaceID:workspace,sku:"existing",name:"已有课程",checkout:"https://example.com/course",audience:"初学者",task:"辨别输入是否超限",outcome:"正确指出容量边界",prerequisite:"会使用聊天界面",scope:"上下文课程",prices:[Price(money:Money(99),from:Date(timeIntervalSince1970:0),source:"已有商品页",verified:true)])
        product.courseMappings=[mapping]
        return(product,asset,evidence,mapping)
    }
    func testMappingRequiresActualBoundedPagesAndConfirmedText() throws {
        let (product,asset,evidence,original)=try fixtures()
        try original.validate(workspaceID:product.workspaceID,assets:[asset],evidence:[evidence])
        var mapping=original;mapping.end=3
        XCTAssertThrowsError(try mapping.validate(workspaceID:product.workspaceID,assets:[asset],evidence:[evidence]))
        var scanned=asset;scanned.pages[0].confirmed=false;scanned.pages[0].requiresOCR=true;scanned.pages[0].text=""
        XCTAssertThrowsError(try original.validate(workspaceID:product.workspaceID,assets:[scanned],evidence:[evidence]))
    }
    func testMappingsAndSceneReferencesCannotCrossWorkspace() throws {
        let(product,asset,evidence,mapping)=try fixtures()
        var foreign=asset;foreign.workspaceID="foreign"
        XCTAssertThrowsError(try mapping.validate(workspaceID:product.workspaceID,assets:[foreign],evidence:[evidence]))
        var scene=Scene(title:"教学",body:"内容");scene.assetID=foreign.id
        let revision=Revision(product:product,purpose:.course,aspect:.portrait,scenes:[scene],cta:product.checkout)
        XCTAssertThrowsError(try DependencyRules.freeze(revision:revision,assets:[foreign],evidence:[evidence]))
    }
    func testTimeRangeUsesRealMediaLengthAndRespectsSceneLock() throws {
        var(product,asset,evidence,mapping)=try fixtures()
        asset.mediaType="video/mp4";asset.durationFrames=900;asset.pages=[]
        mapping.rangeKind = .time;mapping.start=300;mapping.end=600;product.courseMappings=[mapping]
        try mapping.validate(workspaceID:product.workspaceID,assets:[asset],evidence:[evidence])
        let result=try mapping.applying(to:Scene(title:"演示",body:"独立镜头",durationFrames:180),product:product,assets:[asset],evidence:[evidence])
        XCTAssertEqual(result.sourceStartFrame,300);XCTAssertEqual(result.sourceEndFrame,600);XCTAssertEqual(result.assetID,asset.id);XCTAssertEqual(result.courseMappingIDs,[mapping.id])
        var locked=result;locked.locked=true
        XCTAssertThrowsError(try mapping.applying(to:locked,product:product,assets:[asset],evidence:[evidence]))
        mapping.end=901
        XCTAssertThrowsError(try mapping.validate(workspaceID:product.workspaceID,assets:[asset],evidence:[evidence]))
    }
    func testFrozenPageDependencyIgnoresUnusedPageButInvalidatesReferencedPage() throws {
        let(product,asset,evidence,mapping)=try fixtures()
        var scene=Scene(title:"教学",body:"仅第一知识点");scene.courseMappingIDs=[mapping.id]
        var revision=Revision(product:product,purpose:.course,aspect:.portrait,scenes:[scene],cta:product.checkout)
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[asset],evidence:[evidence])
        XCTAssertTrue(DependencyRules.diff(revision:revision,assets:[asset],evidence:[evidence]).isEmpty)
        var otherPage=asset;otherPage.pages[1].text="修订不相关的第二页"
        XCTAssertTrue(DependencyRules.diff(revision:revision,assets:[otherPage],evidence:[evidence]).isEmpty)
        otherPage.pages[0].text="第一知识点已修改"
        let changes=DependencyRules.diff(revision:revision,assets:[otherPage],evidence:[evidence])
        XCTAssertTrue(changes.contains{$0.id=="asset:"+asset.id+":changed" && $0.sceneIDs==[scene.id]})
        XCTAssertEqual(revision.dependencies?.records.first(where:{$0.kind == .asset})?.asset?.pages.first?.text,asset.pages[0].text)
    }
    func testEvidenceExpiryInvalidatesOnlyReferencingSceneAndPreservesOriginal() throws {
        let(product,asset,original,mapping)=try fixtures()
        let now=Date(timeIntervalSince1970:2_000_000)
        var evidence=original;evidence.expiresAt=now.addingTimeInterval(60)
        var scene=Scene(title:"实际教学",body:"说明");scene.courseMappingIDs=[mapping.id]
        let unrelated=Scene(title:"独立片头",body:"无源依赖")
        var revision=Revision(product:product,purpose:.course,aspect:.portrait,scenes:[scene,unrelated],cta:product.checkout)
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[asset],evidence:[evidence],now:now)
        XCTAssertTrue(DependencyRules.diff(revision:revision,assets:[asset],evidence:[evidence],now:now).isEmpty)
        let expired=DependencyRules.diff(revision:revision,assets:[asset],evidence:[evidence],now:now.addingTimeInterval(61))
        XCTAssertTrue(expired.contains{$0.reason == .expired && $0.sceneIDs==[scene.id]})
        XCTAssertEqual(revision.dependencies?.records.first(where:{$0.kind == .evidence})?.evidence?.expiresAt,evidence.expiresAt)
        var revoked=evidence;revoked.commercialAllowed=false
        XCTAssertTrue(DependencyRules.diff(revision:revision,assets:[asset],evidence:[revoked],now:now).contains{$0.reason == .permission})
    }
    func testAddingSourceToEarlierSnapshotRequiresNewFreeze() throws {
        let(product,asset,evidence,_)=try fixtures()
        var scene=Scene(title:"片头",body:"无素材")
        var revision=Revision(product:product,purpose:.course,aspect:.portrait,scenes:[scene],cta:product.checkout)
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[asset],evidence:[evidence])
        scene.assetID=asset.id;revision.scenes=[scene]
        XCTAssertTrue(DependencyRules.diff(revision:revision,assets:[asset],evidence:[evidence]).contains{$0.id=="graph"})
    }
    func testLegacyRevisionDecodesWithoutNewOptionalFields() throws {
        let(product,_,_,_)=try fixtures()
        let revision=Revision(product:product,purpose:.course,aspect:.portrait,scenes:[Scene(title:"保留",body:"旧工程")],cta:product.checkout)
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(revision)) as? [String:Any])
        json.removeValue(forKey:"dependencies")
        var p=try XCTUnwrap(json["product"] as? [String:Any]);p.removeValue(forKey:"courseMappings");json["product"]=p
        let decoded=try Codec.decoder().decode(Revision.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertNil(decoded.dependencies);XCTAssertNil(decoded.product!.courseMappings);XCTAssertNil(decoded.scenes[0].courseMappingIDs)
    }
    func testSourceEditPreservesHistoryAndSkipsUnrelatedPagesAndWorkspace() throws {
        let(product,asset,evidence,mapping)=try fixtures()
        var scene=Scene(title:"教学",body:"第一页");scene.courseMappingIDs=[mapping.id]
        var revision=Revision(product:product,purpose:.course,aspect:.portrait,scenes:[scene],cta:product.checkout)
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[asset],evidence:[evidence]);revision.review.text=true
        let project=Project(workspaceID:product.workspaceID,name:"引用第一页",revision:revision)
        var foreign=project;foreign.id="foreign-project";foreign.workspaceID="other"
        var database=Database();database.assets=[asset];database.evidence=[evidence];database.projects=[project,foreign]
        database.assets[0].pages[1].text="只改第二页"
        try DependencyRules.refreshDependents(in:&database,workspaceID:product.workspaceID,changedAssetIDs:[asset.id],reason:"校对")
        XCTAssertEqual(database.projects[0].revisions.count,1)
        database.assets[0].pages[0].text="第一页有实质修正"
        try DependencyRules.refreshDependents(in:&database,workspaceID:product.workspaceID,changedAssetIDs:[asset.id],reason:"校对")
        XCTAssertEqual(database.projects[0].revisions.count,2);XCTAssertEqual(database.projects[1].revisions.count,1)
        XCTAssertTrue(database.projects[0].revisions[0].review.text);XCTAssertFalse(database.projects[0].current.review.text)
        XCTAssertEqual(database.projects[0].current.parentID,revision.id)
        XCTAssertTrue(DependencyRules.diff(revision:database.projects[0].current,assets:database.assets,evidence:database.evidence).contains{$0.reason == .changed})
    }
    func testLayerImageAndCharacterVoiceRightsBelongToDependencyGraph() throws {
        let(product,asset,evidence,_)=try fixtures()
        var image=asset;image.id="layer-image";image.mediaType="image";image.pages=[]
        var voice=asset;voice.id="character-voice";voice.mediaType="audio";voice.durationFrames=180;voice.pages=[]
        var scene=Scene(title:"角色与图层",body:"原创教学")
        scene.layers=[SceneLayer(kind:.image,assetID:image.id,endFrame:scene.durationFrames)]
        scene.characterProfile=CharacterProfile(name:"原创老师",evidenceIDs:[evidence.id],voiceAssetID:voice.id)
        let revision=Revision(product:product,purpose:.course,aspect:.portrait,scenes:[scene],cta:product.checkout)
        let snapshot=try DependencyRules.freeze(revision:revision,assets:[image,voice],evidence:[evidence])
        XCTAssertTrue(snapshot.records.contains{$0.asset?.id==image.id && $0.sceneIDs==[scene.id]})
        XCTAssertTrue(snapshot.records.contains{$0.asset?.id==voice.id && $0.sceneIDs==[scene.id]})
        XCTAssertTrue(snapshot.records.contains{$0.evidence?.id==evidence.id && $0.sceneIDs==[scene.id]})
    }
    func testCyclicRightsGraphPropagatesEveryAffectedSceneWithoutLooping() throws {
        let(product,asset,original,_)=try fixtures()
        var first=asset;first.id="source-a";first.evidenceID="e1";first.pages=[]
        var second=asset;second.id="source-b";second.evidenceID="e2";second.pages=[]
        var third=asset;third.id="source-c";third.evidenceID="e2";third.pages=[]
        var e1=original;e1.id="e1";e1.assetID=second.id
        var e2=original;e2.id="e2";e2.assetID=first.id
        var sceneA=Scene(title:"场景甲",body:"实际素材甲");sceneA.assetID=first.id
        var sceneB=Scene(title:"场景乙",body:"实际素材乙");sceneB.assetID=third.id
        let revision=Revision(product:product,purpose:.course,aspect:.portrait,scenes:[sceneA,sceneB],cta:product.checkout)
        let snapshot=try DependencyRules.freeze(revision:revision,assets:[first,second,third],evidence:[e1,e2])
        let associated=try XCTUnwrap(snapshot.records.first{$0.asset?.id==second.id})
        XCTAssertEqual(Set(associated.sceneIDs),[sceneA.id,sceneB.id]);XCTAssertEqual(snapshot.records.count,5)
    }
}
