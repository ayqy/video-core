import XCTest
@testable import VideoCore

final class ModelSceneContractTests: XCTestCase {
    private struct Fixture {
        let root: URL; let repository: Repository; let workspace: Workspace
        let assets: [Asset]; let evidence: [Evidence]; let model: ModelScene3D
    }
    private func fixture() throws -> Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("model-contract-"+UUID().uuidString)
        let repository=try Repository(root:root.appendingPathComponent("original")),workspace=Workspace(name:"模型合同",owner:"owner")
        // Authored test geometry and a real one-pixel PNG exercise byte identity;
        // they are not ACNH assets or evidence of rendered game appearance.
        let xml="""
        <COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
        <asset><unit meter="1"/><up_axis>Y_UP</up_axis></asset>
        <library_images><image id="body"><init_from>body.png</init_from></image></library_images>
        <library_effects><effect id="surfaceEffect"><profile_COMMON><technique sid="common"><lambert><diffuse><color>1 1 1 1</color></diffuse></lambert></technique></profile_COMMON></effect></library_effects>
        <library_materials><material id="bodyMaterial"><instance_effect url="#surfaceEffect"/></material><material id="capMaterial"><instance_effect url="#surfaceEffect"/></material></library_materials>
        <library_geometries><geometry id="triangle"><mesh><source id="positions"><float_array id="position-array" count="9">0 0 0 1 0 0 0 1 0</float_array></source></mesh></geometry></library_geometries>
        <library_visual_scenes><visual_scene id="stage"><node id="hip" sid="hip" type="JOINT"/><node id="mesh"><instance_geometry url="#triangle"/></node></visual_scene></library_visual_scenes>
        <scene><instance_visual_scene url="#stage"/></scene></COLLADA>
        """
        let bytes=Data(xml.utf8),png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=")!
        var mesh=try repository.ingest(bytes,name:"mesh.dae",workspaceID:workspace.id,mediaType:"model3d")
        var texture=try repository.ingest(png,name:"body.png",workspaceID:workspace.id,mediaType:"image")
        let meshProof=Evidence(workspaceID:workspace.id,title:"测试自制网格",source:"authored test source",claim:"triangle",owner:"test",commercialAllowed:true,verified:true,assetID:mesh.id)
        let textureProof=Evidence(workspaceID:workspace.id,title:"测试纹理",source:"authored test source",claim:"pixel",owner:"test",commercialAllowed:true,verified:true,assetID:texture.id)
        mesh.evidenceID=meshProof.id;texture.evidenceID=textureProof.id
        let inspection=try DAEInspector.inspect(bytes)
        let resource=ModelDAEResource(model:.init(asset:mesh),inspection:inspection,textures:["body.png":.init(asset:texture)])
        let model=ModelScene3D(instances:[.init(id:"actor",name:"测试演员",resource:resource)],camera:.init(position:.init(x:0,y:2,z:5),target:.init()),lights:[.init(id:"sun",kind:.directional)],
            transformTracks:[.init(instanceID:"actor",keyframes:[.init(frame:0,transform:.init()),.init(frame:20,transform:.init(translation:.init(x:2)))])],
            jointTracks:[.init(instanceID:"actor",jointName:"hip",keyframes:[.init(frame:0,transform:.init()),.init(frame:20,transform:.init(rotation:.init(x:0,y:0,z:1,w:0)))])])
        try repository.transaction {$0.workspaces=[workspace];$0.assets=[mesh,texture];$0.evidence=[meshProof,textureProof]}
        return Fixture(root:root,repository:repository,workspace:workspace,assets:[mesh,texture],evidence:[meshProof,textureProof],model:model)
    }
    private func scene(_ fixture: Fixture) -> Scene {
        var scene=Scene(kind:.simulation,title:"模型场景",body:"",durationFrames:21)
        scene.modelScene3D=fixture.model
        return scene
    }
    private func project(_ scene: Scene, _ fixture: Fixture) -> Project {
        Project(workspaceID:fixture.workspace.id,name:"正常模型工程",revision:Revision(contentContext:.init(workspaceID:fixture.workspace.id,name:"模型故事"),aspect:.landscape,scenes:[scene]))
    }
    private func input(_ project: Project, edits: [Edit]) throws -> Data {
        try Codec.data(AgentValue.object(["workspace_id":.string(project.workspaceID),"project_id":.string(project.id),"base_revision":.string(project.current.id),"edits":try Codec.decoder().decode(AgentValue.self,from:Codec.data(edits))]))
    }
    func testNormalAgentEditFreezesModelAndTextureAndColdBackupPreservesContract() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        var original=scene(f);original.modelScene3D=nil
        let project=project(original,f);try f.repository.transaction{$0.projects=[project]}
        var interpreted=f.model
        interpreted.instances[0].materialInterpretation = .init(vertexColors:.ignored,normalEncoding:.redGreenPositiveZ,opaqueDiffuseMaterialIDs:["bodyMaterial"])
        var replacement=scene(f);replacement.modelScene3D=interpreted
        let data=try input(project,edits:[.replaceScene(original.id,replacement)])
        let before=try Codec.data(f.repository.read())
        _=try AgentMutationExecutor.preview(command:"edit apply",data:data,database:f.repository.read(),principal:"owner",repository:f.repository)
        XCTAssertEqual(try Codec.data(f.repository.read()),before,"正常dry-run不得保存模型或回执")
        let unknownEncoding=Data(String(decoding:data,as:UTF8.self).replacingOccurrences(of:"redGreenPositiveZ",with:"unknownNormalEncoding").utf8)
        XCTAssertThrowsError(try AgentMutationExecutor.preview(command:"edit apply",data:unknownEncoding,database:f.repository.read(),principal:"owner",repository:f.repository),"未知材质解释须在正常Agent解码时拒绝")
        XCTAssertEqual(try Codec.data(f.repository.read()),before)
        for (index,ids) in [["unknownMaterial"],["bodyMaterial","bodyMaterial"],[]].enumerated() {
            var invalid=replacement;invalid.modelScene3D!.instances[0].materialInterpretation!.opaqueDiffuseMaterialIDs=ids
            let invalidInput=try input(project,edits:[.replaceScene(original.id,invalid)])
            XCTAssertThrowsError(try AgentMutationExecutor.preview(command:"edit apply",data:invalidInput,database:f.repository.read(),principal:"owner",repository:f.repository))
            XCTAssertThrowsError(try f.repository.performAgentMutation(command:"edit apply",data:invalidInput,principal:"owner",requestID:"invalid-opaque-material-\(index)"))
            XCTAssertEqual(try Codec.data(f.repository.read()),before,"错误材质列表不能增加版本或保存回执")
        }
        let answer=try f.repository.performAgentMutation(command:"edit apply",data:data,principal:"owner",requestID:"model-edit")
        XCTAssertEqual(answer,try f.repository.performAgentMutation(command:"edit apply",data:data,principal:"owner",requestID:"model-edit"))
        let current=try XCTUnwrap(f.repository.read().projects.first?.current)
        XCTAssertEqual(current.scenes[0].modelScene3D,interpreted)
        XCTAssertEqual(Set((current.dependencies?.records ?? []).filter{$0.kind == .asset}.map{$0.asset!.id}),f.model.assetIDs)
        XCTAssertEqual(Set((current.dependencies?.records ?? []).filter{$0.kind == .evidence}.map{$0.evidence!.id}),Set(f.evidence.map(\.id)))
        let digest=try current.contentDigest(),backup=try f.repository.backup()
        let restored=try Repository.restore(backup,to:f.root.appendingPathComponent("restored"))
        let cold=try XCTUnwrap(restored.read().projects.first?.current)
        XCTAssertEqual(try cold.contentDigest(),digest);XCTAssertEqual(cold.scenes[0].modelScene3D,interpreted)
        XCTAssertEqual(cold.scenes[0].modelScene3D?.instances[0].materialInterpretation?.opaqueDiffuseMaterialIDs,["bodyMaterial"])
        for asset in f.assets {XCTAssertEqual(try Data(contentsOf:restored.assetURL(asset)),try Data(contentsOf:f.repository.assetURL(asset)))}
        var changedAssets=f.assets;changedAssets[1].hash=String(repeating:"b",count:64)
        XCTAssertTrue(DependencyRules.diff(revision:current,assets:changedAssets,evidence:f.evidence).contains{$0.id=="asset:"+f.assets[1].id+":changed" && $0.sceneIDs==[current.scenes[0].id]})
        var changedSources=try f.repository.read();changedSources.projects[0].revisions[1].review.sound=true;changedSources.assets=changedAssets
        try DependencyRules.refreshDependents(in:&changedSources,workspaceID:f.workspace.id,changedAssetIDs:[f.assets[1].id],reason:"纹理原件发生变化")
        XCTAssertEqual(changedSources.projects[0].revisions.count,3)
        XCTAssertTrue(changedSources.projects[0].revisions[1].review.sound);XCTAssertFalse(changedSources.projects[0].current.review.sound)
        var foreign=f.assets;foreign[1].workspaceID="different"
        XCTAssertThrowsError(try DependencyRules.freeze(revision:current,assets:foreign,evidence:f.evidence))
        XCTAssertThrowsError(try DependencyRules.freeze(revision:current,assets:Array(f.assets.prefix(1)),evidence:f.evidence))
    }
    func testSourceFrameSamplingUsesExplicitJointAndShortestQuaternionArc() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let middle=try f.model.sampledTransform(instanceID:"actor",sourceFrame:10,durationFrames:21)
        XCTAssertEqual(middle.translation.x,1,accuracy:0.000001)
        let joint=try f.model.sampledTransform(instanceID:"actor",jointName:"hip",sourceFrame:10,durationFrames:21)
        XCTAssertEqual(joint.rotation.z,sqrt(0.5),accuracy:0.000001);XCTAssertEqual(joint.rotation.w,sqrt(0.5),accuracy:0.000001)
        var same=f.model;same.jointTracks[0].keyframes[1].transform.rotation = .init(w:-1)
        XCTAssertEqual(try same.sampledTransform(instanceID:"actor",jointName:"hip",sourceFrame:10,durationFrames:21).rotation.w,1,accuracy:0.000001)
        for bad in [-1,21,Int.max] {XCTAssertThrowsError(try f.model.sampledTransform(instanceID:"actor",sourceFrame:bad,durationFrames:21))}
        XCTAssertThrowsError(try f.model.sampledTransform(instanceID:"actor",jointName:"invented",sourceFrame:0,durationFrames:21))
        let reopened=try Codec.decoder().decode(ModelScene3D.self,from:Codec.data(f.model))
        XCTAssertEqual(try f.model.contentDigest(durationFrames:21),try reopened.contentDigest(durationFrames:21))
        let legacyBytes=try Codec.data(f.model.instances[0])
        let legacy=try XCTUnwrap(JSONSerialization.jsonObject(with:legacyBytes) as? [String:Any])
        XCTAssertNil(legacy["materialInterpretation"],"旧缺省不得新增解释键或改变原编码")
        XCTAssertEqual(legacyBytes,try Codec.data(Codec.decoder().decode(ModelInstance3D.self,from:legacyBytes)))
        XCTAssertNil(reopened.instances[0].materialInterpretation)
        let defaults=ModelMaterialInterpretation()
        XCTAssertEqual(defaults.vertexColors,.source);XCTAssertEqual(defaults.normalEncoding,.rgb)
        XCTAssertNil(defaults.opaqueDiffuseMaterialIDs)
        let oldInterpretation=Data(#"{"normalEncoding":"rgb","vertexColors":"source"}"#.utf8)
        XCTAssertEqual(try Codec.data(defaults),oldInterpretation,"nil列表不得在旧显式解释编码中新增键")
        XCTAssertEqual(try Codec.data(Codec.decoder().decode(ModelMaterialInterpretation.self,from:oldInterpretation)),oldInterpretation)
        var explicit=f.model;explicit.instances[0].materialInterpretation=defaults
        XCTAssertNotEqual(try f.model.contentDigest(durationFrames:21),try explicit.contentDigest(durationFrames:21),"显式设置进入内容摘要")
        var ignored=explicit;ignored.instances[0].materialInterpretation!.vertexColors = .ignored
        XCTAssertNotEqual(try explicit.contentDigest(durationFrames:21),try ignored.contentDigest(durationFrames:21))
        var encoded=ignored;encoded.instances[0].materialInterpretation!.normalEncoding = .redGreenPositiveZ
        XCTAssertNotEqual(try ignored.contentDigest(durationFrames:21),try encoded.contentDigest(durationFrames:21))
        XCTAssertEqual(encoded,try Codec.decoder().decode(ModelScene3D.self,from:Codec.data(encoded)))
        var opaque=encoded;opaque.instances[0].materialInterpretation!.opaqueDiffuseMaterialIDs=["bodyMaterial"]
        XCTAssertNotEqual(try encoded.contentDigest(durationFrames:21),try opaque.contentDigest(durationFrames:21),"显式不透明材质列表进入内容摘要")
        var otherOpaque=opaque;otherOpaque.instances[0].materialInterpretation!.opaqueDiffuseMaterialIDs=["capMaterial"]
        XCTAssertNotEqual(try opaque.contentDigest(durationFrames:21),try otherOpaque.contentDigest(durationFrames:21))
        XCTAssertEqual(opaque,try Codec.decoder().decode(ModelScene3D.self,from:Codec.data(opaque)))
        let definitions=AgentSchemas.definitions()
        XCTAssertEqual(definitions["ModelVertexColorUsage"]?.object?["enum"],AgentValue.array([.string("source"),.string("ignored")]))
        XCTAssertEqual(definitions["ModelNormalTextureEncoding"]?.object?["enum"],AgentValue.array([.string("rgb"),.string("redGreenPositiveZ")]))
        XCTAssertEqual(definitions["ModelMaterialInterpretation"]?.object?["additionalProperties"],.boolean(false))
        XCTAssertEqual(definitions["ModelMaterialInterpretation"]?.object?["properties"]?.object?["normalEncoding"]?.object?["$ref"],.string("#/$defs/ModelNormalTextureEncoding"))
        XCTAssertEqual(definitions["ModelMaterialInterpretation"]?.object?["required"],.array([.string("vertexColors"),.string("normalEncoding")]))
        if case .array(let options)?=definitions["ModelMaterialInterpretation"]?.object?["properties"]?.object?["opaqueDiffuseMaterialIDs"]?.object?["anyOf"] {
            XCTAssertEqual(options.first?.object?["minItems"],.number(1));XCTAssertEqual(options.first?.object?["maxItems"],.number(128))
            XCTAssertEqual(options.first?.object?["uniqueItems"],.boolean(true));XCTAssertEqual(options.first?.object?["items"]?.object?["type"],.string("string"))
            XCTAssertEqual(options.last?.object?["type"],.string("null"))
        } else {XCTFail("可选原材质列表须有明确数组schema")}
        XCTAssertNotNil(definitions["ModelInstance3D"]?.object?["properties"]?.object?["materialInterpretation"])
    }
    func testMalformedCameraTracksAndTextureClosureRejectBeforeSave() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        var candidates: [ModelScene3D]=[]
        var bad=f.model;bad.camera.target=bad.camera.position;candidates.append(bad)
        bad=f.model;bad.camera.up = .init();candidates.append(bad)
        bad=f.model;bad.camera.near=bad.camera.far;candidates.append(bad)
        bad=f.model;bad.instances[0].transform.scale.x=0;candidates.append(bad)
        bad=f.model;bad.instances[0].transform.rotation.w=2;candidates.append(bad)
        bad=f.model;bad.jointTracks[0].jointName="invented";candidates.append(bad)
        bad=f.model;bad.jointTracks.append(bad.jointTracks[0]);candidates.append(bad)
        bad=f.model;bad.transformTracks[0].keyframes[1].frame=0;candidates.append(bad)
        bad=f.model;bad.transformTracks[0].keyframes[1].frame=19;candidates.append(bad)
        bad=f.model;bad.instances[0].resource.textures.removeAll();candidates.append(bad)
        bad=f.model;bad.lights[0].intensity = .infinity;candidates.append(bad)
        for ids in [[],["unknownMaterial"],["bodyMaterial","bodyMaterial"],[" bodyMaterial"],["bodyMaterial\n"],[String(repeating:"x",count:161)]] {
            bad=f.model;bad.instances[0].materialInterpretation = .init(opaqueDiffuseMaterialIDs:ids);candidates.append(bad)
        }
        for candidate in candidates {XCTAssertThrowsError(try candidate.validate(durationFrames:21,assets:f.assets))}
        var bounded=f.model
        bounded.instances[0].resource.inspection.materials=(0..<129).map{.init(id:"material\($0)",effectID:"surfaceEffect")}
        bounded.instances[0].materialInterpretation = .init(opaqueDiffuseMaterialIDs:(0..<128).map{"material\($0)"})
        XCTAssertNoThrow(try bounded.validate(durationFrames:21,assets:f.assets),"纯结构边界接受128个明确声明的材质，不代原件验真")
        bounded.instances[0].materialInterpretation!.opaqueDiffuseMaterialIDs!.append("material128")
        XCTAssertThrowsError(try bounded.validate(durationFrames:21,assets:f.assets),"129个均已声明的材质仍超过有限上限")
        var wrong=scene(f);wrong.gameWorld=GameWorld(width:1,height:1,tiles:["floor"],entities:[])
        XCTAssertThrowsError(try wrong.validate(assets:f.assets))
        wrong=scene(f);wrong.kind = .explanation;XCTAssertThrowsError(try wrong.validate(assets:f.assets))
        for bytes in [Data(#"{"vertexColors":"guessed","normalEncoding":"rgb"}"#.utf8),Data(#"{"vertexColors":"source","normalEncoding":"guessed"}"#.utf8)] {
            XCTAssertThrowsError(try Codec.decoder().decode(ModelMaterialInterpretation.self,from:bytes),"未知枚举不能回退成默认解释")
        }
    }
    func testLocksProtectResourceTracksAndDeletionUntilExplicitNormalUnlock() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let s=scene(f),original=project(s,f)
        let locked=try Editor.apply([.lockModelInstance(s.id,"actor",true)],to:original,baseRevision:original.current.id,assets:f.assets,message:"锁定模型")
        var changed=locked.current.scenes[0];changed.modelScene3D!.jointTracks[0].keyframes[1].transform.translation.x=3
        XCTAssertThrowsError(try Editor.apply([.replaceScene(s.id,changed)],to:locked,baseRevision:locked.current.id,assets:f.assets,message:"不可改锁定骨骼"))
        XCTAssertThrowsError(try Editor.apply([.removeScene(s.id)],to:locked,baseRevision:locked.current.id,assets:f.assets,message:"不可删锁定实例"))
        var changedInterpretation=locked.current.scenes[0]
        changedInterpretation.modelScene3D!.instances[0].materialInterpretation = .init(vertexColors:.ignored,normalEncoding:.redGreenPositiveZ,opaqueDiffuseMaterialIDs:["bodyMaterial"])
        XCTAssertThrowsError(try Editor.apply([.replaceScene(s.id,changedInterpretation)],to:locked,baseRevision:locked.current.id,assets:f.assets,message:"不可改锁定实例材质解释"))
        var opacityOnly=locked.current.scenes[0]
        opacityOnly.modelScene3D!.instances[0].materialInterpretation = .init(opaqueDiffuseMaterialIDs:["bodyMaterial"])
        XCTAssertThrowsError(try Editor.apply([.replaceScene(s.id,opacityOnly)],to:locked,baseRevision:locked.current.id,assets:f.assets,message:"仅改不透明材质也须先解锁"))
        XCTAssertThrowsError(try Editor.apply([.splitScene(s.id,10)],to:original,baseRevision:original.current.id,assets:f.assets,message:"不可复制动作区间"))
        let unlocked=try Editor.apply([.lockModelInstance(s.id,"actor",false)],to:locked,baseRevision:locked.current.id,assets:f.assets,message:"显式解锁")
        changed.modelScene3D!.instances[0].locked=false
        XCTAssertNoThrow(try Editor.apply([.replaceScene(s.id,changed)],to:unlocked,baseRevision:unlocked.current.id,assets:f.assets,message:"修改明确骨骼轨道"))
        changedInterpretation.modelScene3D!.instances[0].locked=false
        XCTAssertNoThrow(try Editor.apply([.replaceScene(s.id,changedInterpretation)],to:unlocked,baseRevision:unlocked.current.id,assets:f.assets,message:"解锁后显式修改材质解释"))
        var sceneLocked=original;sceneLocked.revisions[0].scenes[0].locked=true
        XCTAssertThrowsError(try Editor.apply([.lockModelInstance(s.id,"actor",true)],to:sceneLocked,baseRevision:sceneLocked.current.id,assets:f.assets,message:"镜头锁优先"))
    }
    func testModelChangesInvalidateReviewAndSourceRightsGateModelsWithoutLegacyRecording() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        var s=scene(f);s.captions=[.init(text:"测试",startFrame:0,endFrame:21,confirmed:true)]
        var original=project(s,f);original.revisions[0].review.sound=true;original.revisions[0].review.captions=true
        var changed=s;changed.modelScene3D!.camera.position.x=1
        let result=try Editor.apply([.replaceScene(s.id,changed)],to:original,baseRevision:original.current.id,assets:f.assets,message:"移动相机")
        XCTAssertFalse(result.current.review.sound);XCTAssertFalse(result.current.review.captions)
        XCTAssertFalse(result.current.scenes[0].captions[0].confirmed)
        XCTAssertNotEqual(try original.current.contentDigest(),try result.current.contentDigest())
        XCTAssertTrue(result.current.invalidated.contains(where:{$0.contains("三维模型")}))
        var materialChange=s
        materialChange.modelScene3D!.instances[0].materialInterpretation = .init(opaqueDiffuseMaterialIDs:["bodyMaterial"])
        let materialResult=try Editor.apply([.replaceScene(s.id,materialChange)],to:original,baseRevision:original.current.id,assets:f.assets,message:"显式材质解释")
        XCTAssertFalse(materialResult.current.review.sound);XCTAssertFalse(materialResult.current.review.captions)
        XCTAssertFalse(materialResult.current.scenes[0].captions[0].confirmed)
        XCTAssertNotEqual(try original.current.contentDigest(),try materialResult.current.contentDigest())
        var database=try f.repository.read();database.projects=[result]
        let checkedAt=Date(),validIssues=try Quality.inspect(result.current,database:database,requireReview:false,now:checkedAt)
        XCTAssertFalse(validIssues.contains{$0.id.contains("model_renderer")},"内容质量不再假定缺少相容运行时，真实模块仍由Host独立校验")
        XCTAssertFalse(validIssues.contains{$0.id==s.id+"simulation_recording"},"三维模型不借旧二维规则回放验收")
        XCTAssertFalse(validIssues.contains{$0.id.hasPrefix(s.id+"model_source_")},"模型和纹理的真实当前工作区来源有效")
        for asset in f.assets {
            let assetIndex=try XCTUnwrap(database.assets.firstIndex{$0.id==asset.id})
            let proofIndex=try XCTUnwrap(database.evidence.firstIndex{$0.id==asset.evidenceID})
            for mutation in 0..<8 {
                var denied=database
                switch mutation {
                case 0:denied.evidence[proofIndex].verified=false
                case 1:denied.evidence[proofIndex].expiresAt=checkedAt.addingTimeInterval(-1)
                case 2:denied.evidence[proofIndex].workspaceID="foreign-workspace"
                case 3:denied.assets[assetIndex].workspaceID="foreign-workspace"
                case 4:denied.evidence[proofIndex].assetID="another-source-asset"
                case 5:denied.assets[assetIndex].evidenceID=nil
                case 6:denied.evidence[proofIndex].source=""
                default:denied.evidence[proofIndex].owner=""
                }
                if mutation==3 {
                    XCTAssertThrowsError(try Quality.inspect(result.current,database:denied,requireReview:false,now:checkedAt),"跨工作区资产先在实际场景资源校验拒绝")
                    continue
                }
                let issues=try Quality.inspect(result.current,database:denied,requireReview:false,now:checkedAt)
                XCTAssertTrue(issues.contains{$0.id==s.id+"model_source_"+asset.id && $0.blocking},"撤回、过期、跨工作区、错绑定或缺来源不能借三维输入越过门禁")
            }
        }
        var ordinary=s;ordinary.modelScene3D=nil;ordinary.simulationRecording=nil
        var ordinaryRevision=result.current;ordinaryRevision.scenes=[ordinary]
        XCTAssertTrue(try Quality.inspect(ordinaryRevision,database:database,requireReview:false,now:checkedAt).contains{$0.id==s.id+"simulation_recording" && $0.blocking},"独立普通仿真仍保留原录制门禁")
        let legacy=Scene(title:"旧工程",body:"")
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(legacy)) as? [String:Any])
        XCTAssertNil(object["modelScene3D"])
        XCTAssertEqual(try Codec.data(legacy),try Codec.data(Codec.decoder().decode(Scene.self,from:Codec.data(legacy))))
        let practiceBytes=Data(EditorPracticeRules.sourceText.utf8)
        let practiceSource=Asset(workspaceID:f.workspace.id,name:"练习.txt",hash:Codec.hash(practiceBytes),ext:"txt",bytes:practiceBytes.count,mediaType:"text")
        var practice=try LearningExample.project(workspaceID:f.workspace.id,asset:practiceSource)
        XCTAssertTrue(EditorPracticeRules.allows(project:practice,assets:[practiceSource]+f.assets))
        var revision=practice.current;revision.id=Codec.id();revision.scenes[0].modelScene3D=f.model;practice.revisions.append(revision)
        XCTAssertFalse(EditorPracticeRules.allows(project:practice,assets:[practiceSource]+f.assets),"新三维外部资源不能借旧练习路径获得发行权益")
    }
    func testForgedInspectionAndJointTrackRejectInSaveDryRunActualAndBackupRestore() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        var original=scene(f);original.modelScene3D=nil
        let originalProject=project(original,f);try f.repository.transaction{$0.projects=[originalProject]}
        let before=try Codec.data(f.repository.read())
        var forged=scene(f)
        // Both caller-controlled fields agree with each other and retain the
        // authentic asset hash. Only reinspection of stored bytes detects this.
        forged.modelScene3D!.instances[0].resource.inspection.jointNames=["invented"]
        forged.modelScene3D!.jointTracks[0].jointName="invented"
        XCTAssertNoThrow(try forged.validate(assets:f.assets),"纯结构校验不读取任意文件，也不能充当原件证明")
        XCTAssertNoThrow(try Editor.apply([.replaceScene(original.id,forged)],to:originalProject,baseRevision:originalProject.current.id,assets:f.assets,message:"仅结构编辑"))
        let candidate=project(forged,f)
        XCTAssertThrowsError(try f.repository.transaction{$0.projects.append(candidate)})
        let forgedInput=try input(originalProject,edits:[.replaceScene(original.id,forged)])
        XCTAssertThrowsError(try AgentPreview.evaluate(command:"edit apply",data:forgedInput,database:f.repository.read(),principal:"owner",repository:f.repository))
        XCTAssertThrowsError(try f.repository.performAgentMutation(command:"edit apply",data:forgedInput,principal:"owner",requestID:"forged-model"))
        XCTAssertEqual(try Codec.data(f.repository.read()),before,"拒绝保存、预演及执行都不得增加版本、代际或回执")
        let validInput=try input(originalProject,edits:[.replaceScene(original.id,scene(f))])
        XCTAssertThrowsError(try AgentPreview.evaluate(command:"edit apply",data:validInput,database:f.repository.read(),principal:"owner"),"没有工作区原件上下文不能声称模型预演通过")
        XCTAssertNoThrow(try AgentPreview.evaluate(command:"edit apply",data:validInput,database:f.repository.read(),principal:"owner",repository:f.repository))
        var otherFact=scene(f);otherFact.modelScene3D!.instances[0].resource.inspection.unitMeters=2
        XCTAssertNoThrow(try otherFact.validate(assets:f.assets))
        XCTAssertThrowsError(try f.repository.transaction{$0.projects.append(project(otherFact,f))},"核对完整解析结果，不能只比较关节列表")
        let validProject=project(scene(f),f);try f.repository.transaction{$0.projects.append(validProject)}
        var backup=try PropertyListDecoder().decode(Repository.Backup.self,from:f.repository.backup())
        var snapshot=try Codec.decoder().decode(Database.self,from:backup.snapshot)
        let index=try XCTUnwrap(snapshot.projects.firstIndex{$0.id==validProject.id})
        snapshot.projects[index].revisions[0].scenes=[forged]
        backup.snapshot=try Codec.data(snapshot);backup.digest=Codec.hash(backup.snapshot)
        let destination=f.root.appendingPathComponent("forged-restore")
        XCTAssertThrowsError(try Repository.restore(PropertyListEncoder().encode(backup),to:destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path),"含源备份在写恢复目录前核对实际DAE")
        let source=f.repository.assetURL(f.assets[0]),external=f.root.appendingPathComponent("external.dae")
        try Data(contentsOf:source).write(to:external);try FileManager.default.removeItem(at:source)
        try FileManager.default.createSymbolicLink(at:source,withDestinationURL:external)
        XCTAssertThrowsError(try f.repository.transaction{_ in},"每次保存都重核物理文件，不复用上次通过的解析结果或跟随链接")
        XCTAssertThrowsError(try AgentPreview.evaluate(command:"edit apply",data:validInput,database:f.repository.read(),principal:"owner",repository:f.repository))
    }
}
