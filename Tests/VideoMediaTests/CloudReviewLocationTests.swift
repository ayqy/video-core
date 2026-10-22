import Foundation
import XCTest
#if !CLOUD_REVIEW_LOCATION_HOST_TEST
@testable import VideoMedia
#endif

final class CloudReviewLocationTests:XCTestCase {
    private func location(_ name:String,account:String,container:String="iCloud.local-rule",owned:Bool=true)->CloudReviewLocation {
        CloudReviewLocation(id:account+container+name,accountKey:account,containerIdentifier:container,zoneName:"rule-zone",zoneOwner:"rule-owner",rootName:name,shareName:"share-"+name,owned:owned,revisionID:"revision-"+name,revisionDigest:"revision-digest-"+name,payloadDigest:"payload-digest-"+name)
    }
    private func bytes(_ locations:[CloudReviewLocation]) throws -> Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return try encoder.encode(locations)
    }
    func testAccountAToBChangeAndBackKeepsAuthorDeletionAddress() throws {
        let authorA=location("author-a",account:"opaque-a"),recipientA=location("recipient-a",account:"opaque-a",owned:false),authorB=location("author-b",account:"opaque-b")
        let before=[authorA,recipientA]
        let switched=CloudReviewLocationPersistence.replacingPartition(stored:before,current:[authorB],accountKey:"opaque-b",containerIdentifier:authorB.containerIdentifier)
        // Round-trip the stored values, then reopen A exactly as connect filters its view.
        let reopened=try JSONDecoder().decode([CloudReviewLocation].self,from:bytes(switched)).filter{$0.accountKey=="opaque-a" && $0.containerIdentifier==authorA.containerIdentifier}
        XCTAssertEqual(try bytes(reopened),try bytes(before))
        XCTAssertEqual(switched.filter{$0.accountKey=="opaque-b"}.map(\.id),[authorB.id])
    }
    func testDeletingOnlyActiveAccountEntryRetainsOtherReviewAndContainer() throws {
        let deleting=location("one",account:"opaque-a"),otherReview=location("two",account:"opaque-a"),otherAccount=location("one",account:"opaque-b"),otherContainer=location("one",account:"opaque-a",container:"iCloud.other-rule")
        let stored=[deleting,otherReview,otherAccount,otherContainer]
        let result=CloudReviewLocationPersistence.replacingPartition(stored:stored,current:[otherReview],accountKey:deleting.accountKey,containerIdentifier:deleting.containerIdentifier)
        XCTAssertFalse(result.contains{$0.id==deleting.id})
        XCTAssertEqual(try bytes(result.filter{$0.id==otherReview.id}),try bytes([otherReview]))
        XCTAssertEqual(try bytes(result.filter{$0.id==otherAccount.id || $0.id==otherContainer.id}),try bytes([otherAccount,otherContainer]))
    }
    func testEmptyActiveViewCannotEraseOtherAccountOrContainer() throws {
        let active=location("one",account:"opaque-a"),otherAccount=location("two",account:"opaque-b"),otherContainer=location("three",account:"opaque-a",container:"iCloud.other-rule")
        let result=CloudReviewLocationPersistence.replacingPartition(stored:[active,otherAccount,otherContainer],current:[],accountKey:active.accountKey,containerIdentifier:active.containerIdentifier)
        XCTAssertEqual(try bytes(result),try bytes([otherAccount,otherContainer]))
    }
    func testForeignEntriesInCurrentViewCannotOverwriteTheirStoredPartition() throws {
        let active=location("one",account:"opaque-a"),otherAccount=location("two",account:"opaque-b")
        var unexpected=otherAccount;unexpected.rootName="changed-outside-active-account"
        let result=CloudReviewLocationPersistence.replacingPartition(stored:[otherAccount],current:[active,unexpected],accountKey:active.accountKey,containerIdentifier:active.containerIdentifier)
        XCTAssertEqual(try bytes(result.filter{$0.accountKey==otherAccount.accountKey}),try bytes([otherAccount]))
        XCTAssertEqual(try bytes(result.filter{$0.accountKey==active.accountKey}),try bytes([active]))
    }
}
