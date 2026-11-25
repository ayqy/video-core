import XCTest
@testable import VideoCore

final class ModelSceneEditPatchTests: XCTestCase {
    private struct Fixture { let root: URL; let repository: Repository; let workspace: Workspace; let assets: [Asset]; let project: Project }
    private func fixture() throws -> Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("static-patch-"+UUID().uuidString)
        let repository=try Repository(root:root),workspace=Workspace(name:"静态批量编辑",owner:"owner")
        let bytes=Data(##"<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1"><asset><unit meter="1"/><up_axis>Y_UP</up_axis></asset><library_images><image id="leaf"><init_from>leaf.png</init_from></image></library_images><library_effects><effect id="effect"><profile_COMMON><technique sid="common"><lambert><diffuse><color>1 1 1 1</color></diffuse></lambert></technique></profile_COMMON></effect></library_effects><library_materials><material id="leafMaterial"><instance_effect url="#effect"/></material></library_materials><library_geometries><geometry id="mesh"><mesh><source id="positions"><float_array id="array" count="9">0 0 0 1 0 0 0 1 0</float_array></source></mesh></geometry></library_geometries><library_visual_scenes><visual_scene id="scene"><node id="root"><instance_geometry url="#mesh"/></node></visual_scene></library_visual_scenes><scene><instance_visual_scene url="#scene"/></scene></COLLADA>"##.utf8)
        let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=")!
        let dae=try repository.ingest(bytes,name:"plant.dae",workspaceID:workspace.id,mediaType:"model3d"),image=try repository.ingest(png,name:"leaf.png",workspaceID:workspace.id,mediaType:"image")
        let resource=ModelDAEResource(model:.init(asset:dae),inspection:try DAEInspector.inspect(bytes),textures:["leaf.png":.init(asset:image)])
        let model=ModelScene3D(instances:[.init(id:"actor",name:"演员",resource:resource),.init(id:"plant",name:"静态花卉",resource:resource)],camera:.init(position:.init(x:0,y:2,z:5),target:.init()),lights:[.init(id:"sun",kind:.directional)],transformTracks:[.init(instanceID:"actor",keyframes:[.init(frame:0,transform:.init()),.init(frame:20,transform:.init(translation:.init(x:2)))])])
        var scenes:[Scene]=[]
        for index in 0..<15 {
            var scene=Scene(kind:.simulation,title:"场景\(index)",body:"保持非三维字段",durationFrames:21)
            scene.modelScene3D=model;scene.captions=[Caption(text:"原字幕",startFrame:0,endFrame:20,confirmed:true)]
            scenes.append(scene)
        }
        let project=Project(workspaceID:workspace.id,name:"同岛多窗",revision:Revision(contentContext:.init(workspaceID:workspace.id,name:"静态装配"),aspect:.landscape,scenes:scenes))
        try repository.transaction {$0.workspaces=[workspace];$0.assets=[dae,image];$0.projects=[project]}
        return .init(root:root,repository:repository,workspace:workspace,assets:[dae,image],project:project)
    }
    private func patch(_ f: Fixture) -> ModelScene3DStaticPatch {
        var plant=f.project.current.scenes[0].modelScene3D!.instances[1]
        plant.materialInterpretation = .init(vertexColors:.ignored,normalEncoding:.redGreenPositiveZ)
        return .init(sceneIDs:f.project.current.scenes.map(\.id),replaceInstances:[plant])
    }
    private func input(_ f: Fixture, _ edits: [Edit]) throws -> Data {
        try Codec.data(AgentValue.object(["workspace_id":.string(f.workspace.id),"project_id":.string(f.project.id),"base_revision":.string(f.project.current.id),"edits":try Codec.decoder().decode(AgentValue.self,from:Codec.data(edits))]))
    }
    func testSharedPatchSavesOneRevisionPreservesActorsTimingAndOtherFields() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let request=try input(f,[.patchModelScenes3D(patch(f))]),before=try Codec.data(f.repository.read())
        XCTAssertNoThrow(try AgentContract.validate(command:"edit apply",data:request))
        _=try AgentMutationExecutor.preview(command:"edit apply",data:request,database:f.repository.read(),principal:"owner",repository:f.repository)
        XCTAssertEqual(try Codec.data(f.repository.read()),before,"预演必须只读")
        _=try f.repository.performAgentMutation(command:"edit apply",data:request,principal:"owner",requestID:"static-patch-one-batch")
        let saved=try XCTUnwrap(f.repository.read().projects.first)
        XCTAssertEqual(saved.revisions.count,2);XCTAssertEqual(try Codec.data(saved.revisions[0]),try Codec.data(f.project.revisions[0]))
        XCTAssertEqual(saved.current.frames,f.project.current.frames)
        for (old,new) in zip(f.project.current.scenes,saved.current.scenes) {
            var expected=old;expected.modelScene3D!.instances[1]=patch(f).replaceInstances[0]
            expected.captions[0].confirmed=false
            XCTAssertEqual(new,expected);XCTAssertEqual(new.modelScene3D!.transformTracks,old.modelScene3D!.transformTracks)
        }
        XCTAssertTrue(saved.current.invalidated.contains("三维模型、材质、相机灯光与动作时序及声音字幕重新复核"))
        let full=try input(f,try patch(f).replacements(in:f.project.current))
        XCTAssertLessThan(request.count*8,full.count,"多窗共享编码应明显小于完整场景重复提交")
        XCTAssertEqual(try Codec.decoder().decode(ModelScene3DStaticPatch.self,from:Codec.data(patch(f))),patch(f))
    }
    func testSequentialPatchesUsePriorOperationsWithoutExtraHistory() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        var appended=f.project.current.scenes[0].modelScene3D!.instances[1];appended.id="new-plant"
        var moved=appended;moved.transform.translation.x=4
        var camera=f.project.current.scenes[0].modelScene3D!.camera;camera.position.z=6
        let saved=try Editor.apply([.patchModelScenes3D(.init(sceneIDs:patch(f).sceneIDs,appendInstances:[appended])),.patchModelScenes3D(.init(sceneIDs:patch(f).sceneIDs,replaceInstances:[moved],camera:camera))],to:f.project,baseRevision:f.project.current.id,assets:f.assets,message:"顺序批量增补再摆位")
        XCTAssertEqual(saved.revisions.count,2)
        for scene in saved.current.scenes {
            XCTAssertEqual(scene.modelScene3D!.instances.map(\.id),["actor","plant","new-plant"])
            XCTAssertEqual(scene.modelScene3D!.instances.last,moved);XCTAssertEqual(scene.modelScene3D!.camera,camera)
        }
    }
    func testRejectsLocksDynamicActorsMissingDuplicateInstancesAndInvalidAssetsAtomically() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let normal=patch(f),before=try Codec.data(f.repository.read())
        var actor=normal;actor.replaceInstances=[f.project.current.scenes[0].modelScene3D!.instances[0]]
        var missing=normal;missing.sceneIDs=["missing"]
        var duplicate=normal;duplicate.sceneIDs.append(normal.sceneIDs[0])
        var absent=normal;absent.replaceInstances[0].id="absent"
        var implicitUnlock=normal;implicitUnlock.replaceInstances[0].locked=true
        var collision=normal;collision.appendInstances=collision.replaceInstances;collision.replaceInstances=[]
        var badSource=normal;badSource.replaceInstances[0].resource.model.sha256=String(repeating:"a",count:64)
        var missingAsset=normal;missingAsset.replaceInstances[0].resource.model.assetID="missing-asset"
        var badBank=normal;badBank.replaceInstances[0].resource.textures["hidden.png"]=badBank.replaceInstances[0].resource.textures["leaf.png"]
        for invalid in [actor,missing,duplicate,absent,implicitUnlock,collision,badSource,missingAsset,badBank,.init(sceneIDs:normal.sceneIDs)] {
            XCTAssertThrowsError(try f.repository.performAgentMutation(command:"edit apply",data:input(f,[.patchModelScenes3D(invalid)]),principal:"owner",requestID:Codec.id()))
            XCTAssertEqual(try Codec.data(f.repository.read()),before)
        }
        var locked=f.project;locked.revisions[0].scenes[0].modelScene3D!.instances[1].locked=true
        var lockedPatch=normal;lockedPatch.replaceInstances[0].locked=true
        XCTAssertThrowsError(try Editor.apply([.patchModelScenes3D(lockedPatch)],to:locked,baseRevision:locked.current.id,assets:f.assets,message:"不能改锁定模型"))
        locked=f.project;locked.revisions[0].scenes[0].locked=true
        XCTAssertThrowsError(try Editor.apply([.patchModelScenes3D(normal)],to:locked,baseRevision:locked.current.id,assets:f.assets,message:"不能改锁定场景"))
        XCTAssertThrowsError(try AgentMutationExecutor.preview(command:"edit apply",data:input(f,[.patchModelScenes3D(normal)]),database:f.repository.read(),principal:"outsider",repository:f.repository))
    }
    func testStrictUnknownNestedKeysNullsAndOperationWrapperAreRejectedByNormalContract() throws {
        let f=try fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let original=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(patch(f))) as? [String:Any])
        var unknown=original;unknown["transformTracks"]=[]
        var nullCamera=original;nullCamera["camera"]=NSNull()
        var nested=original,replacements=try XCTUnwrap(original["replaceInstances"] as? [[String:Any]])
        var resource=try XCTUnwrap(replacements[0]["resource"] as? [String:Any]);resource["externalURL"]="https://example.com"
        replacements[0]["resource"]=resource;nested["replaceInstances"]=replacements
        var transformUnknown=original,transforms=try XCTUnwrap(original["replaceInstances"] as? [[String:Any]])
        var transform=try XCTUnwrap(transforms[0]["transform"] as? [String:Any]);transform["teleport"]=true
        transforms[0]["transform"]=transform;transformUnknown["replaceInstances"]=transforms
        for value in [unknown,nullCamera,nested,transformUnknown] {
            XCTAssertThrowsError(try Codec.decoder().decode(ModelScene3DStaticPatch.self,from:JSONSerialization.data(withJSONObject:value)))
        }
        var request=try XCTUnwrap(JSONSerialization.jsonObject(with:input(f,[.patchModelScenes3D(patch(f))])) as? [String:Any])
        for edit: [String:Any] in [["patchModelScenes3D":["_0":original,"_1":true]],["patchModelScenes3D":["_0":original],"music":[:]]] {
            request["edits"]=[edit]
            XCTAssertThrowsError(try AgentContract.validate(command:"edit apply",data:JSONSerialization.data(withJSONObject:request)))
        }
        let definitions=AgentSchemas.definitions()
        XCTAssertNotNil(definitions["ModelScene3DStaticPatch"])
        XCTAssertEqual(definitions["ModelScene3DStaticPatch"]?.object?["additionalProperties"],.boolean(false))
        XCTAssertEqual(definitions["ModelScene3DStaticPatch"]?.object?["properties"]?.object?["camera"]?.object?["$ref"],.string("#/$defs/ModelCamera3D"))
    }
}
