import XCTest
@testable import VideoCore

final class CloudProposalTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1_780_000_000)
    private func fixture()throws->(CloudReviewEnvelope,ScopedRevision,Project,CloudStoryboardProposal) {
        let product=Product(workspaceID:"proposal-w",sku:"existing-sku",name:"隔离协作规则资料",checkout:"https://example.org/course",audience:"既定受众",task:"核对分镜",outcome:"理解知识",prerequisite:"无",scope:"仅规则夹具",prices:[Price(money:Money(99),from:.distantPast,source:"isolated-test",verified:true)])
        var revision=Revision(product:product,purpose:.education,aspect:.portrait,scenes:[Scene(title:"第一段",body:"原来的知识点",narration:"原来的配音稿",durationFrames:180),Scene(title:"第二段",body:"保留的演示",durationFrames:180)],cta:"核对课程范围")
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[],evidence:[],now:now)
        var project=Project(workspaceID:product.workspaceID,name:"隔离协作规则工程",revision:revision);project.id="proposal-project"
        let preview=ScopedArtifact(id:"preview",jobID:"preview-job",mime:"video/mp4",sha256:Codec.hash(Data("isolated-preview".utf8)),bytes:16)
        let scope=ScopedRevision(projectID:project.id,projectName:project.name,revision:revision,comments:[],assets:[],evidence:[],artifacts:[preview],legacyMaterialsUnfrozen:false)
        let envelope=try CloudReviewRules.prepare(scope:scope,preview:preview,role:.collaborator,expiresAt:now.addingTimeInterval(3600),now:now)
        var change=CloudSceneChange(scene:revision.scenes[0],index:1);change.title="建议的新标题";change.body="补充解释后的知识点";change.narration="更清楚的配音稿";change.durationFrames=210
        let proposal=CloudStoryboardProposal(id:"proposal-one",revisionID:revision.id,revisionDigest:envelope.revisionDigest,sceneID:revision.scenes[0].id,sceneDigest:try Codec.digest(revision.scenes[0]),change:change,reason:"先说明边界再演示",authorID:"server-collaborator-hash",createdAt:now)
        return(envelope,scope,project,proposal)
    }
    func testOnlyIndependentWritableCollaboratorCanPropose()throws {
        let(envelope,_,_,_)=try fixture()
        XCTAssertNoThrow(try CloudProposalRules.authorizeSubmission(envelope:envelope,isOwner:false,canWrite:true,actorID:"collaborator",ownerID:"owner",now:now))
        XCTAssertThrowsError(try CloudProposalRules.authorizeSubmission(envelope:envelope,isOwner:true,canWrite:true,actorID:"owner",ownerID:"owner",now:now))
        XCTAssertThrowsError(try CloudProposalRules.authorizeSubmission(envelope:envelope,isOwner:false,canWrite:false,actorID:"collaborator",ownerID:"owner",now:now))
        XCTAssertThrowsError(try CloudProposalRules.authorizeSubmission(envelope:envelope,isOwner:false,canWrite:true,actorID:"",ownerID:"owner",now:now))
        var brand=envelope;brand.role = .brandReviewer
        XCTAssertThrowsError(try CloudProposalRules.authorizeSubmission(envelope:brand,isOwner:false,canWrite:true,actorID:"reviewer",ownerID:"owner",now:now))
        XCTAssertThrowsError(try CloudProposalRules.authorizeSubmission(envelope:envelope,isOwner:false,canWrite:true,actorID:"collaborator",ownerID:"owner",now:envelope.expiresAt))
    }
    func testStructuredDiffAndAcceptancePreserveProductOtherSceneAndSourceFields()throws {
        let(envelope,scope,project,proposal)=try fixture()
        let differences=try CloudProposalRules.differences(proposal,envelope:envelope)
        XCTAssertEqual(Set(differences.map(\.field)),Set(["标题","正文","旁白","原始时长（帧）","镜头顺序"]))
        let operations=try CloudProposalRules.edits(proposal,envelope:envelope,localScope:scope,project:project,now:now)
        let updated=try Editor.apply(operations,to:project,baseRevision:proposal.revisionID,assets:[],message:try CloudProposalRules.changeMessage(proposal))
        XCTAssertEqual(updated.revisions.count,2);XCTAssertEqual(updated.current.scenes.map(\.id),project.current.scenes.reversed().map(\.id))
        XCTAssertEqual(updated.current.scenes[0],project.current.scenes[1]);XCTAssertEqual(updated.current.scenes[1].title,proposal.change.title)
        XCTAssertEqual(try Codec.digest(updated.current.product!),try Codec.digest(project.current.product!));XCTAssertEqual(updated.current.cta,project.current.cta)
        XCTAssertEqual(updated.current.scenes[1].assetID,project.current.scenes[0].assetID);XCTAssertEqual(updated.current.scenes[1].evidenceIDs,project.current.scenes[0].evidenceIDs)
        XCTAssertFalse(updated.current.review.complete)
    }
    func testAnotherSceneRevisionDigestOrFutureCreatorCannotBeAccepted()throws {
        let(envelope,_,_,proposal)=try fixture()
        var wrong=proposal;wrong.sceneID="unshared-scene";XCTAssertThrowsError(try CloudProposalRules.validate(wrong,envelope:envelope,now:now))
        wrong=proposal;wrong.sceneDigest=String(repeating:"0",count:64);XCTAssertThrowsError(try CloudProposalRules.validate(wrong,envelope:envelope,now:now))
        wrong=proposal;wrong.revisionID="other-version";XCTAssertThrowsError(try CloudProposalRules.validate(wrong,envelope:envelope,now:now))
        wrong=proposal;wrong.revisionDigest=String(repeating:"0",count:64);XCTAssertThrowsError(try CloudProposalRules.validate(wrong,envelope:envelope,now:now))
        wrong=proposal;wrong.createdAt=now.addingTimeInterval(3600);XCTAssertThrowsError(try CloudProposalRules.validate(wrong,envelope:envelope,now:now))
        wrong=proposal;wrong.authorID="";XCTAssertThrowsError(try CloudProposalRules.validate(wrong,envelope:envelope,now:now))
    }
    func testUnknownProductWorkspaceAndMediaFieldsAreRejectedAtDecodeBoundary()throws {
        let(_,_,_,proposal)=try fixture()
        let data=try Codec.data(proposal.change)
        XCTAssertNoThrow(try Codec.decoder().decode(CloudSceneChange.self,from:data))
        for key in ["product","workspaceID","evidenceIDs","assetID","approved","price"] {
            var object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);object[key]="forged"
            XCTAssertThrowsError(try Codec.decoder().decode(CloudSceneChange.self,from:JSONSerialization.data(withJSONObject:object)))
        }
    }
    func testOldLocalBaseAndChangedLocalScopeConflictWithoutOverwriting()throws {
        let(envelope,scope,project,proposal)=try fixture()
        let changed=try Editor.apply([.cta("本机作者已更新")],to:project,baseRevision:project.current.id,assets:[],message:"本地并行修改")
        XCTAssertThrowsError(try CloudProposalRules.edits(proposal,envelope:envelope,localScope:scope,project:changed,now:now))
        var another=scope;another.revision.product!.prices[0].money=Money(200)
        XCTAssertThrowsError(try CloudProposalRules.edits(proposal,envelope:envelope,localScope:another,project:project,now:now))
        var cross=project;cross.workspaceID="different-customer"
        XCTAssertThrowsError(try CloudProposalRules.edits(proposal,envelope:envelope,localScope:scope,project:cross,now:now))
        XCTAssertEqual(changed.current.cta,"本机作者已更新")
    }
    func testLockedScenesInvalidTimingAndNoopCannotBecomeProposals()throws {
        var(envelope,_,_,proposal)=try fixture()
        proposal.change.targetIndex=10;XCTAssertThrowsError(try CloudProposalRules.validate(proposal,envelope:envelope,now:now))
        proposal.change.targetIndex=0;proposal.change.durationFrames=0;XCTAssertThrowsError(try CloudProposalRules.validate(proposal,envelope:envelope,now:now))
        proposal.change=CloudSceneChange(scene:envelope.scope.revision.scenes[0],index:0);XCTAssertThrowsError(try CloudProposalRules.validate(proposal,envelope:envelope,now:now))
        envelope.scope.revision.scenes[0].locked=true;envelope.revisionDigest=try envelope.scope.revision.contentDigest();proposal.revisionDigest=envelope.revisionDigest;proposal.sceneDigest=try Codec.digest(envelope.scope.revision.scenes[0]);proposal.change.title="锁定后提案"
        XCTAssertThrowsError(try CloudProposalRules.validate(proposal,envelope:envelope,now:now))
    }
    func testNarrationChangeClearsOldVoiceAndCaptionConfirmationUsingNormalEditor()throws {
        var(envelope,scope,project,proposal)=try fixture()
        var evidence=Evidence(workspaceID:project.workspaceID,title:"隔离声音规则许可",source:"isolated-rules-source",claim:"本规则夹具音轨",owner:"测试权利人",commercialAllowed:false,uploadConsent:true,verified:true);evidence.checkedAt=now
        var voice=Asset(workspaceID:project.workspaceID,name:"isolated-rules-voice",hash:String(repeating:"a",count:64),ext:"wav",bytes:1,mediaType:"audio",durationFrames:150);voice.evidenceID=evidence.id
        var base=project.current;base.scenes[0].voice=VoiceTake(assetID:voice.id,textDigest:try base.scenes[0].speechDigest(),durationFrames:150,method:"isolated-rule",listened:true);base.scenes[0].captions=[Caption(text:"原字幕",startFrame:0,endFrame:90,confirmed:true)];base.product!.assetIDs=[voice.id];base.dependencies=try DependencyRules.freeze(revision:base,assets:[voice],evidence:[evidence],now:now)
        project.revisions=[base];scope.revision=base;scope.assets=[voice];scope.evidence=[evidence]
        envelope=try CloudReviewRules.prepare(scope:scope,preview:scope.artifacts[0],role:.collaborator,expiresAt:now.addingTimeInterval(3600),now:now)
        proposal.revisionDigest=envelope.revisionDigest;proposal.sceneDigest=try Codec.digest(base.scenes[0])
        let operations=try CloudProposalRules.edits(proposal,envelope:envelope,localScope:scope,project:project,now:now)
        let updated=try Editor.apply(operations,to:project,baseRevision:base.id,assets:[voice],message:"接收分镜旁白")
        let scene=try XCTUnwrap(updated.current.scenes.first(where:{$0.id==proposal.sceneID}))
        XCTAssertNil(scene.voice);XCTAssertFalse(scene.captions[0].confirmed);XCTAssertTrue(updated.current.invalidated.contains("字幕对齐"))
    }
    func testCommittedRevisionRecoveryDoesNotApplyTwiceAndRejectsForgedMarker()throws {
        let(envelope,scope,project,proposal)=try fixture()
        XCTAssertNil(try CloudProposalRules.committedRevision(proposal,envelope:envelope,localScope:scope,project:project,now:now))
        let operations=try CloudProposalRules.edits(proposal,envelope:envelope,localScope:scope,project:project,now:now)
        var saved=try Editor.apply(operations,to:project,baseRevision:project.current.id,assets:[],message:try CloudProposalRules.changeMessage(proposal))
        let receipt=try XCTUnwrap(CloudProposalRules.committedRevision(proposal,envelope:envelope,localScope:scope,project:saved,now:now))
        XCTAssertEqual(receipt.revisionID,saved.current.id);XCTAssertEqual(receipt.revisionDigest,try saved.current.contentDigest());XCTAssertEqual(saved.revisions.count,2)
        saved.revisions[1].scenes[0].body="额外伪改"
        XCTAssertThrowsError(try CloudProposalRules.committedRevision(proposal,envelope:envelope,localScope:scope,project:saved,now:now))
    }
    func testOrdinaryCommittedProposalCannotAlsoChangeContentContextOrSchema()throws {
        var(envelope,scope,project,proposal)=try fixture()
        let base=try Planner.create(workspaceID:project.workspaceID,name:"普通教学工程",scenes:project.current.scenes)
        project.revisions=[base];scope.revision=base
        scope.revision.dependencies=try DependencyRules.freeze(revision:base,assets:[],evidence:[],now:now)
        project.revisions=[scope.revision]
        envelope=try CloudReviewRules.prepare(scope:scope,preview:scope.artifacts[0],role:.collaborator,expiresAt:now.addingTimeInterval(3600),now:now)
        proposal.revisionID=base.id;proposal.revisionDigest=envelope.revisionDigest
        let operations=try CloudProposalRules.edits(proposal,envelope:envelope,localScope:scope,project:project,now:now)
        let saved=try Editor.apply(operations,to:project,baseRevision:base.id,assets:[],message:try CloudProposalRules.changeMessage(proposal))
        XCTAssertNotNil(try CloudProposalRules.committedRevision(proposal,envelope:envelope,localScope:scope,project:saved,now:now))
        var tampered=saved;tampered.revisions[1].contentContext?.name="未审核的其他内容"
        XCTAssertThrowsError(try CloudProposalRules.committedRevision(proposal,envelope:envelope,localScope:scope,project:tampered,now:now))
        tampered=saved;tampered.revisions[1].schemaVersion=1
        XCTAssertThrowsError(try CloudProposalRules.committedRevision(proposal,envelope:envelope,localScope:scope,project:tampered,now:now))
    }
    func testProposalChangedAfterDiffDisplayRequiresExplicitReviewAgain()throws {
        let(_,_,_,proposal)=try fixture();let viewed=try Codec.digest(proposal)
        XCTAssertNoThrow(try CloudProposalRules.requireViewedDigest(proposal,expected:viewed))
        var altered=proposal;altered.change.body="查看差异之后另一份内容"
        XCTAssertThrowsError(try CloudProposalRules.requireViewedDigest(altered,expected:viewed))
    }
    func testOnlyOwnerReceiptForMatchingCommittedNewRevisionIsValid()throws {
        let(_,_,_,proposal)=try fixture()
        var receipt=CloudProposalReceipt(id:"accepted-proposal-one",proposalID:proposal.id,proposalDigest:try Codec.digest(proposal),applied:CloudProposalAppliedRevision(revisionID:"new-revision",revisionDigest:String(repeating:"a",count:64)),authorID:"server-owner",createdAt:now)
        XCTAssertNoThrow(try CloudProposalRules.validateReceipt(receipt,proposal:proposal,ownerID:"server-owner",now:now))
        receipt.authorID="collaborator";XCTAssertThrowsError(try CloudProposalRules.validateReceipt(receipt,proposal:proposal,ownerID:"server-owner",now:now))
        receipt.authorID="server-owner";receipt.applied.revisionID=proposal.revisionID;XCTAssertThrowsError(try CloudProposalRules.validateReceipt(receipt,proposal:proposal,ownerID:"server-owner",now:now))
        receipt.applied.revisionID="new-revision";receipt.proposalDigest="different-proposal";XCTAssertThrowsError(try CloudProposalRules.validateReceipt(receipt,proposal:proposal,ownerID:"server-owner",now:now))
    }
    func testProposalSystemCreatorMustBeUnchangedAndStillWritable()throws {
        let(envelope,_,_,_)=try fixture()
        let valid=CloudProposalServerProof(ownerID:"server-owner",creatorID:"server-writer",modifierID:"server-writer",activeWriter:true)
        XCTAssertEqual(try CloudProposalRules.authorizeRecord(valid,envelope:envelope,now:now),Codec.hash(Data("server-writer".utf8)))
        var altered=valid;altered.modifierID="another-writer";XCTAssertThrowsError(try CloudProposalRules.authorizeRecord(altered,envelope:envelope,now:now))
        altered=valid;altered.activeWriter=false;XCTAssertThrowsError(try CloudProposalRules.authorizeRecord(altered,envelope:envelope,now:now))
        altered=valid;altered.creatorID="server-owner";altered.modifierID="server-owner";XCTAssertThrowsError(try CloudProposalRules.authorizeRecord(altered,envelope:envelope,now:now))
    }
    func testShorteningCannotSilentlyCutExistingCaption()throws {
        var(envelope,scope,_,proposal)=try fixture()
        scope.revision.scenes[0].captions=[Caption(text:"不能静默截断",startFrame:100,endFrame:170)]
        scope.revision.dependencies=try DependencyRules.freeze(revision:scope.revision,assets:[],evidence:[],now:now)
        envelope=try CloudReviewRules.prepare(scope:scope,preview:scope.artifacts[0],role:.collaborator,expiresAt:now.addingTimeInterval(3600),now:now)
        proposal.revisionDigest=envelope.revisionDigest;proposal.sceneDigest=try Codec.digest(scope.revision.scenes[0]);proposal.change.durationFrames=120
        XCTAssertThrowsError(try CloudProposalRules.validate(proposal,envelope:envelope,now:now))
    }
}
