import Foundation
import XCTest
@testable import VideoCore
#if !CLOUD_REVIEW_LEASE_HOST_TEST
@testable import VideoMedia
#endif

final class CloudReviewPresentationLeaseTests: XCTestCase {
    private let now=Date(timeIntervalSince1970:1_792_750_000)

    func testInitialReadAndSameVersionRefreshPreserveDraftDecision() {
        var lease=CloudReviewPresentationLease()
        let first=lease.begin()
        XCTAssertEqual(lease.authorize(first,versionKey:"immutable-version",authorizedUntil:now.addingTimeInterval(10),active:true,now:now),.initial)
        let refresh=lease.begin()
        XCTAssertEqual(lease.authorize(refresh,versionKey:"immutable-version",authorizedUntil:now.addingTimeInterval(15),active:true,now:now.addingTimeInterval(5)),.refreshed)
        XCTAssertEqual(lease.authorizedUntil,now.addingTimeInterval(15))
    }

    func testReplacedVersionCannotCarryOldDraftIntoDifferentContent() {
        var lease=CloudReviewPresentationLease()
        let first=lease.begin()
        _=lease.authorize(first,versionKey:"version-one",authorizedUntil:now.addingTimeInterval(10),active:true,now:now)
        let refresh=lease.begin()
        XCTAssertEqual(lease.authorize(refresh,versionKey:"version-two",authorizedUntil:now.addingTimeInterval(15),active:true,now:now),.invalidated)
        XCTAssertNil(lease.versionKey);XCTAssertNil(lease.authorizedUntil)
        XCTAssertFalse(lease.isCurrent(refresh))
    }

    func testAccountInvalidationRejectsOldSuccessWithoutRestoringContent() {
        var lease=CloudReviewPresentationLease()
        let pending=lease.begin()
        lease.invalidate()
        XCTAssertEqual(lease.authorize(pending,versionKey:"old-account",authorizedUntil:now.addingTimeInterval(10),active:true,now:now),.stale)
        XCTAssertNil(lease.versionKey);XCTAssertNil(lease.authorizedUntil)
    }

    func testOldFailureCannotClearNewForegroundSession() {
        var lease=CloudReviewPresentationLease()
        let old=lease.begin()
        lease.invalidate()
        let fresh=lease.begin()
        XCTAssertEqual(lease.authorize(fresh,versionKey:"new-account",authorizedUntil:now.addingTimeInterval(10),active:true,now:now),.initial)
        XCTAssertFalse(lease.isCurrent(old))
        XCTAssertTrue(lease.isCurrent(fresh))
        XCTAssertEqual(lease.versionKey,"new-account")
    }

    func testOutOfOrderReadCannotReplaceMostRecentAuthorization() {
        var lease=CloudReviewPresentationLease()
        let old=lease.begin(),fresh=lease.begin()
        _=lease.authorize(fresh,versionKey:"current",authorizedUntil:now.addingTimeInterval(10),active:true,now:now)
        XCTAssertEqual(lease.authorize(old,versionKey:"old",authorizedUntil:now.addingTimeInterval(30),active:true,now:now),.stale)
        XCTAssertEqual(lease.versionKey,"current")
        XCTAssertEqual(lease.authorizedUntil,now.addingTimeInterval(10))
    }

    func testBackgroundCompletionIsRejectedAndRequiresFreshReadOnReturn() {
        var lease=CloudReviewPresentationLease()
        let pending=lease.begin()
        XCTAssertEqual(lease.authorize(pending,versionKey:"version",authorizedUntil:now.addingTimeInterval(10),active:false,now:now),.invalidated)
        XCTAssertNil(lease.versionKey);XCTAssertNil(lease.authorizedUntil)
        let foreground=lease.begin()
        XCTAssertEqual(lease.authorize(foreground,versionKey:"version",authorizedUntil:now.addingTimeInterval(10),active:true,now:now),.initial)
    }

    func testExpiryAtExactBoundaryInvalidatesOutstandingRefresh() {
        var lease=CloudReviewPresentationLease()
        let first=lease.begin()
        _=lease.authorize(first,versionKey:"version",authorizedUntil:now.addingTimeInterval(10),active:true,now:now)
        let pending=lease.begin()
        XCTAssertFalse(lease.expire(now:now.addingTimeInterval(9.999)))
        XCTAssertTrue(lease.expire(now:now.addingTimeInterval(10)))
        XCTAssertEqual(lease.authorize(pending,versionKey:"version",authorizedUntil:now.addingTimeInterval(20),active:true,now:now.addingTimeInterval(10)),.stale)
        XCTAssertNil(lease.versionKey);XCTAssertNil(lease.authorizedUntil)
        XCTAssertFalse(lease.expire(now:now.addingTimeInterval(20)))
    }

    func testAlreadyExpiredReadCannotDisplayContent() {
        for expiry in [now,now.addingTimeInterval(-1)] {
            var lease=CloudReviewPresentationLease()
            let pending=lease.begin()
            XCTAssertEqual(lease.authorize(pending,versionKey:"version",authorizedUntil:expiry,active:true,now:now),.invalidated)
            XCTAssertNil(lease.versionKey);XCTAssertNil(lease.authorizedUntil)
        }
    }

    func testEmptyVersionCannotAuthorizeUnpinnedDraft() {
        var lease=CloudReviewPresentationLease()
        let pending=lease.begin()
        XCTAssertEqual(lease.authorize(pending,versionKey:"",authorizedUntil:now.addingTimeInterval(10),active:true,now:now),.invalidated)
        XCTAssertNil(lease.versionKey)
    }

    private func inputError(reason:String="明确的修改理由",durationFrames:Int=210,captioned:Bool=false)throws->Error {
        var scene=Scene(title:"已授权的分镜",body:"教学说明",narration:"真实讲稿",durationFrames:180)
        if captioned {scene.captions=[Caption(text:"不可截断",startFrame:100,endFrame:170)]}
        var revision=try Planner.create(workspaceID:"lease-rules",name:"普通内容提案",scenes:[scene])
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[],evidence:[],now:now)
        let preview=ScopedArtifact(id:"preview",jobID:"isolated-preview",mime:"video/mp4",sha256:String(repeating:"a",count:64),bytes:16)
        let scope=ScopedRevision(projectID:"isolated-project",projectName:"普通内容提案",revision:revision,comments:[],assets:[],evidence:[],artifacts:[preview],legacyMaterialsUnfrozen:false)
        let envelope=try CloudReviewRules.prepare(scope:scope,preview:preview,role:.collaborator,expiresAt:now.addingTimeInterval(3600),now:now)
        var change=CloudSceneChange(scene:scene,index:0);change.title="更清楚的标题";change.durationFrames=durationFrames
        let proposal=CloudStoryboardProposal(id:"input-correction",revisionID:revision.id,revisionDigest:envelope.revisionDigest,sceneID:scene.id,sceneDigest:try Codec.digest(scene),change:change,reason:reason,authorID:"isolated-server-author",createdAt:now)
        do {try CloudProposalRules.validate(proposal,envelope:envelope,now:now);XCTFail("无效输入不得通过提案规则");return VideoError.unavailable("unexpected validation success")}
        catch{return error}
    }

    private func authorizedLease()->(CloudReviewPresentationLease,CloudReviewPresentationLease.Request) {
        var lease=CloudReviewPresentationLease()
        let first=lease.begin()
        _=lease.authorize(first,versionKey:"immutable-version",authorizedUntil:now.addingTimeInterval(10),active:true,now:now)
        let submit=lease.begin()
        return(lease,submit)
    }

    func testOverlongActualProposalReasonRemainsCorrectableInsideLease()throws {
        let error=try inputError(reason:String(repeating:"字",count:1001))
        XCTAssertEqual((error as? VideoError)?.code,"invalid_input")
        let(lease,request)=authorizedLease()
        XCTAssertTrue(lease.canPreserveDraft(after:error,request:request,active:true,now:now))
        XCTAssertEqual(lease.versionKey,"immutable-version")
    }

    func testActualCaptionTruncationErrorRemainsCorrectableInsideLease()throws {
        let error=try inputError(durationFrames:120,captioned:true)
        XCTAssertEqual((error as? VideoError)?.code,"invalid_input")
        let(lease,request)=authorizedLease()
        XCTAssertTrue(lease.canPreserveDraft(after:error,request:request,active:true,now:now))
    }

    func testAuthorizationVersionAndServiceErrorsCannotPreserveRestrictedDraft() {
        let(lease,request)=authorizedLease()
        for error in [VideoError.permission("撤销"),.conflict("版本已变化"),.unavailable("不能核验"),.notFound("版本不存在"),.review("需要重新审核"),.budget("不能提交")] {
            XCTAssertFalse(lease.canPreserveDraft(after:error,request:request,active:true,now:now))
        }
        XCTAssertFalse(lease.canPreserveDraft(after:NSError(domain:"isolated-network",code:1),request:request,active:true,now:now))
    }

    func testInputErrorCannotRetainDraftInBackgroundAtExpiryOrAfterInvalidation() {
        var(lease,request)=authorizedLease()
        let error=VideoError.invalid("修改理由超出范围")
        XCTAssertFalse(lease.canPreserveDraft(after:error,request:request,active:false,now:now))
        XCTAssertFalse(lease.canPreserveDraft(after:error,request:request,active:true,now:now.addingTimeInterval(10)))
        lease.invalidate()
        XCTAssertFalse(lease.canPreserveDraft(after:error,request:request,active:true,now:now))
    }

    func testOldInvalidInputCannotRetainDraftAfterAReplacementRequest() {
        var(lease,old)=authorizedLease()
        _=lease.begin()
        XCTAssertFalse(lease.canPreserveDraft(after:VideoError.invalid("无分镜改动"),request:old,active:true,now:now))
    }
}
