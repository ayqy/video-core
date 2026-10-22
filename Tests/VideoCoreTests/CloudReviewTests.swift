import XCTest
@testable import VideoCore

final class CloudReviewTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1_780_000_000)
    private func fixture() throws -> (ScopedRevision,ScopedArtifact) {
        let product=Product(workspaceID:"private-w",sku:"isolated-cloud-rules",name:"隔离规则材料",checkout:"https://example.org/course",audience:"测试对象",task:"核对共享边界",outcome:"查看指定版本",prerequisite:"无",scope:"规则测试",prices:[Price(money:Money(1),from:.distantPast,source:"isolated-test",verified:true)])
        var revision=Revision(product:product,purpose:.education,aspect:.portrait,scenes:[Scene(title:"实际版本片段",body:"仅分享此版实际内容。",durationFrames:90)],cta:"核对一次来源")
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[],evidence:[],now:now)
        let preview=ScopedArtifact(id:"job:preview",jobID:"one-job",mime:"video/mp4",sha256:Codec.hash(Data("isolated preview bytes".utf8)),bytes:22)
        let scope=ScopedRevision(projectID:"one-project",projectName:"规则测试共享",revision:revision,comments:[],assets:[],evidence:[],artifacts:[preview],legacyMaterialsUnfrozen:false)
        return(scope,preview)
    }
    private func envelope() throws -> CloudReviewEnvelope {let(scope,preview)=try fixture();return try CloudReviewRules.prepare(scope:scope,preview:preview,role:.brandReviewer,expiresAt:now.addingTimeInterval(3600),now:now)}
    func testSharedEnvelopeFreezesOneVersionAndOneSelectedPreviewAndDropsLocalNames() throws {
        var(scope,preview)=try fixture();scope.comments=[Comment(revisionID:scope.revision.id,sceneID:nil,frame:0,element:"整片",text:"本机批注",author:"本机任意姓名")];scope.revision.review.reviewer="非服务器身份";scope.revision.review.text=true
        var other=preview;other.id="another";other.jobID="different";scope.artifacts.append(other)
        let value=try CloudReviewRules.prepare(scope:scope,preview:preview,role:.collaborator,expiresAt:now.addingTimeInterval(300),now:now)
        XCTAssertTrue(value.scope.comments.isEmpty);XCTAssertNil(value.scope.revision.review.reviewer);XCTAssertEqual(value.scope.artifacts.map(\.id),[preview.id]);XCTAssertEqual(value.revisionDigest,try scope.revision.contentDigest())
        let text=String(data:try Codec.data(value),encoding:.utf8)!;XCTAssertFalse(text.contains("本机任意姓名"));XCTAssertFalse(text.contains("非服务器身份"));XCTAssertFalse(text.contains("different"))
    }
    func testCannotSmuggleUnselectedPreviewOrRevisionMutation() throws {
        let(scope,preview)=try fixture();var other=preview;other.id="forged";XCTAssertThrowsError(try CloudReviewRules.prepare(scope:scope,preview:other,role:.brandReviewer,expiresAt:now.addingTimeInterval(300),now:now))
        var value=try envelope();value.scope.revision.scenes[0].body="改写送审内容";XCTAssertThrowsError(try CloudReviewRules.validate(value,now:now))
    }
    func testUnreferencedMaterialsAndOtherCourseMappingsAreRefused() throws {
        var(scope,preview)=try fixture();scope.assets=[Asset(workspaceID:"other-client",name:"其他客户文件",hash:"unrelated",ext:"txt",bytes:1,mediaType:"text")]
        XCTAssertThrowsError(try CloudReviewRules.prepare(scope:scope,preview:preview,role:.brandReviewer,expiresAt:now.addingTimeInterval(300),now:now))
        (scope,preview)=try fixture();scope.revision.product.courseMappings=[CourseMapping(title:"未引用",knowledge:"其他课程",audience:"其他人",task:"其他任务",outcome:"其他成果",prerequisite:"无",assetID:"missing",rangeKind:.whole)]
        XCTAssertThrowsError(try CloudReviewRules.prepare(scope:scope,preview:preview,role:.brandReviewer,expiresAt:now.addingTimeInterval(300),now:now))
    }
    func testPrivateAcceptedServerOwnerIdentityIsRequiredAndCollaborationCannotRewritePayload() throws {
        let valid=CloudReviewServerProof(ownerID:"cloud-owner",creatorID:"cloud-owner",modifierID:"cloud-owner",privateShare:true,accepted:true,canRead:true)
        XCTAssertNoThrow(try CloudReviewRules.authorize(valid))
        var cases:[CloudReviewServerProof]=[];var proof=valid;proof.modifierID="collaborator";cases.append(proof);proof=valid;proof.creatorID="forged-owner";cases.append(proof);proof=valid;proof.privateShare=false;cases.append(proof);proof=valid;proof.accepted=false;cases.append(proof);proof=valid;proof.canRead=false;cases.append(proof);proof=valid;proof.ownerID="";cases.append(proof)
        for value in cases {XCTAssertThrowsError(try CloudReviewRules.authorize(value))}
    }
    func testExpiryAndUnfrozenLegacyRevisionNeverReturnAnOfflineGrant() throws {
        let value=try envelope();XCTAssertThrowsError(try CloudReviewRules.validate(value,now:value.expiresAt))
        var(scope,preview)=try fixture();scope.legacyMaterialsUnfrozen=true;XCTAssertThrowsError(try CloudReviewRules.prepare(scope:scope,preview:preview,role:.brandReviewer,expiresAt:now.addingTimeInterval(300),now:now))
        scope.legacyMaterialsUnfrozen=false;scope.revision.dependencies=nil;XCTAssertThrowsError(try CloudReviewRules.prepare(scope:scope,preview:preview,role:.brandReviewer,expiresAt:now.addingTimeInterval(300),now:now))
    }
    func testPermissionRecordMustPermitCloudUploadAndRemainValid() throws {
        var(scope,preview)=try fixture();var evidence=Evidence(workspaceID:"private-w",title:"测试许可",source:"isolated-license-source",claim:"限本次预览",owner:"测试权利人",commercialAllowed:false,uploadConsent:false,verified:true);evidence.checkedAt=now.addingTimeInterval(-60);scope.evidence=[evidence];scope.revision.scenes[0].evidenceIDs=[evidence.id];scope.revision.dependencies=try DependencyRules.freeze(revision:scope.revision,assets:[],evidence:[evidence],now:now)
        XCTAssertThrowsError(try CloudReviewRules.prepare(scope:scope,preview:preview,role:.brandReviewer,expiresAt:now.addingTimeInterval(300),now:now))
        evidence.uploadConsent=true;scope.evidence=[evidence];scope.revision.dependencies=try DependencyRules.freeze(revision:scope.revision,assets:[],evidence:[evidence],now:now)
        XCTAssertNoThrow(try CloudReviewRules.prepare(scope:scope,preview:preview,role:.brandReviewer,expiresAt:now.addingTimeInterval(300),now:now))
        evidence.expiresAt=now.addingTimeInterval(-1);scope.evidence=[evidence];scope.revision.dependencies=try DependencyRules.freeze(revision:scope.revision,assets:[],evidence:[evidence],now:now);XCTAssertThrowsError(try CloudReviewRules.prepare(scope:scope,preview:preview,role:.brandReviewer,expiresAt:now.addingTimeInterval(300),now:now))
    }
    func testCommentsCannotClaimAnotherVersionOrElementOrFutureServerTime() throws {
        let value=try envelope();var annotation=CloudReviewAnnotation(id:"server-record",revisionID:value.scope.revision.id,revisionDigest:value.revisionDigest,sceneID:nil,frame:1,element:"整片",text:"请核对片段",authorID:"hash-of-server-creator",createdAt:now)
        XCTAssertNoThrow(try CloudReviewRules.validateAnnotation(annotation,envelope:value,now:now))
        annotation.revisionID="another-revision";XCTAssertThrowsError(try CloudReviewRules.validateAnnotation(annotation,envelope:value,now:now));annotation.revisionID=value.scope.revision.id;annotation.element="价格";XCTAssertThrowsError(try CloudReviewRules.validateAnnotation(annotation,envelope:value,now:now));annotation.element="整片";annotation.createdAt=now.addingTimeInterval(3600);XCTAssertThrowsError(try CloudReviewRules.validateAnnotation(annotation,envelope:value,now:now))
    }
    func testCloudCommentDoesNotApproveAnUnrelatedVersionOrCompleteLocalQA() throws {
        let value=try envelope();let data=try Codec.data(value);XCTAssertFalse(value.scope.revision.review.complete);XCTAssertFalse(String(data:data,encoding:.utf8)!.contains("provider"))
        var changed=value;changed.scope.comments=[Comment(revisionID:value.scope.revision.id,sceneID:nil,frame:0,element:"整片",text:"伪认证意见",author:"fake")];XCTAssertThrowsError(try CloudReviewRules.validate(changed,now:now))
    }
}
