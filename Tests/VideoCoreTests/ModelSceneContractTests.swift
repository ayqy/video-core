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
        <library_visual_scenes><visual_scene id="stage"><node id="hip" sid="hip" type="JOINT"/><node id="mesh"><instance_geometry url="#triangle"/></node><node id="alternate"><instance_geometry url="#triangle"/></node></visual_scene></library_visual_scenes>
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
    func testShadowStylePreservesLegacyWireAndExactOriginalKeySelection() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        struct OldLight:Encodable {let id:String;let kind:ModelLightKind;let color:String;let intensity:Double;let transform:ModelTransform3D}
        let light=f.model.lights[0],old=OldLight(id:light.id,kind:light.kind,color:light.color,intensity:light.intensity,transform:light.transform)
        let bytes=try Codec.data(old),decoded=try Codec.decoder().decode(ModelLight3D.self,from:bytes)
        XCTAssertNil(decoded.shadowStyle);XCTAssertEqual(try Codec.data(decoded),bytes)
        let choices:[[ModelLight3D]]=[[],[.init(id:"ambient",kind:.ambient)],
            [.init(id:"zero",kind:.directional,intensity:0),.init(id:"black",kind:.directional,color:"000000")],
            [.init(id:"fill",kind:.directional,intensity:100),.init(id:"sun",kind:.directional,intensity:200)],
            [.init(id:"first",kind:.directional,intensity:200),.init(id:"last",kind:.directional,intensity:200)],
            [.init(id:"last",kind:.directional,intensity:200),.init(id:"first",kind:.directional,intensity:200)],
            [.init(id:"omni",kind:.omni,intensity:9999),.init(id:"sun",kind:.directional,intensity:2)]]
        for lights in choices {
            var model=f.model;model.lights=lights
            let original=lights.filter{$0.kind == .directional && $0.intensity>0 && $0.color != "000000"}.max{$0.intensity<$1.intensity}?.id
            XCTAssertEqual(model.shadowLightID,original,"旧过滤、max顺序和相等强度行为不能改变")
        }
        for (opacity,radius) in [(0.0,0.0),(1.0,16.0),(0.24,3.0)] {
            var model=f.model;model.lights[0].shadowStyle = .init(opacity:opacity,radius:radius)
            XCTAssertNoThrow(try model.validate(durationFrames:21,assets:f.assets))
            XCTAssertEqual(try Codec.decoder().decode(ModelScene3D.self,from:Codec.data(model)),model)
        }
    }
    func testShadowStyleRejectsNonKeyNonfiniteOutOfRangeAndMalformedWire() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let style=ModelShadowStyle3D(opacity:0.24,radius:3)
        for field in ["opacity","radius"] {
            for number in [Double.nan,Double.infinity,-Double.infinity,-0.001,field=="opacity" ? 1.001:16.001] {
                var invalid=style
                if field=="opacity" {invalid.opacity=number}else{invalid.radius=number}
                XCTAssertThrowsError(try invalid.validate(),field)
                var model=f.model;model.lights[0].shadowStyle=invalid
                XCTAssertThrowsError(try model.validate(durationFrames:21),field)
            }
        }
        for rejected in [ModelLight3D(id:"ambient",kind:.ambient),.init(id:"omni",kind:.omni),
                         .init(id:"zero",kind:.directional,intensity:0),.init(id:"black",kind:.directional,color:"000000"),
                         .init(id:"fill",kind:.directional,intensity:100)] {
            var model=f.model,light=rejected;light.shadowStyle=style;model.lights.append(light)
            XCTAssertThrowsError(try model.validate(durationFrames:21),rejected.id)
            model.lights=[light]
            if rejected.id != "fill" {XCTAssertThrowsError(try model.validate(durationFrames:21),"没有实际主投影灯时不可接受样式")}
        }
        var light=f.model.lights[0];light.shadowStyle=style
        let wire=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(light)) as? [String:Any])
        for index in 0..<7 {
            var changed=wire,fields=try XCTUnwrap(wire["shadowStyle"] as? [String:Any])
            switch index {
            case 0:changed["shadowStyle"]=NSNull()
            case 1:fields.removeValue(forKey:"radius");changed["shadowStyle"]=fields
            case 2:fields["opacity"]=NSNull();changed["shadowStyle"]=fields
            case 3:fields["radius"]="3";changed["shadowStyle"]=fields
            case 4:fields["unknown"]=1;changed["shadowStyle"]=fields
            case 5:changed["unknown"]=1
            default:changed["shadowStyle"]=[:]
            }
            XCTAssertThrowsError(try Codec.decoder().decode(ModelLight3D.self,from:JSONSerialization.data(withJSONObject:changed)),"显式样式不可静默忽略未知、缺失或null字段")
        }
    }
    func testShadowStyleNormalEditAndColdRestorePreserveOriginalResourcesAndEnterDigest() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let original=scene(f);var project=project(original,f)
        project.revisions[0].review.sound=true;project.revisions[0].review.fullPreview=true
        try f.repository.transaction{$0.projects=[project]}
        var changed=original;changed.modelScene3D!.lights[0].shadowStyle = .init(opacity:0.24,radius:3)
        let before=try Codec.data(f.repository.read()),data=try input(project,edits:[.replaceScene(original.id,changed)])
        _=try AgentMutationExecutor.preview(command:"edit apply",data:data,database:f.repository.read(),principal:"owner",repository:f.repository)
        XCTAssertEqual(try Codec.data(f.repository.read()),before)
        _=try f.repository.performAgentMutation(command:"edit apply",data:data,principal:"owner",requestID:"save-shadow-style")
        let current=try XCTUnwrap(f.repository.read().projects.first?.current),model=try XCTUnwrap(current.scenes[0].modelScene3D)
        XCTAssertEqual(model,changed.modelScene3D);XCTAssertEqual(model.instances,f.model.instances)
        XCTAssertEqual(model.camera,f.model.camera);XCTAssertEqual(model.transformTracks,f.model.transformTracks);XCTAssertEqual(model.jointTracks,f.model.jointTracks)
        XCTAssertEqual(try PluginModelBankManifest(scene:model,durationFrames:21),try PluginModelBankManifest(scene:f.model,durationFrames:21))
        XCTAssertNotEqual(try model.contentDigest(durationFrames:21),try f.model.contentDigest(durationFrames:21))
        XCTAssertFalse(current.review.sound);XCTAssertFalse(current.review.fullPreview)
        let cold=try Repository.restore(f.repository.backup(),to:f.root.appendingPathComponent("shadow-style-cold"))
        XCTAssertEqual(try cold.read().projects.first?.current.contentDigest(),try current.contentDigest())
        XCTAssertEqual(try cold.read().projects.first?.current.scenes[0].modelScene3D,model)
        for asset in f.assets {XCTAssertEqual(try Data(contentsOf:cold.assetURL(asset)),try Data(contentsOf:f.repository.assetURL(asset)))}
    }
    func testCameraMotionKeepsLegacyBytesAndDeterministicEndpointHolds() throws {
        let legacy=Data(#"{"far":1000,"near":0.01,"position":{"x":0,"y":2,"z":5},"target":{"x":0,"y":0,"z":0},"up":{"x":0,"y":1,"z":0},"verticalFieldOfViewDegrees":45}"#.utf8)
        var camera=try Codec.decoder().decode(ModelCamera3D.self,from:legacy)
        XCTAssertNil(camera.keyframes);XCTAssertEqual(try Codec.data(camera),legacy)
        let still=try ModelCameraTimeline3D(camera:camera,durationFrames:21)
        XCTAssertEqual(try still.value(at:20),camera);XCTAssertEqual(try still.value(at:0),camera)
        let first=ModelCameraKeyframe3D(frame:4,position:camera.position,target:camera.target,verticalFieldOfViewDegrees:45)
        let last=ModelCameraKeyframe3D(frame:16,position:.init(x:3,y:2,z:4),target:.init(x:3),verticalFieldOfViewDegrees:51)
        camera.keyframes=[first,last]
        let timeline=try ModelCameraTimeline3D(camera:camera,durationFrames:21)
        let middle=try timeline.value(at:10)
        XCTAssertEqual(middle.position,.init(x:1.5,y:2,z:4.5));XCTAssertEqual(middle.target,.init(x:1.5))
        XCTAssertEqual(middle.verticalFieldOfViewDegrees,48);XCTAssertNil(middle.keyframes)
        XCTAssertEqual(middle.up,camera.up);XCTAssertEqual(middle.near,camera.near);XCTAssertEqual(middle.far,camera.far)
        XCTAssertEqual(try timeline.value(at:0),try timeline.value(at:4),"首个关键帧前明确保持首pose")
        XCTAssertEqual(try timeline.value(at:20),try timeline.value(at:16),"末个关键帧后明确保持末pose")
        XCTAssertEqual(try timeline.value(at:10),middle,"末帧后乱序回到中帧不得继承上一镜头")
        XCTAssertThrowsError(try timeline.value(at:-1));XCTAssertThrowsError(try timeline.value(at:21))
        XCTAssertEqual(try Codec.decoder().decode(ModelCamera3D.self,from:Codec.data(camera)),camera)
        // A frame-indexed camera is bounded by the actual scene duration,
        // rather than an unrelated 4096-key transform-track restriction.
        camera.keyframes=(0..<5000).map { .init(frame:$0,position:first.position,target:first.target,verticalFieldOfViewDegrees:45) }
        XCTAssertEqual(try ModelCameraTimeline3D(camera:camera,durationFrames:5000).value(at:4999).position,first.position)
    }
    func testCameraMotionRejectsMalformedWireFramesAndContinuousDegeneracy() throws {
        let base=ModelCamera3D(position:.init(z:4),target:.init())
        func key(_ frame:Int,_ position:ModelVector3 = .init(z:4),_ target:ModelVector3 = .init(),_ fov:Double = 45)->ModelCameraKeyframe3D {
            .init(frame:frame,position:position,target:target,verticalFieldOfViewDegrees:fov)
        }
        let bad:[[ModelCameraKeyframe3D]]=[[],[key(-1)],[key(21)],[key(3),key(3)],[key(5),key(2)],
            [key(0,.init())],[key(0,.init(z:.nan))],[key(0,.init(z:4),.init(),.infinity)],
            [key(0),key(3,.init(z:-4))], // target crossing at fractional frame 1.5
            [key(0,.init(z:4),.init(y:2)),key(3,.init(z:-4),.init(y:2))]] // view becomes parallel to up
        for keys in bad {
            var camera=base;camera.keyframes=keys
            XCTAssertThrowsError(try ModelCameraTimeline3D(camera:camera,durationFrames:21))
        }
        var valid=base;valid.keyframes=[key(0),key(20,.init(x:2,z:4),.init(x:2))]
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(valid)) as? [String:Any])
        for index in 0..<8 {
            var changed=object
            var keys=try XCTUnwrap(changed["keyframes"] as? [[String:Any]])
            switch index {
            case 0:changed["unknown"]=true
            case 1:changed["keyframes"]=NSNull()
            case 2:changed["keyframes"]="not a source-frame track"
            case 3:keys[0]["unknown"]=true;changed["keyframes"]=keys
            case 4:keys[0]["target"]=NSNull();changed["keyframes"]=keys
            case 5:keys[0]["verticalFieldOfViewDegrees"]=NSNull();changed["keyframes"]=keys
            case 6:keys[0]["position"]=["x":0,"y":0,"z":4,"unknown":1];changed["keyframes"]=keys
            default:keys[0].removeValue(forKey:"frame");changed["keyframes"]=keys
            }
            XCTAssertThrowsError(try Codec.decoder().decode(ModelCamera3D.self,from:JSONSerialization.data(withJSONObject:changed)),"未知/缺失/null镜头数据不能静默降级，case \(index)")
        }
        var single=base;single.keyframes=[key(10,.init(x:1,z:4),.init(x:1))]
        let timeline=try ModelCameraTimeline3D(camera:single,durationFrames:21)
        XCTAssertEqual(try timeline.value(at:0),try timeline.value(at:20),"单pose也是定义完整的静止取景")
    }
    func testCameraMotionNormalEditAndColdRestoreRetainOriginalSources() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let original=scene(f);var project=project(original,f)
        project.revisions[0].review.sound=true;project.revisions[0].review.fullPreview=true
        try f.repository.transaction {$0.projects=[project]}
        var changed=original
        let camera=try XCTUnwrap(changed.modelScene3D?.camera)
        changed.modelScene3D!.camera.keyframes=[
            .init(frame:0,position:camera.position,target:camera.target,verticalFieldOfViewDegrees:45),
            .init(frame:20,position:.init(x:2,y:2,z:4),target:.init(x:2),verticalFieldOfViewDegrees:40)]
        let before=try Codec.data(f.repository.read()),data=try input(project,edits:[.replaceScene(original.id,changed)])
        _=try AgentMutationExecutor.preview(command:"edit apply",data:data,database:f.repository.read(),principal:"owner",repository:f.repository)
        XCTAssertEqual(try Codec.data(f.repository.read()),before)
        _=try f.repository.performAgentMutation(command:"edit apply",data:data,principal:"owner",requestID:"save-camera-motion")
        let current=try XCTUnwrap(f.repository.read().projects.first?.current),model=try XCTUnwrap(current.scenes[0].modelScene3D)
        XCTAssertEqual(model.camera,changed.modelScene3D?.camera);XCTAssertEqual(model.instances,f.model.instances)
        XCTAssertEqual(model.transformTracks,f.model.transformTracks);XCTAssertEqual(model.jointTracks,f.model.jointTracks)
        XCTAssertEqual(try PluginModelBankManifest(scene:model,durationFrames:21),try PluginModelBankManifest(scene:f.model,durationFrames:21))
        XCTAssertNotEqual(try model.contentDigest(durationFrames:21),try f.model.contentDigest(durationFrames:21))
        XCTAssertFalse(current.review.sound);XCTAssertFalse(current.review.fullPreview)
        let cold=try Repository.restore(f.repository.backup(),to:f.root.appendingPathComponent("camera-motion-cold"))
        XCTAssertEqual(try cold.read().projects.first?.current.contentDigest(),try current.contentDigest())
        XCTAssertEqual(try cold.read().projects.first?.current.scenes[0].modelScene3D,model)
        for asset in f.assets {XCTAssertEqual(try Data(contentsOf:cold.assetURL(asset)),try Data(contentsOf:f.repository.assetURL(asset)))}
    }
    func testWaterSurfaceUsesExplicitBoundedOriginalIDsAndPreservesLegacyBytes() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let legacy=Data(#"{"normalEncoding":"redGreenPositiveZ","normalIntensityByMaterialID":{"bodyMaterial":0.35},"vertexColors":"source"}"#.utf8)
        let old=try Codec.decoder().decode(ModelMaterialInterpretation.self,from:legacy)
        XCTAssertNil(old.waterSurfaceByMaterialID);XCTAssertEqual(try Codec.data(old),legacy)
        var model=f.model;model.instances[0].materialInterpretation=old
        let oldDigest=try model.contentDigest(durationFrames:21),bank=try PluginModelBankManifest(scene:model,durationFrames:21)
        let water=ModelWaterSurface(baseColor:"#47AAA9",reflectionColor:"#C1E8E4",wavelength:0.8,flowSpeed:0.035)
        model.instances[0].materialInterpretation!.waterSurfaceByMaterialID=["bodyMaterial":water]
        XCTAssertNoThrow(try model.validate(durationFrames:21,assets:f.assets))
        XCTAssertNotEqual(try model.contentDigest(durationFrames:21),oldDigest)
        XCTAssertEqual(try PluginModelBankManifest(scene:model,durationFrames:21),bank)
        XCTAssertEqual(try Codec.decoder().decode(ModelScene3D.self,from:Codec.data(model)),model)
        for (length,speed) in [(0.05,0.0),(20.0,2.0)] {
            var changed=model;changed.instances[0].materialInterpretation!.waterSurfaceByMaterialID!["bodyMaterial"] = .init(baseColor:"#abcdef",reflectionColor:"#012345",wavelength:length,flowSpeed:speed)
            XCTAssertNoThrow(try changed.validate(durationFrames:21,assets:f.assets))
        }
        for field in ["baseColor","reflectionColor","wavelength","flowSpeed","missing","spaced","empty","rgb","cutout"] {
            var changed=model
            switch field {
            case "baseColor":changed.instances[0].materialInterpretation!.waterSurfaceByMaterialID!["bodyMaterial"]!.baseColor="47AAA9"
            case "reflectionColor":changed.instances[0].materialInterpretation!.waterSurfaceByMaterialID!["bodyMaterial"]!.reflectionColor="#C1E8EG"
            case "wavelength":changed.instances[0].materialInterpretation!.waterSurfaceByMaterialID!["bodyMaterial"]!.wavelength=0.049
            case "flowSpeed":changed.instances[0].materialInterpretation!.waterSurfaceByMaterialID!["bodyMaterial"]!.flowSpeed=2.001
            case "missing":changed.instances[0].materialInterpretation!.waterSurfaceByMaterialID=["guessed":water]
            case "spaced":changed.instances[0].materialInterpretation!.waterSurfaceByMaterialID=[" bodyMaterial":water]
            case "empty":changed.instances[0].materialInterpretation!.waterSurfaceByMaterialID=[:]
            case "rgb":changed.instances[0].materialInterpretation!.normalEncoding = .rgb
            default:changed.instances[0].materialInterpretation!.alphaCutoutMaterialIDs=["bodyMaterial"]
            }
            XCTAssertThrowsError(try changed.validate(durationFrames:21,assets:f.assets),field)
        }
        for number in [-Double.infinity,Double.nan,Double.infinity,-1.0,20.01] {
            var invalid=water;invalid.wavelength=number;XCTAssertThrowsError(try invalid.validate())
        }
        for number in [-Double.infinity,Double.nan,Double.infinity,-0.01,2.01] {
            var invalid=water;invalid.flowSpeed=number;XCTAssertThrowsError(try invalid.validate())
        }
        for invalid in [
            ##"{"baseColor":"#47AAA9","reflectionColor":"#C1E8E4","wavelength":0.8}"##,
            ##"{"baseColor":"#47AAA9","reflectionColor":"#C1E8E4","wavelength":0.8,"flowSpeed":0,"strength":0.35}"##,
            ##"{"baseColor":"#47AAA9","reflectionColor":"#C1E8E4","wavelength":null,"flowSpeed":0}"##,
            ##"{"baseColor":"#47AAA9","reflectionColor":"#C1E8E4","wavelength":"0.8","flowSpeed":0}"##,
            ##"{"baseColor":"#47AAA9","reflectionColor":"#C1E8E4","wavelength":0.01,"flowSpeed":0}"##] {
            XCTAssertThrowsError(try Codec.decoder().decode(ModelWaterSurface.self,from:Data(invalid.utf8)))
        }
        XCTAssertThrowsError(try Codec.decoder().decode(ModelMaterialInterpretation.self,from:Data(#"{"vertexColors":"source","normalEncoding":"redGreenPositiveZ","waterSurfaceByMaterialID":null}"#.utf8)))
        var bounded=f.model;bounded.instances[0].resource.inspection.materials=(0..<129).map{.init(id:"material\($0)",effectID:"surfaceEffect")}
        bounded.instances[0].materialInterpretation = .init(normalEncoding:.redGreenPositiveZ,waterSurfaceByMaterialID:Dictionary(uniqueKeysWithValues:(0..<128).map{("material\($0)",water)}))
        XCTAssertNoThrow(try bounded.validate(durationFrames:21,assets:f.assets))
        bounded.instances[0].materialInterpretation!.waterSurfaceByMaterialID!["material128"]=water
        XCTAssertThrowsError(try bounded.validate(durationFrames:21,assets:f.assets))
    }
    func testWaterSurfaceCASLocksAndColdRestorePreserveAllOriginalAssets() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let original=scene(f);var project=project(original,f)
        project.revisions[0].review.sound=true;project.revisions[0].review.fullPreview=true
        try f.repository.transaction{$0.projects=[project]}
        var changed=original
        let water=ModelWaterSurface(baseColor:"#47AAA9",reflectionColor:"#C1E8E4",wavelength:0.8,flowSpeed:0.035)
        changed.modelScene3D!.instances[0].materialInterpretation = .init(normalEncoding:.redGreenPositiveZ,normalIntensityByMaterialID:["bodyMaterial":0.35],waterSurfaceByMaterialID:["bodyMaterial":water])
        let before=try Codec.data(f.repository.read())
        var invalid=changed;invalid.modelScene3D!.instances[0].materialInterpretation!.waterSurfaceByMaterialID=["missing":water]
        XCTAssertThrowsError(try f.repository.performAgentMutation(command:"edit apply",data:input(project,edits:[.replaceScene(original.id,invalid)]),principal:"owner",requestID:Codec.id()))
        XCTAssertEqual(try Codec.data(f.repository.read()),before)
        let data=try input(project,edits:[.replaceScene(original.id,changed)])
        _=try AgentMutationExecutor.preview(command:"edit apply",data:data,database:f.repository.read(),principal:"owner",repository:f.repository)
        XCTAssertEqual(try Codec.data(f.repository.read()),before)
        let answer=try f.repository.performAgentMutation(command:"edit apply",data:data,principal:"owner",requestID:"water-surface-save")
        XCTAssertEqual(answer,try f.repository.performAgentMutation(command:"edit apply",data:data,principal:"owner",requestID:"water-surface-save"))
        let current=try XCTUnwrap(f.repository.read().projects.first?.current)
        XCTAssertEqual(current.scenes[0].modelScene3D,changed.modelScene3D)
        XCTAssertFalse(current.review.sound);XCTAssertFalse(current.review.fullPreview)
        XCTAssertEqual(Set((current.dependencies?.records ?? []).filter{$0.kind == .asset}.map{$0.asset!.id}),f.model.assetIDs)
        let locked=try Editor.apply([.lockModelInstance(original.id,"actor",true)],to:project,baseRevision:project.current.id,assets:f.assets,message:"锁定原实例")
        var lockedChange=locked.current.scenes[0];lockedChange.modelScene3D!.instances[0].materialInterpretation=changed.modelScene3D!.instances[0].materialInterpretation
        XCTAssertThrowsError(try Editor.apply([.replaceScene(original.id,lockedChange)],to:locked,baseRevision:locked.current.id,assets:f.assets,message:"锁定时不能改变水面解释"))
        let restored=try Repository.restore(f.repository.backup(),to:f.root.appendingPathComponent("water-surface-cold"))
        let cold=try XCTUnwrap(restored.read().projects.first?.current)
        XCTAssertEqual(try cold.contentDigest(),try current.contentDigest());XCTAssertEqual(cold.scenes[0].modelScene3D,changed.modelScene3D)
        for asset in f.assets {XCTAssertEqual(try Data(contentsOf:restored.assetURL(asset)),try Data(contentsOf:f.repository.assetURL(asset)))}
    }
    func testNormalIntensityUsesBoundedOriginalIDsAndPreservesLegacySourceBytes() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let legacy=Data(#"{"normalEncoding":"rgb","opaqueDiffuseMaterialIDs":["bodyMaterial"],"vertexColors":"source"}"#.utf8)
        let old=try Codec.decoder().decode(ModelMaterialInterpretation.self,from:legacy)
        XCTAssertNil(old.normalIntensityByMaterialID);XCTAssertEqual(try Codec.data(old),legacy)
        var model=f.model;model.instances[0].materialInterpretation=old
        let oldDigest=try model.contentDigest(durationFrames:21),bank=try PluginModelBankManifest(scene:model,durationFrames:21)
        for intensity in [0.0,0.25,1.0] {
            model.instances[0].materialInterpretation!.normalIntensityByMaterialID=["bodyMaterial":intensity]
            XCTAssertNoThrow(try model.validate(durationFrames:21,assets:f.assets))
            XCTAssertNotEqual(try model.contentDigest(durationFrames:21),oldDigest)
            XCTAssertEqual(try PluginModelBankManifest(scene:model,durationFrames:21),bank)
            XCTAssertEqual(try Codec.decoder().decode(ModelScene3D.self,from:Codec.data(model)),model)
        }
        let invalidMaps:[[String:Double]]=[[:],["missing":0.5],[" bodyMaterial":0.5],["bodyMaterial\n":0.5],
            [String(repeating:"x",count:161):0.5],["bodyMaterial":-0.01],["bodyMaterial":1.01],
            ["bodyMaterial":.nan],["bodyMaterial":.infinity],["bodyMaterial":-Double.infinity]]
        for values in invalidMaps {
            var invalid=model;invalid.instances[0].materialInterpretation!.normalIntensityByMaterialID=values
            XCTAssertThrowsError(try invalid.validate(durationFrames:21,assets:f.assets))
        }
        for invalid in [#"{"normalEncoding":"rgb","vertexColors":"source","normalIntensityByMaterialID":null}"#,
            #"{"normalEncoding":"rgb","vertexColors":"source","normalIntensityByMaterialID":{"bodyMaterial":"0.5"}}"#,
            #"{"normalEncoding":"rgb","vertexColors":"source","normalIntensity":0.5}"#] {
            XCTAssertThrowsError(try Codec.decoder().decode(ModelMaterialInterpretation.self,from:Data(invalid.utf8)))
        }
        var bounded=f.model
        bounded.instances[0].resource.inspection.materials=(0..<129).map{.init(id:"material\($0)",effectID:"surfaceEffect")}
        bounded.instances[0].materialInterpretation = .init(normalIntensityByMaterialID:Dictionary(uniqueKeysWithValues:(0..<128).map{("material\($0)",0.25)}))
        XCTAssertNoThrow(try bounded.validate(durationFrames:21,assets:f.assets))
        bounded.instances[0].materialInterpretation!.normalIntensityByMaterialID!["material128"]=0.25
        XCTAssertThrowsError(try bounded.validate(durationFrames:21,assets:f.assets))
    }
    func testNormalIntensityCASLocksAndColdRestorePreserveAllOriginalAssets() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let original=scene(f);var project=project(original,f)
        project.revisions[0].review.sound=true;project.revisions[0].review.fullPreview=true
        try f.repository.transaction{$0.projects=[project]}
        var changed=original
        changed.modelScene3D!.instances[0].materialInterpretation = .init(normalIntensityByMaterialID:["bodyMaterial":0.25])
        let before=try Codec.data(f.repository.read())
        var invalid=changed;invalid.modelScene3D!.instances[0].materialInterpretation!.normalIntensityByMaterialID=["missing":0.25]
        XCTAssertThrowsError(try f.repository.performAgentMutation(command:"edit apply",data:input(project,edits:[.replaceScene(original.id,invalid)]),principal:"owner",requestID:Codec.id()))
        XCTAssertEqual(try Codec.data(f.repository.read()),before)
        let data=try input(project,edits:[.replaceScene(original.id,changed)])
        _=try AgentMutationExecutor.preview(command:"edit apply",data:data,database:f.repository.read(),principal:"owner",repository:f.repository)
        XCTAssertEqual(try Codec.data(f.repository.read()),before)
        let answer=try f.repository.performAgentMutation(command:"edit apply",data:data,principal:"owner",requestID:"normal-intensity-save")
        XCTAssertEqual(answer,try f.repository.performAgentMutation(command:"edit apply",data:data,principal:"owner",requestID:"normal-intensity-save"))
        let current=try XCTUnwrap(f.repository.read().projects.first?.current)
        XCTAssertEqual(current.scenes[0].modelScene3D,changed.modelScene3D)
        XCTAssertFalse(current.review.sound);XCTAssertFalse(current.review.fullPreview)
        XCTAssertEqual(Set((current.dependencies?.records ?? []).filter{$0.kind == .asset}.map{$0.asset!.id}),f.model.assetIDs)
        let locked=try Editor.apply([.lockModelInstance(original.id,"actor",true)],to:project,baseRevision:project.current.id,assets:f.assets,message:"锁定原实例")
        var lockedChange=locked.current.scenes[0];lockedChange.modelScene3D!.instances[0].materialInterpretation=changed.modelScene3D!.instances[0].materialInterpretation
        XCTAssertThrowsError(try Editor.apply([.replaceScene(original.id,lockedChange)],to:locked,baseRevision:locked.current.id,assets:f.assets,message:"锁定时不能改变法线强度"))
        let restored=try Repository.restore(f.repository.backup(),to:f.root.appendingPathComponent("normal-intensity-cold"))
        let cold=try XCTUnwrap(restored.read().projects.first?.current)
        XCTAssertEqual(try cold.contentDigest(),try current.contentDigest());XCTAssertEqual(cold.scenes[0].modelScene3D,changed.modelScene3D)
        for asset in f.assets {XCTAssertEqual(try Data(contentsOf:restored.assetURL(asset)),try Data(contentsOf:f.repository.assetURL(asset)))}
    }
    func testAlphaCutoutUsesExplicitBoundedOriginalIDsAndKeepsLegacyBytes()throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let legacy=Data(#"{"normalEncoding":"rgb","opaqueDiffuseMaterialIDs":["bodyMaterial"],"vertexColors":"source"}"#.utf8)
        let old=try Codec.decoder().decode(ModelMaterialInterpretation.self,from:legacy)
        XCTAssertNil(old.alphaCutoutMaterialIDs);XCTAssertEqual(try Codec.data(old),legacy)
        for invalid in [#"{"normalEncoding":"rgb","vertexColors":"source","alphaCutoutThreshold":0.2}"#,#"{"normalEncoding":"rgb","vertexColors":"source","alphaCutoutMaterialIDs":"bodyMaterial"}"#] {
            XCTAssertThrowsError(try Codec.decoder().decode(ModelMaterialInterpretation.self,from:Data(invalid.utf8)),"裁切阈值固定且未知解释不能被静默忽略")
        }
        var model=f.model;model.instances[0].materialInterpretation=old
        let oldDigest=try model.contentDigest(durationFrames:21),bank=try PluginModelBankManifest(scene:model,durationFrames:21)
        model.instances[0].materialInterpretation!.alphaCutoutMaterialIDs=["bodyMaterial"]
        XCTAssertNoThrow(try model.validate(durationFrames:21,assets:f.assets),"同一原材质可同时声明diffuse不透明与独立transparent裁切")
        XCTAssertNotEqual(try model.contentDigest(durationFrames:21),oldDigest)
        XCTAssertEqual(try PluginModelBankManifest(scene:model,durationFrames:21),bank)
        XCTAssertEqual(try Codec.decoder().decode(ModelScene3D.self,from:Codec.data(model)),model)
        for ids in [[],["unknownMaterial"],["bodyMaterial","bodyMaterial"],[" bodyMaterial"],["bodyMaterial\n"],[String(repeating:"x",count:161)]] {
            var invalid=model;invalid.instances[0].materialInterpretation!.alphaCutoutMaterialIDs=ids
            XCTAssertThrowsError(try invalid.validate(durationFrames:21,assets:f.assets))
        }
        var bounded=f.model
        bounded.instances[0].resource.inspection.materials=(0..<129).map{.init(id:"material\($0)",effectID:"surfaceEffect")}
        bounded.instances[0].materialInterpretation = .init(alphaCutoutMaterialIDs:(0..<128).map{"material\($0)"})
        XCTAssertNoThrow(try bounded.validate(durationFrames:21,assets:f.assets))
        bounded.instances[0].materialInterpretation!.alphaCutoutMaterialIDs!.append("material128")
        XCTAssertThrowsError(try bounded.validate(durationFrames:21,assets:f.assets))
    }
    func testAlphaCutoutNormalCASLocksInvalidationAndColdRestorePreserveSources()throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let original=scene(f);var project=project(original,f)
        project.revisions[0].review.sound=true;project.revisions[0].review.fullPreview=true
        try f.repository.transaction{$0.projects=[project]}
        var changed=original
        changed.modelScene3D!.instances[0].materialInterpretation = .init(opaqueDiffuseMaterialIDs:["bodyMaterial"],alphaCutoutMaterialIDs:["bodyMaterial"])
        let before=try Codec.data(f.repository.read())
        for ids in [[],["missing"],["bodyMaterial","bodyMaterial"]] {
            var invalid=changed;invalid.modelScene3D!.instances[0].materialInterpretation!.alphaCutoutMaterialIDs=ids
            let data=try input(project,edits:[.replaceScene(original.id,invalid)])
            XCTAssertThrowsError(try f.repository.performAgentMutation(command:"edit apply",data:data,principal:"owner",requestID:Codec.id()))
            XCTAssertEqual(try Codec.data(f.repository.read()),before)
        }
        let data=try input(project,edits:[.replaceScene(original.id,changed)])
        _=try AgentMutationExecutor.preview(command:"edit apply",data:data,database:f.repository.read(),principal:"owner",repository:f.repository)
        XCTAssertEqual(try Codec.data(f.repository.read()),before)
        let answer=try f.repository.performAgentMutation(command:"edit apply",data:data,principal:"owner",requestID:"alpha-cutout-save")
        XCTAssertEqual(answer,try f.repository.performAgentMutation(command:"edit apply",data:data,principal:"owner",requestID:"alpha-cutout-save"))
        let current=try XCTUnwrap(f.repository.read().projects.first?.current)
        XCTAssertEqual(current.scenes[0].modelScene3D,changed.modelScene3D)
        XCTAssertFalse(current.review.sound);XCTAssertFalse(current.review.fullPreview)
        XCTAssertEqual(Set((current.dependencies?.records ?? []).filter{$0.kind == .asset}.map{$0.asset!.id}),f.model.assetIDs)
        let locked=try Editor.apply([.lockModelInstance(original.id,"actor",true)],to:project,baseRevision:project.current.id,assets:f.assets,message:"锁定原实例")
        var lockedChange=locked.current.scenes[0];lockedChange.modelScene3D!.instances[0].materialInterpretation=changed.modelScene3D!.instances[0].materialInterpretation
        XCTAssertThrowsError(try Editor.apply([.replaceScene(original.id,lockedChange)],to:locked,baseRevision:locked.current.id,assets:f.assets,message:"锁定时不能新增裁切"))
        let restored=try Repository.restore(f.repository.backup(),to:f.root.appendingPathComponent("alpha-cutout-cold"))
        let cold=try XCTUnwrap(restored.read().projects.first?.current)
        XCTAssertEqual(try cold.contentDigest(),try current.contentDigest());XCTAssertEqual(cold.scenes[0].modelScene3D,changed.modelScene3D)
        for asset in f.assets {XCTAssertEqual(try Data(contentsOf:restored.assetURL(asset)),try Data(contentsOf:f.repository.assetURL(asset)))}
    }
    func testNodeVariantStepSamplingDigestAndLegacyWireAreExplicit()throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let old=try Codec.data(f.model.instances[0])
        XCTAssertNil((try JSONSerialization.jsonObject(with:old) as? [String:Any])?["nodeVariants"])
        XCTAssertEqual(old,try Codec.data(Codec.decoder().decode(ModelInstance3D.self,from:old)))
        var changed=f.model
        let group=ModelNodeVariantGroup(id:"expression",nodeIDs:["mesh","alternate"],defaultNodeID:"mesh",keyframes:[.init(frame:5,nodeID:"alternate"),.init(frame:10,nodeID:"mesh")])
        changed.instances[0].nodeVariants=[group]
        try changed.validate(durationFrames:21)
        for (frame,expected) in [(20,"mesh"),(5,"alternate"),(0,"mesh"),(9,"alternate"),(10,"mesh"),(4,"mesh"),(5,"alternate")] {XCTAssertEqual(group.selectedNodeID(at:frame),expected)}
        XCTAssertNotEqual(try changed.contentDigest(durationFrames:21),try f.model.contentDigest(durationFrames:21))
        XCTAssertEqual(try PluginModelBankManifest(scene:changed,durationFrames:21),try PluginModelBankManifest(scene:f.model,durationFrames:21),"只改变视觉状态，不重写原DAE或纹理闭包")
        XCTAssertEqual(changed,try Codec.decoder().decode(ModelScene3D.self,from:Codec.data(changed)))
        let host=AgentSchemas.definitions(),legacy=PluginRPCSchemas.definitions(inputSchemaVersion:10,pluginID:"video.game")
        XCTAssertNotNil(host["ModelInstance3D"]?.object?["properties"]?.object?["nodeVariants"])
        XCTAssertNil(legacy["ModelInstance3D"]?.object?["properties"]?.object?["nodeVariants"])
        XCTAssertEqual(host["ModelNodeVariantKeyframe"]?.object?["properties"]?.object?["frame"]?.object?["minimum"],.number(1))
    }
    func testNodeVariantMalformedGroupsFramesAndWireRejectWithoutGuessing()throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let valid=ModelNodeVariantGroup(id:"face",nodeIDs:["mesh","alternate"],defaultNodeID:"mesh")
        var invalid:[[ModelNodeVariantGroup]]=[[],[valid,valid]]
        for ids in [["mesh"],["mesh","mesh"],["mesh","missing"],["mesh"," alternate"]] {var item=valid;item.nodeIDs=ids;invalid.append([item])}
        var item=valid;item.defaultNodeID="missing";invalid.append([item])
        item=valid;item.id=" face";invalid.append([item])
        var other=valid;other.id="another";invalid.append([valid,other])
        let badKeys:[[ModelNodeVariantKeyframe]]=[[],[.init(frame:0,nodeID:"mesh")],[.init(frame:21,nodeID:"mesh")],[.init(frame:1,nodeID:"missing")],[.init(frame:2,nodeID:"mesh"),.init(frame:1,nodeID:"alternate")],[.init(frame:1,nodeID:"mesh"),.init(frame:1,nodeID:"alternate")]]
        for keys in badKeys {item=valid;item.keyframes=keys;invalid.append([item])}
        for groups in invalid {var model=f.model;model.instances[0].nodeVariants=groups;XCTAssertThrowsError(try model.validate(durationFrames:21))}
        var model=f.model;model.instances[0].nodeVariants=[valid]
        let bytes=try Codec.data(model.instances[0]),object=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        for field in ["unknown", "nodeVariants"] {
            var wrong=object;wrong[field]=NSNull()
            XCTAssertThrowsError(try Codec.decoder().decode(ModelInstance3D.self,from:JSONSerialization.data(withJSONObject:wrong)))
        }
        var group=try XCTUnwrap((object["nodeVariants"] as? [[String:Any]])?.first)
        for field in ["unknown","keyframes"] {var wrong=group;wrong[field]=NSNull();XCTAssertThrowsError(try Codec.decoder().decode(ModelNodeVariantGroup.self,from:JSONSerialization.data(withJSONObject:wrong)))}
        group["keyframes"]=[["frame":1,"nodeID":"mesh","emotion":"guessed"]]
        XCTAssertThrowsError(try Codec.decoder().decode(ModelNodeVariantGroup.self,from:JSONSerialization.data(withJSONObject:group)))
    }
    func testNodeVariantsNormalAgentSaveLocksReviewAndColdRestorePreserveOriginalBytes()throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        var original=scene(f);original.modelScene3D=nil
        var project=project(original,f);project.revisions[0].review.sound=true;project.revisions[0].review.fullPreview=true
        try f.repository.transaction{$0.projects=[project]}
        var replacement=scene(f);replacement.id=original.id
        replacement.modelScene3D!.instances[0].nodeVariants=[.init(id:"face",nodeIDs:["mesh","alternate"],defaultNodeID:"mesh",keyframes:[.init(frame:7,nodeID:"alternate")])]
        let data=try input(project,edits:[.replaceScene(original.id,replacement)]),before=try Codec.data(f.repository.read())
        _=try AgentMutationExecutor.preview(command:"edit apply",data:data,database:f.repository.read(),principal:"owner",repository:f.repository)
        XCTAssertEqual(before,try Codec.data(f.repository.read()))
        _=try f.repository.performAgentMutation(command:"edit apply",data:data,principal:"owner",requestID:"node-variants")
        let current=try XCTUnwrap(f.repository.read().projects.first?.current)
        XCTAssertEqual(current.scenes[0].modelScene3D,replacement.modelScene3D)
        XCTAssertFalse(current.review.sound);XCTAssertFalse(current.review.fullPreview)
        XCTAssertEqual(Set((current.dependencies?.records ?? []).filter{$0.kind == .asset}.map{$0.asset!.id}),f.model.assetIDs)
        var locked=replacement;locked.modelScene3D!.instances[0].locked=true
        var changed=locked;changed.modelScene3D!.instances[0].nodeVariants![0].defaultNodeID="alternate"
        XCTAssertThrowsError(try ModelScene3DRules.protectLocked(old:locked,new:changed))
        let restored=try Repository.restore(f.repository.backup(),to:f.root.appendingPathComponent("variant-cold"))
        let cold=try XCTUnwrap(restored.read().projects.first?.current)
        XCTAssertEqual(try cold.contentDigest(),try current.contentDigest());XCTAssertEqual(cold.scenes[0].modelScene3D,replacement.modelScene3D)
        for asset in f.assets {XCTAssertEqual(try Data(contentsOf:restored.assetURL(asset)),try Data(contentsOf:f.repository.assetURL(asset)))}
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
    func testExplicitDialogueObstaclesValidateAllSpeakersAndRejectAmbiguousLists() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        var valid=nativeModel(f)
        valid.instances.append(.init(id:"independent-clothing",name:"独立衣服",resource:f.model.instances[0].resource))
        valid.dialogueObstacleInstanceIDs=["actor","independent-clothing"]
        XCTAssertNoThrow(try valid.validate(durationFrames:21,assets:f.assets))
        XCTAssertEqual(valid,try Codec.decoder().decode(ModelScene3D.self,from:Codec.data(valid)))
        XCTAssertEqual(valid.assetIDs,f.model.assetIDs,"作者角色元数据不得增改任何模型字节依赖")
        let invalid:[[String]]=[[],["actor","actor"],["missing"],["independent-clothing"],["actor"," missing"],Array(repeating:"actor",count:129)]
        for ids in invalid {
            var wrong=valid;wrong.dialogueObstacleInstanceIDs=ids
            XCTAssertThrowsError(try wrong.validate(durationFrames:21),"缺少发言者、未知、重复或无界名单均须拒收")
        }
        var another=valid
        another.actions!.append(.init(id:"late-speaker",kind:.speak,instanceID:"independent-clothing",startFrame:18,endFrame:20,anchor:.init(y:1),text:"另一个时窗。"))
        another.dialogueObstacleInstanceIDs=["actor"]
        XCTAssertThrowsError(try another.validate(durationFrames:21),"名单覆盖全源窗发言者，不能只校当前帧")
        var wire=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(valid)) as? [String:Any])
        let malformed:[Any]=[NSNull(),true,"actor",1,["actor",1]]
        for value in malformed {
            wire["dialogueObstacleInstanceIDs"]=value
            XCTAssertThrowsError(try Codec.decoder().decode(ModelScene3D.self,from:JSONSerialization.data(withJSONObject:wire)))
        }
    }
    func testOmittedDialogueObstaclesPreserveExactLegacyV1AndV2WireAndDigest() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        struct Legacy:Encodable {
            let version:Int;let instances:[ModelInstance3D];let camera:ModelCamera3D;let lights:[ModelLight3D]
            let transformTracks:[ModelTransformTrack];let jointTracks:[ModelJointTrack];let actions:[ModelStoryAction3D]?
        }
        for model in [f.model,nativeModel(f)] {
            let old=Legacy(version:model.version,instances:model.instances,camera:model.camera,lights:model.lights,transformTracks:model.transformTracks,jointTracks:model.jointTracks,actions:model.actions)
            XCTAssertNil(model.dialogueObstacleInstanceIDs)
            XCTAssertEqual(try Codec.data(model),try Codec.data(old))
            XCTAssertEqual(model,try Codec.decoder().decode(ModelScene3D.self,from:Codec.data(old)))
            var explicit=model;explicit.dialogueObstacleInstanceIDs=["actor"]
            XCTAssertNotEqual(try model.contentDigest(durationFrames:21),try explicit.contentDigest(durationFrames:21))
        }
    }
    private func nativeModel(_ f:Fixture)->ModelScene3D {
        var model=f.model;model.version=2
        model.actions=[
            .init(id:"walk",kind:.move,instanceID:"actor",startFrame:0,endFrame:21),
            .init(id:"original-pose",kind:.pose,instanceID:"actor",startFrame:0,endFrame:21,jointNames:["hip"]),
            .init(id:"speech",kind:.speak,instanceID:"actor",startFrame:5,endFrame:10,anchor:.init(x:0,y:1,z:0),text:"门开了，再往外走。"),
            .init(id:"hide",kind:.hide,instanceID:"actor",startFrame:15,endFrame:16),
            .init(id:"show",kind:.show,instanceID:"actor",startFrame:18,endFrame:19,requires:["hide"])
        ]
        return model
    }
    func testV2NativeOperationsUseOriginalTracksAndRandomAccessVisibilityAndSpeech() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let model=nativeModel(f),actions=try XCTUnwrap(model.actions)
        XCTAssertNoThrow(try model.validate(durationFrames:21,assets:f.assets))
        XCTAssertEqual(try Codec.decoder().decode(ModelScene3D.self,from:Codec.data(model)),model)
        let middle=try model.sampledTransform(instanceID:"actor",sourceFrame:10,durationFrames:21)
        XCTAssertEqual(middle.translation.x,1,accuracy:0.0000001)
        let pose=try model.sampledTransform(instanceID:"actor",jointName:"hip",sourceFrame:10,durationFrames:21)
        XCTAssertEqual(abs(pose.rotation.z),sqrt(0.5),accuracy:0.0000001)
        var observations:[Int:ModelStoryActionState3D]=[:]
        for frame in [20,16,5,0,9,18,10,15,5,20] {
            let current=ModelStoryActionRules3D.presentation(instanceID:"actor",actions:actions,frame:frame)
            if let previous=observations[frame] {XCTAssertEqual(current,previous,"乱序采样不得继承前一帧的显隐或发言")}
            observations[frame]=current
            XCTAssertEqual(current.opacity,(15..<18).contains(frame) ? 0:1)
            XCTAssertEqual(current.speech?.text,(5..<10).contains(frame) ? "门开了，再往外走。":nil)
        }
        let initiallyHidden=[ModelStoryAction3D(id:"first-show",kind:.show,instanceID:"actor",startFrame:4,endFrame:5)]
        XCTAssertEqual(ModelStoryActionRules3D.presentation(instanceID:"actor",actions:initiallyHidden,frame:3).opacity,0)
        XCTAssertEqual(ModelStoryActionRules3D.presentation(instanceID:"actor",actions:initiallyHidden,frame:4).opacity,1)
        var hiddenSpeech=actions;hiddenSpeech[2].startFrame=15;hiddenSpeech[2].endFrame=17
        XCTAssertNil(ModelStoryActionRules3D.presentation(instanceID:"actor",actions:hiddenSpeech,frame:16).speech)
        var invalid=model;invalid.actions=hiddenSpeech
        XCTAssertThrowsError(try invalid.validate(durationFrames:21),"不能保存一个在发言过程中不可见的说话者")
    }
    func testV2NativeActionsRejectFakeMovementPoseHiddenFieldsAndFutureDependencies() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let valid=nativeModel(f)
        for index in 0..<17 {
            var invalid=valid
            switch index {
            case 0:invalid.transformTracks=[]
            case 1:invalid.transformTracks[0].keyframes[1].transform.translation = .init()
            case 2:invalid.actions![0].startFrame=20
            case 3:invalid.actions![0].instanceID="not-an-instance"
            case 4:invalid.actions![1].jointNames=["invented"]
            case 5:invalid.jointTracks=[]
            case 6:invalid.jointTracks[0].keyframes[1].transform = .init(rotation:.init(w:-1))
            case 7:invalid.actions![0].text="隐藏文本"
            case 8:invalid.actions![2].anchor!.x=Double.infinity
            case 9:invalid.actions![2].text=String(repeating:"字",count:49)
            case 10:invalid.actions![2].requires=["walk"]
            case 11:invalid.actions![0].requires=["walk"]
            case 12:var duplicate=invalid.actions![0];duplicate.id="walk-duplicate";invalid.actions!.append(duplicate)
            case 13:var duplicate=invalid.actions![1];duplicate.id="pose-duplicate";invalid.actions!.append(duplicate)
            case 14:invalid.actions!.append(.init(id:"show-again",kind:.show,instanceID:"actor",startFrame:19,endFrame:20))
            case 15:invalid.actions![0].startFrame=5
            default:invalid.actions![1].startFrame=5
            }
            XCTAssertThrowsError(try invalid.validate(durationFrames:21),"拒绝未经实际操作支持的声明 \(index)")
        }
        // A loop may return to its start, but its intermediate source frames
        // must contain real movement. Endpoint-only checking would miss this.
        var returning=valid
        returning.transformTracks[0].keyframes.insert(.init(frame:10,transform:.init(translation:.init(x:2))),at:1)
        returning.transformTracks[0].keyframes[2].transform.translation = .init()
        XCTAssertNoThrow(try returning.validate(durationFrames:21))
    }
    func testV1WireAndStrictV2DecodingDoNotSilentlyAcceptNewActions() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        struct Legacy:Encodable {
            let version:Int;let instances:[ModelInstance3D];let camera:ModelCamera3D;let lights:[ModelLight3D]
            let transformTracks:[ModelTransformTrack];let jointTracks:[ModelJointTrack]
        }
        let old=f.model
        XCTAssertEqual(try Codec.data(old),try Codec.data(Legacy(version:old.version,instances:old.instances,camera:old.camera,lights:old.lights,transformTracks:old.transformTracks,jointTracks:old.jointTracks)))
        let base=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(old)) as? [String:Any])
        let invalidValues:[Any]=[[Any](),NSNull()]
        for value in invalidValues {
            var invalid=base;invalid["actions"]=value
            XCTAssertThrowsError(try Codec.decoder().decode(ModelScene3D.self,from:JSONSerialization.data(withJSONObject:invalid)))
        }
        var missing=base;missing["version"]=2
        XCTAssertThrowsError(try Codec.decoder().decode(ModelScene3D.self,from:JSONSerialization.data(withJSONObject:missing)))
        let native=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(nativeModel(f))) as? [String:Any])
        for index in 0..<7 {
            var object=native,actions=try XCTUnwrap(object["actions"] as? [[String:Any]])
            switch index {
            case 0:object["invented"]=true
            case 1:actions[0]["from"]=["x":0,"y":0]
            case 2:actions[0]["anchor"]=NSNull()
            case 3:actions[1]["jointNames"]=NSNull()
            case 4:actions[2]["anchor"]=["x":0,"y":1,"z":0,"screenX":0.5]
            case 5:actions[2]["text"]=NSNull()
            default:actions[0]["requires"]=nil
            }
            object["actions"]=actions
            XCTAssertThrowsError(try Codec.decoder().decode(ModelScene3D.self,from:JSONSerialization.data(withJSONObject:object)),"未知字段、旧二维别名及null不应消失 \(index)")
        }
    }
    func testV2NormalDryRunSaveColdRestoreAndLockedNativeOperations() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        var original=scene(f);original.modelScene3D=nil
        let p=project(original,f);try f.repository.transaction{$0.projects=[p]}
        var native=scene(f);native.modelScene3D=nativeModel(f);native.modelScene3D!.dialogueObstacleInstanceIDs=["actor"]
        let data=try input(p,edits:[.replaceScene(original.id,native)]),before=try Codec.data(f.repository.read())
        _=try AgentMutationExecutor.preview(command:"edit apply",data:data,database:f.repository.read(),principal:"owner",repository:f.repository)
        XCTAssertEqual(try Codec.data(f.repository.read()),before)
        _=try f.repository.performAgentMutation(command:"edit apply",data:data,principal:"owner",requestID:"native-v2-edit")
        let saved=try XCTUnwrap(f.repository.read().projects.first?.current)
        XCTAssertEqual(saved.scenes[0].modelScene3D,native.modelScene3D)
        let restored=try Repository.restore(f.repository.backup(),to:f.root.appendingPathComponent("native-v2-cold"))
        let savedDigest=try saved.contentDigest()
        XCTAssertEqual(try restored.read().projects.first?.current.contentDigest(),savedDigest)
        XCTAssertEqual(try restored.read().projects.first?.current.scenes[0].modelScene3D,native.modelScene3D)
        for source in f.assets {XCTAssertEqual(try Data(contentsOf:restored.assetURL(source)),try Data(contentsOf:f.repository.assetURL(source)))}
        var locked=native;locked.modelScene3D!.instances[0].locked=true
        var changed=locked;changed.modelScene3D!.actions![2].anchor!.y=2
        XCTAssertThrowsError(try ModelScene3DRules.protectLocked(old:locked,new:changed))
        for index in 0..<4 {
            var retimed=native
            switch index {case 0:retimed.sourceStartFrame=1;case 1:retimed.sourceEndFrame=20;case 2:retimed.speed=1.2;default:retimed.pauseFrames=1}
            XCTAssertThrowsError(try retimed.validate(assets:f.assets),"未实现三维源轴变换时明确拒绝，不能把展示轴冒原轨 \(index)")
        }
    }
}
