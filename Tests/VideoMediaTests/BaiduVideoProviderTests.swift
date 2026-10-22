import XCTest
import VideoCore
@testable import VideoMedia

final class BaiduVideoProviderTests:XCTestCase {
    func testOfficialBaiduContractCannotCallCustomCancelOrPretendToBeChat()throws {
        let profile=BaiduVideoRules.profile(keyReference:"test-keychain-reference-not-credential")
        XCTAssertThrowsError(try RemoteJobs.requireCancellationSupport(profile:profile))
        XCTAssertThrowsError(try ProviderRules.validate(profile:profile))
        XCTAssertFalse(profile.idempotency);XCTAssertNil(profile.cancelPath)
    }
    func testUnknownOriginalDoesNotReadKeychainOrResubmitFromQuery()async throws {
        let product=Product(workspaceID:"w",sku:"one",name:"课程",checkout:"https://example.com",audience:"新人",task:"复现",outcome:"理解",prerequisite:"",scope:"知识",prices:[Price(money:Money(1),source:"产品页")]),revision=Revision(product:product,purpose:.education,aspect:.portrait,scenes:[Scene(title:"知识",body:"内容")],cta:"复现"),profile=BaiduVideoRules.profile(keyReference:"intentionally-missing-keychain-reference")
        let quote=Quote(projectID:"p",revisionID:revision.id,digest:try revision.contentDigest(),upper:Money(3),unit:"CNY",provider:profile.id,expiresAt:Date().addingTimeInterval(60));var job=Job(workspaceID:"w",projectID:"p",revisionID:revision.id,digest:try revision.contentDigest(),requestKey:"original",quote:quote);job.videoGeneration=VideoGenerationReceipt(inputDigest:String(repeating:"a",count:64));job.state = .unknownRemote
        do{_ = try await RemoteJobs.query(profile:profile,job:job);XCTFail("unknown ID was queried or submitted")}
        catch{XCTAssertEqual((error as? VideoError)?.exitCode,8);XCTAssertFalse(error.localizedDescription.contains("intentionally-missing-keychain-reference"))}
        XCTAssertEqual(job.state,.unknownRemote);XCTAssertNil(job.remoteID);XCTAssertEqual(job.requestKey,"original")
    }
}
