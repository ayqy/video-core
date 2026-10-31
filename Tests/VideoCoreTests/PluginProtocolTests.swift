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
    func testCartoonWalkingUsesVerifiedImageBytesAcrossSeparateAssetIDs() throws {
        var input=fixture(),scene=Scene(kind:.cartoon,title:"源身份不是步态",body:"只核真实图块",durationFrames:90)
        let roles=Array(Set(CartoonActor.dinoRoles.values)).sorted()+["hero","floor"]
        let first=input.assets[0].assetID,second="second-atlas-identity"
        var bankCopy=input.assets[0];bankCopy.assetID=second;input.assets.append(bankCopy)
        var sprites=roles.enumerated().map{ClassicSprite(role:$0.element,assetID:first,x:Double($0.offset%3)/3,y:Double($0.offset/3)/3,width:0.25,height:0.25)}
        let walk=try XCTUnwrap(sprites.first{$0.role=="hero_walk"}),alternate=try XCTUnwrap(sprites.firstIndex{$0.role=="hero_walk_alt"})
        let actualAlternate=sprites[alternate]
        sprites[alternate]=ClassicSprite(role:"hero_walk_alt",assetID:second,x:walk.x,y:walk.y,width:walk.width,height:walk.height)
        scene.classicArtwork=ClassicArtwork(gameplay:.platformer,sprites:sprites,sources:[],derivation:.qStyle)
        scene.cartoonPerformance=try .conversation(durationFrames:90)
        input.props=PluginVisualProps(scene:scene)
        XCTAssertThrowsError(try PluginProtocolRules.validate(input,capabilityID:"cartoon.animate"))
        // Different regions of these equal image bytes are still valid.
        var differentRegion=actualAlternate;differentRegion.assetID=second
        input.props.artwork?.sprites[alternate]=differentRegion
        XCTAssertNoThrow(try PluginProtocolRules.validate(input,capabilityID:"cartoon.animate"))
        // Separate actual image bytes may use the same normalized region.
        input.props.artwork?.sprites[alternate]=ClassicSprite(role:"hero_walk_alt",assetID:second,x:walk.x,y:walk.y,width:walk.width,height:walk.height)
        input.assets[1].data.append(4);input.assets[1].sha256=Codec.hash(input.assets[1].data)
        XCTAssertNoThrow(try PluginProtocolRules.validate(input,capabilityID:"cartoon.animate"))
        // The claimed hash alone cannot make unequal transmitted bytes valid.
        input.assets[1].sha256=input.assets[0].sha256
        XCTAssertThrowsError(try PluginProtocolRules.validate(input,capabilityID:"cartoon.animate"))
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
    func testMatrixNegotiationRequiresSchemaThreeWhileLegacyKnowledgeKeepsSchemaTwo() throws {
        var simulation = Simulation()
        let people = [KnowledgeParticipant(id: "a", name: "甲", strategy: .contribute, initialResources: 20),
                      KnowledgeParticipant(id: "b", name: "乙", strategy: .contribute, initialResources: 20)]
        simulation.knowledge = KnowledgeSimulation(knowledgeLabel: "公共品", participants: people, rounds: 1)
        XCTAssertThrowsError(try PluginInputCompatibility.requireKnowledgeSupport(simulation, pluginID: "video.game", inputSchema: 1))
        XCTAssertNoThrow(try PluginInputCompatibility.requireKnowledgeSupport(simulation, pluginID: "video.game", inputSchema: 2))
        XCTAssertNoThrow(try PluginInputCompatibility.requireKnowledgeSupport(simulation, pluginID: "video.game", inputSchema: 3))
        simulation.knowledge?.version = 2; simulation.knowledge?.payoffMatrix = .prisonersDilemma()
        for index in 0..<2 { simulation.knowledge?.participants[index].matrixStrategy = .alwaysFirst }
        for version in [1, 2, 4] {
            XCTAssertThrowsError(try PluginInputCompatibility.requireKnowledgeSupport(simulation, pluginID: "video.game", inputSchema: version))
        }
        XCTAssertNoThrow(try PluginInputCompatibility.requireKnowledgeSupport(simulation, pluginID: "video.game", inputSchema: 3))
        XCTAssertThrowsError(try PluginInputCompatibility.requireKnowledgeSupport(simulation, pluginID: "video.cartoon", inputSchema: 3))
        simulation.knowledge?.payoffMatrix = nil
        XCTAssertThrowsError(try PluginInputCompatibility.requireKnowledgeSupport(simulation, pluginID: "video.game", inputSchema: 3), "schema升级不能授权不完整规则")
    }
    func testSchemaTwoKnowledgeShapeStaysFrozenAndMatrixThreeDiscoveryHasResolvableRules() throws {
        let old = PluginRPCSchemas.definitions(inputSchemaVersion: 2), current = PluginRPCSchemas.definitions(inputSchemaVersion: 3)
        XCTAssertNil(PluginRPCSchemas.definitions(inputSchemaVersion: 1)["KnowledgeSimulation"])
        for key in ["payoffMatrix", "matrixStrategy", "matrixPool"] {
            let record = key == "payoffMatrix" ? "KnowledgeSimulation" : key == "matrixStrategy" ? "KnowledgeParticipant" : "KnowledgeEvent"
            XCTAssertNil(old[record]?.object?["properties"]?.object?[key])
            XCTAssertNotNil(current[record]?.object?["properties"]?.object?[key])
        }
        XCTAssertNil(old["KnowledgePayoffMatrix"]); XCTAssertNotNil(current["KnowledgePayoffMatrix"])
        XCTAssertEqual(old["KnowledgeChoice"]?.object?["enum"], .array([.string("出力"), .string("等待"), .string("资源不足，无法出力")]))
        let discoverable = AgentSchemas.definitions()
        XCTAssertNotNil(discoverable["KnowledgeMatrixStrategy"])
        XCTAssertNotNil(discoverable["KnowledgePayoffCell"]?.object?["properties"]?.object?["columnPayout"])
        func refs(_ node: AgentValue) throws {
            switch node {
            case .object(let values):
                if let ref = values["$ref"]?.string { XCTAssertNotNil(current[String(ref.dropFirst("#/$defs/".count))], ref) }
                for value in values.values { try refs(value) }
            case .array(let values): for value in values { try refs(value) }
            default: break
            }
        }
        for value in current.values { try refs(value) }
        let descriptor = PluginDescription(pluginID: "video.game", capabilityID: "game.simulate", version: "1.2.0", inputSchemaVersion: 3)
        XCTAssertEqual(descriptor.inputSchemaVersion, 3)
        XCTAssertEqual(descriptor.inputSchema.object?["$defs"]?.object?["KnowledgePayoffMatrix"], current["KnowledgePayoffMatrix"])
    }
    func testPublicationSchemaSelectionUsesCurrentDefaultsAndRetainsExplicitLegacyRequests() throws {
        XCTAssertEqual(try PluginInputCompatibility.publicationSchema(pluginID: "video.game"), 8)
        XCTAssertEqual(try PluginInputCompatibility.publicationSchema(pluginID: "video.cartoon"), 8)
        for version in [1, 2, 3, 5, 6, 7, 8] {
            XCTAssertEqual(try PluginInputCompatibility.publicationSchema(pluginID: "video.game", requested: String(version)), version)
        }
        for version in [1, 4, 5, 6, 7, 8] {
            XCTAssertEqual(try PluginInputCompatibility.publicationSchema(pluginID: "video.cartoon", requested: String(version)), version)
        }
        for value in ["", "0", "-1", "03", "+3", "3.0", " 3", "3 ", "1e0", "true", "999999999999999999999", "3\n"] {
            XCTAssertThrowsError(try PluginInputCompatibility.publicationSchema(pluginID: "video.game", requested: value), value)
        }
        XCTAssertThrowsError(try PluginInputCompatibility.publicationSchema(pluginID: "unknown"))
        XCTAssertThrowsError(try PluginInputCompatibility.publicationSchema(pluginID: "video.game", requested: "4"))
        XCTAssertThrowsError(try PluginInputCompatibility.publicationSchema(pluginID: "video.cartoon", requested: "2"))
        XCTAssertThrowsError(try PluginInputCompatibility.publicationSchema(pluginID: "video.cartoon", requested: "3"))
        XCTAssertThrowsError(try PluginInputCompatibility.publicationSchema(pluginID: "video.cartoon", requested: "9"))
    }
    func testRuleTableRequiresExplicitSchemaFiveWithoutChangingEarlierShapes() throws {
        var simulation=Simulation()
        simulation.knowledge=KnowledgeSimulation(knowledgeLabel:"可编辑机制",participants:[
            .init(id:"a",name:"甲",strategy:.contribute),.init(id:"b",name:"乙",strategy:.contribute)
        ],rounds:1,ruleTable:KnowledgeRuleTable(actions:[.init(id:"wait",label:"等待",pose:.idle)],states:[.init(id:"open",label:"待处理")],plans:[
            .init(actorID:"a",initialStateID:"open",defaultActionID:"wait"),
            .init(actorID:"b",initialStateID:"open",defaultActionID:"wait")
        ],rules:[.init(id:"remain",label:"保持",conditions:[.init(kind:.round,minimum:1,maximum:1)],effects:[.setState(actorID:"a",stateID:"open")])]))
        try XCTUnwrap(simulation.knowledge).validate()
        for version in [1,2,3,4] {XCTAssertThrowsError(try PluginInputCompatibility.requireKnowledgeSupport(simulation,pluginID:"video.game",inputSchema:version))}
        XCTAssertNoThrow(try PluginInputCompatibility.requireKnowledgeSupport(simulation,pluginID:"video.game",inputSchema:5))
        let current=PluginRPCSchemas.definitions(inputSchemaVersion:5)
        for version in [2,3,4] {
            let previous=PluginRPCSchemas.definitions(inputSchemaVersion:version)
            XCTAssertNil(previous["KnowledgeRuleTable"])
            XCTAssertNil(previous["KnowledgeSimulation"]?.object?["properties"]?.object?["ruleTable"])
            XCTAssertNil(previous["KnowledgeActorState"]?.object?["properties"]?.object?["executedActionID"])
        }
        XCTAssertNotNil(current["KnowledgeRuleTable"])
        XCTAssertNotNil(current["KnowledgeSimulation"]?.object?["properties"]?.object?["ruleTable"])
        XCTAssertNotNil(current["KnowledgeActorState"]?.object?["properties"]?.object?["executedActionID"])
        func check(_ node:AgentValue) {
            switch node {
            case .object(let values):
                if let ref=values["$ref"]?.string {XCTAssertNotNil(current[String(ref.dropFirst("#/$defs/".count))],ref)}
                for value in values.values {check(value)}
            case .array(let values):for value in values {check(value)}
            default:break
            }
        }
        for value in current.values {check(value)}
        // The Host maps a shot to an absolute source frame. The plugin sees no
        // shot window, narration, source annotations, audio or human approvals.
        var scene=fixture().props.drawingScene()
        scene.simulation=simulation
        scene.simulationPresentation=SimulationPresentation(sourceStartFrame:30,sourceEndFrame:61,presentationFrames:90)
        let visual=PluginVisualProps(scene:scene)
        let bytes=String(decoding:try Codec.data(visual),as:UTF8.self)
        XCTAssertFalse(bytes.contains("simulationPresentation"))
        XCTAssertNil(visual.drawingScene().simulationPresentation)
    }
    func testRigVersionTwoRequiresCartoonSixEvenForOneActorAndKeepsLegacyFive()throws {
        for count in [1,7,8] {
            let rig=CartoonRig(version:2,actors:(0..<count).map{.init(id:"actor-\($0)",name:"角色\($0)",x:0.5,y:0.5)})
            for schema in [1,4,5] {XCTAssertThrowsError(try PluginInputCompatibility.requireStorySupport(storyActions:[],gameWorld:nil,cartoonRig:rig,pluginID:"video.cartoon",inputSchema:schema))}
            XCTAssertNoThrow(try PluginInputCompatibility.requireStorySupport(storyActions:[],gameWorld:nil,cartoonRig:rig,pluginID:"video.cartoon",inputSchema:6))
            XCTAssertThrowsError(try PluginInputCompatibility.requireStorySupport(storyActions:[],gameWorld:nil,cartoonRig:rig,pluginID:"video.game",inputSchema:7))
            var input=fixture(),scene=Scene(kind:.cartoon,title:"",body:"",durationFrames:30);scene.cartoonRig=rig;scene.classicArtworkRequired=false
            input.props=PluginVisualProps(scene:scene);input.assets=[]
            XCTAssertNoThrow(try PluginProtocolRules.validate(input,capabilityID:"cartoon.animate"))
        }
        let legacy=CartoonRig(actors:[.init(id:"legacy",name:"旧演员",x:0.5,y:0.5)])
        for schema in [5,6] {XCTAssertNoThrow(try PluginInputCompatibility.requireStorySupport(storyActions:[],gameWorld:nil,cartoonRig:legacy,pluginID:"video.cartoon",inputSchema:schema))}
        var unknown=legacy;unknown.version=3
        XCTAssertThrowsError(try PluginInputCompatibility.requireStorySupport(storyActions:[],gameWorld:nil,cartoonRig:unknown,pluginID:"video.cartoon",inputSchema:6))
        XCTAssertTrue(PluginInputCompatibility.supports(pluginID:"video.cartoon",version:6));XCTAssertTrue(PluginInputCompatibility.supports(pluginID:"video.cartoon",version:7));XCTAssertTrue(PluginInputCompatibility.supports(pluginID:"video.cartoon",version:8));XCTAssertFalse(PluginInputCompatibility.supports(pluginID:"video.cartoon",version:9))
    }
    func testCartoonSixDiscoveryBoundsRigTwoWithoutChangingFiveOrExposingHostCausality()throws {
        let old=PluginRPCSchemas.definitions(inputSchemaVersion:5,pluginID:"video.cartoon"),current=PluginRPCSchemas.definitions(inputSchemaVersion:6,pluginID:"video.cartoon")
        let oldRig=try XCTUnwrap(old["CartoonRig"]?.object),rig=try XCTUnwrap(current["CartoonRig"]?.object)
        XCTAssertNil(oldRig["if"]);XCTAssertNil(oldRig["properties"]?.object?["actors"]?.object?["maxItems"]);XCTAssertNil(oldRig["properties"]?.object?["version"]?.object?["enum"])
        XCTAssertEqual(rig["properties"]?.object?["version"]?.object?["enum"],.array([.number(1),.number(2)]))
        XCTAssertEqual(rig["properties"]?.object?["actors"]?.object?["minItems"],.number(1));XCTAssertEqual(rig["properties"]?.object?["actors"]?.object?["maxItems"],.number(8))
        XCTAssertEqual(rig["then"]?.object?["properties"]?.object?["actors"]?.object?["maxItems"],.number(4))
        for name in ["StoryAction","CartoonRigActor","CartoonRigCue","CartoonSpeechTrack","SpeechEnergyCue"] {XCTAssertEqual(old[name],current[name],name)}
        for name in ["StoryCausality","StoryCausalSource","StoryCausalBinding"] {XCTAssertNil(current[name],name)}
    }

    func testHostImageFlipStaysInSceneButNotPluginSnapshotOrDigest()throws {
        var input=fixture(),scene=input.props.drawingScene()
        scene.storyActions=[]
        var layer=SceneLayer(kind:.image,assetID:"atlas",endFrame:scene.durationFrames)
        layer.id="host-picture";layer.sourceRect=MediaFraming(x:0.1,y:0.2,width:0.3,height:0.4)
        scene.layers=[layer]
        let legacy=PluginVisualProps(scene:scene)
        input.props=legacy
        let legacyBytes=try Codec.data(legacy),legacyDigest=try input.contentDigest()
        for flag in [true,false] {
            var host=scene;host.layers?[0].imageFlipHorizontal=flag
            let saved=try Codec.decoder().decode(Scene.self,from:Codec.data(host))
            XCTAssertEqual(saved.layers?[0].imageFlipHorizontal,flag)
            XCTAssertNotEqual(try Codec.data(saved),try Codec.data(scene))
            let snapshot=PluginVisualProps(scene:saved)
            XCTAssertEqual(host.layers?[0].imageFlipHorizontal,flag)
            XCTAssertNil(snapshot.layers?[0].imageFlipHorizontal)
            XCTAssertNil(snapshot.drawingScene().layers?[0].imageFlipHorizontal)
            XCTAssertEqual(snapshot.layers?[0].sourceRect,layer.sourceRect)
            XCTAssertEqual(try Codec.data(snapshot),legacyBytes)
            var frozen=input;frozen.props=snapshot
            XCTAssertEqual(try frozen.contentDigest(),legacyDigest)
            XCTAssertNoThrow(try PluginProtocolRules.validate(frozen,capabilityID:"game.simulate"))
        }
    }
    func testHistoricalRPCSceneLayerSchemaBytesAndDigestRemainFrozen()throws {
        // The literal is the published SceneLayer definition at 0a54ff6c,
        // including its original optional/null shapes and additionalProperties.
        let historical=try Codec.decoder().decode(AgentValue.self,from:Data(##"{"additionalProperties":true,"properties":{"assetID":{"anyOf":[{"type":"string"},{"type":"null"}]},"color":{"type":"string"},"dataPresentation":{"anyOf":[{"$ref":"#/$defs/DataPresentation"},{"type":"null"}]},"endFrame":{"type":"integer"},"entrance":{"anyOf":[{"$ref":"#/$defs/LayerEntrance"},{"type":"null"}]},"height":{"description":"JSON decimal, never a formatted currency string","type":"number"},"id":{"type":"string"},"imageSequence":{"anyOf":[{"$ref":"#/$defs/LayerImageSequence"},{"type":"null"}]},"keyframes":{"items":{"$ref":"#/$defs/Keyframe"},"type":"array"},"kind":{"$ref":"#/$defs/LayerKind"},"locked":{"type":"boolean"},"opacity":{"description":"JSON decimal, never a formatted currency string","type":"number"},"sourceRect":{"anyOf":[{"$ref":"#/$defs/MediaFraming"},{"type":"null"}]},"startFrame":{"type":"integer"},"text":{"type":"string"},"texturedPath":{"anyOf":[{"$ref":"#/$defs/LayerTexturedPath"},{"type":"null"}]},"width":{"description":"JSON decimal, never a formatted currency string","type":"number"},"x":{"description":"JSON decimal, never a formatted currency string","type":"number"},"y":{"description":"JSON decimal, never a formatted currency string","type":"number"}},"required":["id","kind","text","x","y","width","height","color","opacity","startFrame","endFrame","locked","keyframes"],"type":"object"}"##.utf8))
        for pluginID in ["video.game","video.cartoon"] {
            for version in 1...8 where PluginInputCompatibility.supports(pluginID:pluginID,version:version) {
                let definitions=PluginRPCSchemas.definitions(inputSchemaVersion:version,pluginID:pluginID)
                if let actual=definitions["SceneLayer"] {
                    var expected=try XCTUnwrap(historical.object)
                    if version<8 {
                        var properties=try XCTUnwrap(expected["properties"]?.object)
                        properties.removeValue(forKey:"texturedPath");expected["properties"] = .object(properties)
                    }
                    let frozen=AgentValue.object(expected)
                    XCTAssertEqual(try Codec.data(actual),try Codec.data(frozen),"\(pluginID) schema\(version)")
                    XCTAssertEqual(try Codec.digest(actual),try Codec.digest(frozen),"\(pluginID) schema\(version)")
                    XCTAssertNil(actual.object?["properties"]?.object?["imageFlipHorizontal"])
                }
                for schema in [PluginRPCSchemas.request(inputSchemaVersion:version,pluginID:pluginID),PluginRPCSchemas.response(inputSchemaVersion:version,pluginID:pluginID)] {
                    XCTAssertFalse(String(decoding:try Codec.data(schema),as:UTF8.self).contains("imageFlipHorizontal"),"\(pluginID) schema\(version)")
                }
            }
        }
        XCTAssertNotNil(AgentSchemas.definitions()["SceneLayer"]?.object?["properties"]?.object?["imageFlipHorizontal"])
    }
    func testRPCRejectsInjectedHostImageFlipInsteadOfDroppingIt()throws {
        var input=fixture(),scene=input.props.drawingScene()
        scene.storyActions=[]
        var layer=SceneLayer(kind:.image,assetID:"atlas",endFrame:scene.durationFrames)
        layer.id="host-picture";scene.layers=[layer];input.props=PluginVisualProps(scene:scene)
        XCTAssertNoThrow(try PluginProtocolRules.validate(input,capabilityID:"game.simulate"))
        for flag in [true,false] {
            var injected=input;injected.props.layers?[0].imageFlipHorizontal=flag
            let decoded=try Codec.decoder().decode(PluginFrameInput.self,from:Codec.data(injected))
            XCTAssertEqual(decoded.props.layers?[0].imageFlipHorizontal,flag)
            XCTAssertThrowsError(try PluginProtocolRules.validate(decoded,capabilityID:"game.simulate")) {error in
                XCTAssertEqual((error as? VideoError)?.code,"invalid_input")
                XCTAssertTrue((error as? VideoError)?.errorDescription?.contains("Host专用图片翻转") == true)
            }
        }
    }
}
