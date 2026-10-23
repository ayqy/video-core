import XCTest
import VideoCore

final class PluginProtocolTests:XCTestCase {
    private func fixture()->PluginFrameInput {
        let scope=PluginInvocation(workspaceID:"workspace",projectID:"project",revisionID:"revision",revisionDigest:String(repeating:"a",count:64),jobID:"original-job",invocationID:"invocation",budgetReference:"original-quote",currency:"CNY",deadlineUnixTime:Date().timeIntervalSince1970+30)
        let data=Data([1,2,3]),id="atlas"
        var scene=Scene(kind:.simulation,title:"private-title",body:"private-body",narration:"private-narration")
        scene.classicArtwork=ClassicArtwork.quadrants(assetID:id,gameplay:.sokoban,sources:[ClassicSource(assetID:id,hash:Codec.hash(data),source:"private-source",owner:"private-owner",license:"private-license",evidenceID:"private-proof")])
        scene.characterProfile=CharacterProfile(name:"private-profile",actions:["点头"],evidenceIDs:["private-proof"],voiceAssetID:"private-voice")
        return PluginFrameInput(invocation:scope,props:PluginVisualProps(scene:scene),sourceFrame:0,fps:30,canvasWidth:600,canvasHeight:480,rect:PluginRect(x:10,y:10,width:580,height:460),assets:[PluginRasterAsset(assetID:id,data:data,sha256:Codec.hash(data),width:64,height:64)])
    }
    func testVisualSnapshotCannotEncodeNarrationSourcesVoiceOrApprovals()throws {
        let value=fixture(),data=try Codec.data(value),text=String(decoding:data,as:UTF8.self)
        for marker in ["private-title","private-body","private-narration","private-source","private-owner","private-license","private-proof","private-voice","private-profile"]{XCTAssertFalse(text.contains(marker),marker)}
        let scene=value.props.drawingScene()
        XCTAssertEqual(scene.narration,"speech");XCTAssertTrue(scene.title.isEmpty);XCTAssertTrue(scene.body.isEmpty)
        XCTAssertNil(scene.voice);XCTAssertNil(scene.characterProfile?.voiceAssetID);XCTAssertTrue(scene.evidenceIDs.isEmpty)
        XCTAssertEqual(scene.classicArtwork?.sources,[]);XCTAssertEqual(scene.classicArtwork?.audioCues,[])
        XCTAssertTrue(value.props.artworkRequired)
    }
    func testFrozenInputRoundTripAndDigestBindEveryIdentityAndFrame()throws {
        let input=fixture(),decoded=try Codec.decoder().decode(PluginFrameInput.self,from:Codec.data(input))
        XCTAssertEqual(input,decoded);try PluginProtocolRules.validate(decoded,capabilityID:"game.simulate")
        for mutation in 0..<8 {var changed=input;switch mutation{case 0:changed.invocation.workspaceID="other";case 1:changed.invocation.projectID="other";case 2:changed.invocation.revisionID="other";case 3:changed.invocation.jobID="other";case 4:changed.invocation.budgetReference="other";case 5:changed.invocation.invocationID="other";case 6:changed.sourceFrame=30;default:changed.props.simulation.seed+=1};XCTAssertNotEqual(try changed.contentDigest(),try input.contentDigest())}
    }
    func testInvocationRequiresWorkspaceDigestCurrencyAndRealBoundedDeadline()throws {
        let input=fixture()
        for mutation in 0..<7 {var changed=input.invocation;switch mutation{case 0:changed.workspaceID="";case 1:changed.projectID="bad\nidentity";case 2:changed.revisionDigest="not-a-hash";case 3:changed.currency="points";case 4:changed.deadlineUnixTime=Date().timeIntervalSince1970-1;case 5:changed.deadlineUnixTime=Date().timeIntervalSince1970+PluginProtocolRules.maximumInvocationSeconds+1;default:changed.deadlineUnixTime = .infinity};XCTAssertThrowsError(try PluginProtocolRules.validate(changed))}
        var longJob=input.invocation;longJob.deadlineUnixTime=Date().timeIntervalSince1970+3600;try PluginProtocolRules.validate(longJob)
        XCTAssertEqual(PluginProtocolRules.maximumTaskSeconds,120)
    }
    func testNewRPCRejectsLegacyGeometricFallbackAndWrongCapability()throws {
        var input=fixture();input.props.artwork=nil;input.assets=[];input.props.artworkRequired=false
        XCTAssertThrowsError(try PluginProtocolRules.validate(input,capabilityID:"game.simulate"))
        XCTAssertThrowsError(try PluginProtocolRules.validate(fixture(),capabilityID:"cartoon.animate"))
        var legacy=Scene(kind:.cartoon,title:"",body:"");legacy.classicArtworkRequired=nil
        XCTAssertTrue(PluginVisualProps(scene:legacy).artworkRequired)
    }
    func testImageHashBankCroppingAndNumericBoundsFailClosed()throws {
        let original=fixture()
        for mutation in 0..<10 {var input=original;switch mutation{case 0:input.assets[0].data.append(4);case 1:input.assets.append(input.assets[0]);case 2:input.assets[0].width=8193;case 3:input.props.artwork?.sprites[0].x = .nan;case 4:input.props.artwork?.sprites[0].width=2;case 5:input.canvasWidth=Int.max;case 6:input.sourceFrame = -1;case 7:input.rect.height = .infinity;case 8:input.props.artwork?.sprites.removeLast();default:input.assets[0].assetID="unreferenced"};XCTAssertThrowsError(try PluginProtocolRules.validate(input,capabilityID:"game.simulate"))}
    }
    func testOutputIsBoundToActualInputFrameAndDependencyBytes()throws {
        let input=fixture(),digest=try input.contentDigest()
        let frame=PluginPNGFrame(data:Data([9,8,7]),width:600,height:480,sourceFrame:0,inputDigest:digest,dependencyFingerprints:["atlas":input.assets[0].sha256])
        try PluginProtocolRules.validate(frame,input:input)
        for mutation in 0..<6 {var changed=frame;switch mutation{case 0:changed.data.append(6);case 1:changed.width=720;case 2:changed.sourceFrame=1;case 3:changed.inputDigest=String(repeating:"0",count:64);case 4:changed.dependencyFingerprints=[:];default:changed.data=Data()};XCTAssertThrowsError(try PluginProtocolRules.validate(changed,input:input))}
    }
    func testDiscoveryPublishesAllEightActualWireMethodsAndNoSceneSchema()throws {
        let descriptor=PluginDescription(pluginID:"video.game",capabilityID:"game.simulate",version:"1.0.0")
        XCTAssertEqual(descriptor.methods.map(\.rawValue),["handshake","describe","validate","estimate","execute","progress","cancel","health"])
        let definitions=PluginRPCSchemas.definitions();XCTAssertNil(definitions["Scene"]);XCTAssertNil(definitions["Evidence"]);XCTAssertNil(definitions["VoiceTake"])
        XCTAssertNotNil(definitions["PluginInvocation"]?.object?["properties"]?.object?["workspaceID"])
        XCTAssertNotNil(descriptor.inputSchema.object?["$defs"]?.object?["PluginFrameInput"])
        XCTAssertFalse(descriptor.filesystemAccess);XCTAssertFalse(descriptor.networkAccess)
        let request=PluginRPCRequest(requestID:"scope-close",method:.cancel,invocation:fixture().invocation)
        let decoded=try Codec.decoder().decode(PluginRPCRequest.self,from:Codec.data(request));XCTAssertEqual(decoded.method,.cancel);XCTAssertNil(decoded.taskID)
    }
    func testStandaloneFrameValidationRejectsDuplicateAssetIDsWithoutDictionaryTrap()throws {
        var input=fixture();input.assets.append(input.assets[0])
        let frame=PluginPNGFrame(data:Data([9,8,7]),width:input.canvasWidth,height:input.canvasHeight,sourceFrame:input.sourceFrame,inputDigest:try input.contentDigest(),dependencyFingerprints:[input.assets[0].assetID:input.assets[0].sha256])
        XCTAssertThrowsError(try PluginProtocolRules.validate(frame,input:input)){error in XCTAssertEqual((error as? VideoError)?.code,"invalid_input")}
    }
    func testLocalCashEstimateNeverModifiesOriginalBudgetReference() {
        let cost=PluginCost(currency:"USD",budgetReference:"original-external-budget")
        XCTAssertEqual(cost.actual,Money(0,"USD"));XCTAssertEqual(cost.budgetReference,"original-external-budget");XCTAssertFalse(cost.exclusions.isEmpty)
    }
}
