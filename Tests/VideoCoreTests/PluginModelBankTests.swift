import XCTest
import VideoCore

final class PluginModelBankTests:XCTestCase {
    private let now=Date(timeIntervalSince1970:1_970_000_000)
    private struct Fixture {
        let invocation:PluginInvocation;let scene:ModelScene3D;let manifest:PluginModelBankManifest;let assets:[String:Data]
    }
    private func fixture() throws -> Fixture {
        let invocation=PluginInvocation(workspaceID:"workspace",projectID:"project",revisionID:"revision",revisionDigest:String(repeating:"a",count:64),jobID:"original-job",invocationID:"invocation",budgetReference:"original-quote",currency:"CNY",deadlineUnixTime:now.timeIntervalSince1970+60)
        // Authored rule-test geometry and a real tiny PNG. No game media or appearance claim.
        let dae=Data("""
        <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
        <asset><unit meter="1"/><up_axis>Y_UP</up_axis></asset>
        <library_images><image id="body"><init_from>body.png</init_from></image></library_images>
        <library_geometries><geometry id="triangle"><mesh><source id="positions"><float_array id="position-array" count="9">0 0 0 1 0 0 0 1 0</float_array></source></mesh></geometry></library_geometries>
        <library_visual_scenes><visual_scene id="stage"><node id="hip" sid="hip" type="JOINT"/></visual_scene></library_visual_scenes>
        <scene><instance_visual_scene url="#stage"/></scene></COLLADA>
        """.utf8)
        let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=")!
        let model=ModelAssetReference(assetID:"model",sha256:Codec.hash(dae),bytes:dae.count,fileExtension:"dae")
        let texture=ModelAssetReference(assetID:"texture",sha256:Codec.hash(png),bytes:png.count,fileExtension:"png")
        let resource=ModelDAEResource(model:model,inspection:try DAEInspector.inspect(dae),textures:["body.png":texture])
        let scene=ModelScene3D(instances:[.init(id:"actor",name:"test actor",resource:resource)],camera:.init(position:.init(x:0,y:2,z:5),target:.init()),lights:[.init(id:"light",kind:.ambient)])
        return Fixture(invocation:invocation,scene:scene,manifest:try PluginModelBankManifest(scene:scene,durationFrames:21),assets:["model":dae,"texture":png])
    }
    private func operation(_ kind:PluginModelBankOperationKind,_ f:Fixture,id:String="bank",assetID:String?=nil,offset:Int?=nil,data:Data?=nil)->PluginModelBankOperation {
        .init(kind:kind,invocation:f.invocation,bankID:id,manifest:kind == .begin ? f.manifest:nil,assetID:assetID,offset:offset,data:data,sha256:data.map{Codec.hash($0)})
    }
    private func upload(_ store:PluginModelBankStore,_ f:Fixture,id:String="bank") throws -> PluginModelBankReceipt {
        _=try store.apply(operation(.begin,f,id:id),now:now)
        for item in f.manifest.assets {
            let bytes=f.assets[item.assetID]!
            for offset in stride(from:0,to:bytes.count,by:PluginModelBankRules.maximumChunkBytes) {
                let chunk=bytes.subdata(in:offset..<min(offset+PluginModelBankRules.maximumChunkBytes,bytes.count))
                _=try store.apply(operation(.append,f,id:id,assetID:item.assetID,offset:offset,data:chunk),now:now)
            }
        }
        return try store.apply(operation(.commit,f,id:id),now:now)
    }
    private func frame(_ f:Fixture,reference:PluginModelBankReference)->PluginFrameInput {
        var scene=Scene(kind:.simulation,title:"private title",body:"private body",narration:"private speech",durationFrames:21);scene.modelScene3D=f.scene
        return .init(invocation:f.invocation,props:.init(scene:scene),sourceFrame:0,fps:30,canvasWidth:600,canvasHeight:480,rect:.init(x:0,y:0,width:600,height:480),assets:[],modelBankReference:reference)
    }
    func testOrderedUploadCommitProducesImmutableActualByteSnapshotAndCompleteFrameFingerprints() throws {
        let f=try fixture(),store=PluginModelBankStore(),receipt=try upload(store,f)
        XCTAssertEqual(receipt.state,.ready);XCTAssertEqual(receipt.receivedBytes,f.manifest.totalBytes);XCTAssertEqual(receipt.totalBytes,f.manifest.totalBytes)
        XCTAssertEqual(receipt,try store.apply(operation(.commit,f),now:now))
        let snapshot=try store.snapshot(reference:receipt.reference,invocation:f.invocation,scene:f.scene,durationFrames:21,now:now)
        XCTAssertEqual(snapshot.assets,f.assets);XCTAssertEqual(snapshot.inspections["model"],f.scene.instances[0].resource.inspection)
        var copy=try XCTUnwrap(snapshot.assets["model"]);copy.append(9)
        XCTAssertEqual(snapshot.assets["model"],f.assets["model"],"调用方Data修改不能改银行快照")
        let input=frame(f,reference:receipt.reference)
        XCTAssertNoThrow(try PluginProtocolRules.validate(input,capabilityID:"game.simulate",inputSchemaVersion:9,now:now))
        XCTAssertEqual(try input.dependencyFingerprints(),f.manifest.dependencyFingerprints)
        var output=PluginPNGFrame(data:Data([1,2,3]),width:600,height:480,sourceFrame:0,inputDigest:try input.contentDigest(),dependencyFingerprints:f.manifest.dependencyFingerprints)
        XCTAssertNoThrow(try PluginProtocolRules.validate(output,input:input))
        output.dependencyFingerprints.removeValue(forKey:"model");XCTAssertThrowsError(try PluginProtocolRules.validate(output,input:input))
        XCTAssertEqual(try Codec.decoder().decode(PluginFrameInput.self,from:Codec.data(input)),input)
        XCTAssertFalse(String(decoding:try Codec.data(input),as:UTF8.self).contains("private speech"))
    }
    func testAppendRetriesAreIdempotentAndRejectGapsChangedBlocksUnknownAssetsAndOversize() throws {
        let f=try fixture(),store=PluginModelBankStore(),data=f.assets["model"]!
        let begin=try store.apply(operation(.begin,f),now:now)
        XCTAssertEqual(begin,try store.apply(operation(.begin,f),now:now))
        XCTAssertThrowsError(try store.apply(operation(.append,f,assetID:"model",offset:1,data:Data(data.prefix(3))),now:now))
        let append=operation(.append,f,assetID:"model",offset:0,data:data)
        let accepted=try store.apply(append,now:now)
        XCTAssertEqual(accepted,try store.apply(append,now:now))
        XCTAssertThrowsError(try store.apply(operation(.append,f,assetID:"model",offset:0,data:Data([7,8,9])),now:now))
        XCTAssertThrowsError(try store.apply(operation(.append,f,assetID:"unknown",offset:0,data:Data([1])),now:now))
        XCTAssertThrowsError(try store.apply(operation(.append,f,assetID:"texture",offset:0,data:Data(repeating:1,count:PluginModelBankRules.maximumChunkBytes+1)),now:now))
        let wrongHash=PluginModelBankOperation(kind:.append,invocation:f.invocation,bankID:"bank",assetID:"texture",offset:0,data:f.assets["texture"],sha256:String(repeating:"0",count:64))
        XCTAssertThrowsError(try store.apply(wrongHash,now:now));XCTAssertEqual(store.reservedBytes,f.manifest.totalBytes)
        XCTAssertThrowsError(try store.apply(operation(.commit,f),now:now),"缺任何块不能提交")
    }
    func testCommitChecksFullLengthHashDAEXMLPNGHeaderAndExistingPixelBudgets() throws {
        let f=try fixture(),store=PluginModelBankStore()
        _=try store.apply(operation(.begin,f),now:now)
        for item in f.manifest.assets {
            var bytes=f.assets[item.assetID]!
            if item.assetID=="model" {bytes[bytes.startIndex]=0}
            _=try store.apply(operation(.append,f,assetID:item.assetID,offset:0,data:bytes),now:now)
        }
        XCTAssertThrowsError(try store.apply(operation(.commit,f),now:now),"块摘要可匹配错误数据，但提交必须核原完整SHA")
        for key in ["model","texture"] {
            var assets=f.assets;assets[key]=Data(repeating:1,count:f.assets[key]!.count)
            let references=f.manifest.assets.map{item in ModelAssetReference(assetID:item.assetID,sha256:Codec.hash(assets[item.assetID]!),bytes:item.bytes,fileExtension:item.fileExtension)}
            XCTAssertThrowsError(try PluginModelBankSnapshot(invocation:f.invocation,bankID:"bad",manifest:.init(assets:references),assets:assets,now:now),"清单SHA匹配仍须检查真实DAE/PNG结构")
        }
        var png=f.assets["texture"]!;png.replaceSubrange(16..<24,with:[0,0,32,0,0,0,32,0])
        var assets=f.assets;assets["texture"]=png
        let references=f.manifest.assets.map{item in ModelAssetReference(assetID:item.assetID,sha256:Codec.hash(assets[item.assetID]!),bytes:item.bytes,fileExtension:item.fileExtension)}
        XCTAssertThrowsError(try PluginModelBankSnapshot(invocation:f.invocation,bankID:"pixels",manifest:.init(assets:references),assets:assets,now:now))
        XCTAssertEqual(PluginProtocolRules.maximumImagePixels,24_000_000);XCTAssertEqual(PluginProtocolRules.maximumTotalImagePixels,48_000_000)
    }
    func testEveryInvocationFieldIsBoundForOperationsAndSnapshot() throws {
        let f=try fixture(),store=PluginModelBankStore(),receipt=try upload(store,f)
        for index in 0..<11 {
            var scope=f.invocation
            switch index {
            case 0:scope.workspaceID="other";case 1:scope.projectID="other";case 2:scope.revisionID="other";case 3:scope.revisionDigest=String(repeating:"b",count:64)
            case 4:scope.jobID=nil;case 5:scope.invocationID="other";case 6:scope.budgetReference="other";case 7:scope.currency="USD";case 8:scope.budgetLimit=1;case 9:scope.deadlineUnixTime+=1;default:scope.jobID="different-job"
            }
            XCTAssertThrowsError(try store.apply(.init(kind:.commit,invocation:scope,bankID:"bank"),now:now))
            XCTAssertThrowsError(try store.snapshot(reference:receipt.reference,invocation:scope,scene:f.scene,durationFrames:21,now:now))
        }
    }
    func testManifestAndActualInspectionMustMatchExactSceneClosure() throws {
        let f=try fixture(),store=PluginModelBankStore(),receipt=try upload(store,f)
        var forged=f.scene;forged.instances[0].resource.inspection.jointNames=["invented"]
        XCTAssertThrowsError(try store.snapshot(reference:receipt.reference,invocation:f.invocation,scene:forged,durationFrames:21,now:now))
        var missing=f.scene;missing.instances[0].resource.textures.removeAll()
        XCTAssertThrowsError(try store.snapshot(reference:receipt.reference,invocation:f.invocation,scene:missing,durationFrames:21,now:now))
        let wrong=PluginModelBankReference(bankID:"bank",manifestDigest:String(repeating:"0",count:64),invocationDigest:receipt.reference.invocationDigest)
        XCTAssertThrowsError(try store.snapshot(reference:wrong,invocation:f.invocation,scene:f.scene,durationFrames:21,now:now))
        var refs=f.manifest.assets;refs.append(refs[0]);XCTAssertThrowsError(try PluginModelBankManifest(assets:refs).validate())
        refs=f.manifest.assets;refs.append(.init(assetID:"extra",sha256:String(repeating:"c",count:64),bytes:1,fileExtension:"zip"));XCTAssertThrowsError(try PluginModelBankManifest(assets:refs).validate())
        var tooMany:[ModelAssetReference]=[]
        for index in 0...PluginModelBankRules.maximumAssets {tooMany.append(.init(assetID:"model-\(index)",sha256:String(repeating:"a",count:64),bytes:1,fileExtension:"dae"))}
        XCTAssertThrowsError(try PluginModelBankManifest(assets:tooMany).validate())
    }
    func testTwoBankCombinedReservationLimitDoesNotAllocateDeclaredPayloadBytes() throws {
        let f=try fixture(),store=PluginModelBankStore()
        let manifest=PluginModelBankManifest(assets:[.init(assetID:"large-model",sha256:String(repeating:"a",count:64),bytes:32*1024*1024,fileExtension:"dae")])
        for id in ["first","second"] {_=try store.apply(.init(kind:.begin,invocation:f.invocation,bankID:id,manifest:manifest),now:now)}
        XCTAssertEqual(store.bankCount,2);XCTAssertEqual(store.reservedBytes,PluginModelBankRules.maximumTotalBytes)
        XCTAssertThrowsError(try store.apply(operation(.begin,f,id:"third"),now:now))
        let partial=PluginModelBankStore(),over=PluginModelBankManifest(assets:[.init(assetID:"large",sha256:String(repeating:"a",count:64),bytes:33*1024*1024,fileExtension:"dae")])
        _=try partial.apply(.init(kind:.begin,invocation:f.invocation,bankID:"one",manifest:over),now:now)
        XCTAssertThrowsError(try partial.apply(.init(kind:.begin,invocation:f.invocation,bankID:"two",manifest:over),now:now))
        XCTAssertEqual(partial.bankCount,1)
    }
    func testReleaseExpiryAndTerminalCloseClearOwnedStorageWithoutChangingActiveSnapshot() throws {
        let f=try fixture(),store=PluginModelBankStore(),receipt=try upload(store,f)
        let active=try store.snapshot(reference:receipt.reference,invocation:f.invocation,scene:f.scene,durationFrames:21,now:now)
        let release=try store.apply(operation(.release,f),now:now)
        XCTAssertEqual(release.state,.released);XCTAssertEqual(release,try store.apply(operation(.release,f),now:now))
        XCTAssertEqual(store.bankCount,0);XCTAssertEqual(store.reservedBytes,0);XCTAssertEqual(active.assets,f.assets)
        XCTAssertThrowsError(try store.snapshot(reference:receipt.reference,invocation:f.invocation,scene:f.scene,durationFrames:21,now:now))
        XCTAssertThrowsError(try store.apply(operation(.begin,f),now:now),"已释放标识不能在同生命周期重开")
        let expiring=PluginModelBankStore();_=try upload(expiring,f)
        expiring.purgeExpired(now:now.addingTimeInterval(61));XCTAssertEqual(expiring.bankCount,0);XCTAssertEqual(expiring.reservedBytes,0)
        XCTAssertThrowsError(try expiring.apply(operation(.begin,f),now:now.addingTimeInterval(61)))
        let closing=PluginModelBankStore();_=try upload(closing,f);closing.close()
        XCTAssertEqual(closing.bankCount,0);XCTAssertEqual(closing.reservedBytes,0);XCTAssertThrowsError(try closing.apply(operation(.begin,f),now:now))
    }
    func testThreeDimensionalInputsRequireGameNineAndNoMixedRasterOrLegacyWorld() throws {
        let f=try fixture(),store=PluginModelBankStore(),receipt=try upload(store,f),input=frame(f,reference:receipt.reference)
        for schema in [1,2,3,5,6,7,8] {XCTAssertThrowsError(try PluginProtocolRules.validate(input,capabilityID:"game.simulate",inputSchemaVersion:schema,now:now))}
        XCTAssertThrowsError(try PluginProtocolRules.validate(input,capabilityID:"cartoon.animate",inputSchemaVersion:9,now:now))
        for index in 0..<7 {
            var mixed=input
            switch index {
            case 0:mixed.modelBankReference=nil;case 1:mixed.props.artworkRequired=true;case 2:mixed.props.storyActions=[]
            case 3:mixed.props.gameWorld=GameWorld(width:1,height:1,tiles:["floor"],entities:[])
            case 4:mixed.assets=[.init(assetID:"raster",data:Data([1]),sha256:Codec.hash(Data([1])),width:1,height:1)]
            case 5:mixed.props.layers=[];default:mixed.sourceFrame=21
            }
            XCTAssertThrowsError(try PluginProtocolRules.validate(mixed,capabilityID:"game.simulate",inputSchemaVersion:9,now:now))
        }
    }
    func testBankWireIsMutuallyExclusiveAndOldShapesBudgetsAndEightMethodsStayUnchanged() throws {
        let f=try fixture(),op=operation(.begin,f)
        let request=PluginRPCRequest(requestID:"register",method:.validate,modelBankOperation:op)
        XCTAssertNoThrow(try PluginProtocolRules.validate(request,pluginID:"video.game",inputSchemaVersion:9,now:now))
        XCTAssertEqual(try Codec.decoder().decode(PluginRPCRequest.self,from:Codec.data(request)).modelBankOperation,op)
        for schema in [1,8] {XCTAssertThrowsError(try PluginProtocolRules.validate(request,pluginID:"video.game",inputSchemaVersion:schema,now:now))}
        XCTAssertThrowsError(try PluginProtocolRules.validate(request,pluginID:"video.cartoon",inputSchemaVersion:9,now:now))
        let ref=PluginModelBankReference(bankID:"bank",manifestDigest:try f.manifest.contentDigest(),invocationDigest:try Codec.digest(f.invocation))
        var mixed=request;mixed.input=frame(f,reference:ref);XCTAssertThrowsError(try PluginProtocolRules.validate(mixed,pluginID:"video.game",inputSchemaVersion:9,now:now))
        mixed=request;mixed.invocation=f.invocation;XCTAssertThrowsError(try PluginProtocolRules.validate(mixed,pluginID:"video.game",inputSchemaVersion:9,now:now))
        mixed=request;mixed.taskID="task";XCTAssertThrowsError(try PluginProtocolRules.validate(mixed,pluginID:"video.game",inputSchemaVersion:9,now:now))
        mixed=request;mixed.method = .execute;XCTAssertThrowsError(try PluginProtocolRules.validate(mixed,pluginID:"video.game",inputSchemaVersion:9,now:now))
        let legacy=PluginRPCRequest(requestID:"old",method:.cancel,invocation:f.invocation)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(legacy)) as? [String:Any]);XCTAssertNil(object["modelBankOperation"])
        XCTAssertNil(PluginRPCSchemas.request(inputSchemaVersion:8,pluginID:"video.game").object?["properties"]?.object?["modelBankOperation"])
        XCTAssertEqual(PluginMethod.allCases.count,8);XCTAssertEqual(request.protocolMajor,1)
        XCTAssertEqual(PluginProtocolRules.maximumRequestBytes,16*1024*1024);XCTAssertEqual(PluginProtocolRules.maximumTotalAssetBytes,10*1024*1024)
        let unknown=Data(String(decoding:try Codec.data(op),as:UTF8.self).replacingOccurrences(of:"\"begin\"",with:"\"unknown\"").utf8)
        XCTAssertThrowsError(try Codec.decoder().decode(PluginModelBankOperation.self,from:unknown))
    }
    func testGameNineDiscoveryClosesAllReferencesWithoutExposingSourceRightsOrAudio() throws {
        let nine=PluginRPCSchemas.definitions(inputSchemaVersion:9,pluginID:"video.game")
        let eight=PluginRPCSchemas.definitions(inputSchemaVersion:8,pluginID:"video.game"),cartoon=PluginRPCSchemas.definitions(inputSchemaVersion:8,pluginID:"video.cartoon")
        for name in ModelScene3DSchema.records.keys {XCTAssertNotNil(nine[name],name);XCTAssertNil(eight[name],name);XCTAssertNil(cartoon[name],name)}
        for name in ["ModelLightKind","ModelVertexColorUsage","ModelNormalTextureEncoding","PluginModelBankOperation","PluginModelBankReceipt"] {XCTAssertNotNil(nine[name],name)}
        for name in ["Scene","Asset","Evidence","VoiceTake","ProductionBrief"] {XCTAssertNil(nine[name],name)}
        func check(_ node:AgentValue) {
            switch node {
            case .object(let values):if let ref=values["$ref"]?.string {XCTAssertNotNil(nine[String(ref.dropFirst("#/$defs/".count))],ref)};for value in values.values {check(value)}
            case .array(let values):for value in values {check(value)}
            default:break
            }
        }
        for value in nine.values {check(value)}
        XCTAssertNotNil(PluginRPCSchemas.request(inputSchemaVersion:9,pluginID:"video.game").object?["oneOf"])
        XCTAssertNotNil(PluginRPCSchemas.response(inputSchemaVersion:9,pluginID:"video.game").object?["properties"]?.object?["modelBankReceipt"])
    }
}
