import XCTest
import VideoCore

final class LayerImageFlipTests: XCTestCase {
    private func asset()->Asset {Asset(workspaceID:"w",name:"图层合同夹具",hash:"atlas",ext:"png",bytes:16,mediaType:"image/png")}
    private func scene(_ asset:Asset)->Scene {
        var scene=Scene(title:"图片朝向",body:"仅镜像同一素材",durationFrames:60)
        scene.layers=[SceneLayer(kind:.image,assetID:asset.id,endFrame:60)]
        return scene
    }
    private func project(_ scene:Scene)->Project {
        Project(workspaceID:"w",name:"图片镜像合同",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"图片朝向"),aspect:.landscape,scenes:[scene]))
    }
    func testLegacyNilKeepsExactBytesAndOptionalBooleanSchema() throws {
        let bytes=Data(#"{"color":"FFFFFF","endFrame":60,"height":0.2,"id":"legacy","keyframes":[],"kind":"文字","locked":false,"opacity":1,"startFrame":0,"text":"旧图层","width":0.5,"x":0.5,"y":0.5}"#.utf8)
        let layer=try Codec.decoder().decode(SceneLayer.self,from:bytes)
        XCTAssertNil(layer.imageFlipHorizontal);XCTAssertFalse(layer.imageFlipHorizontal ?? false)
        XCTAssertEqual(try Codec.data(layer),bytes)
        let schema=try XCTUnwrap(AgentSchemas.definitions()["SceneLayer"]?.object)
        XCTAssertEqual(schema["properties"]?.object?["imageFlipHorizontal"],.object(["anyOf":.array([
            .object(["type":.string("boolean")]),.object(["type":.string("null")])])]))
        let requiredValue=try XCTUnwrap(schema["required"])
        guard case .array(let required)=requiredValue else {return XCTFail("图层schema缺少required")}
        XCTAssertFalse(required.contains(.string("imageFlipHorizontal")))
    }
    func testExplicitTrueAndFalseRoundTripButNonBooleanWireValuesAreRejected() throws {
        var layer=SceneLayer(kind:.image,assetID:"atlas",endFrame:60)
        for value in [true,false] {
            layer.imageFlipHorizontal=value
            XCTAssertEqual(try Codec.decoder().decode(SceneLayer.self,from:Codec.data(layer)),layer)
            let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(layer)) as? [String:Any])
            XCTAssertEqual(object["imageFlipHorizontal"] as? Bool,value)
        }
        let original=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(layer)) as? [String:Any])
        for value in ["true" as Any,1 as Any,[true] as Any] {
            var changed=original;changed["imageFlipHorizontal"]=value
            XCTAssertThrowsError(try Codec.decoder().decode(SceneLayer.self,from:JSONSerialization.data(withJSONObject:changed)))
        }
    }
    func testFlipAcceptsOrdinaryCropsAndSequencesAndRejectsOtherKindsAndTextureRoutes() throws {
        let asset=asset();var original=scene(asset);original.layers?[0].imageFlipHorizontal=true
        XCTAssertNoThrow(try LayerRules.validate(scene:original,assets:[asset]))
        var cropped=original;cropped.layers?[0].sourceRect=MediaFraming(x:0,y:0,width:0.5,height:1)
        XCTAssertNoThrow(try LayerRules.validate(scene:cropped,assets:[asset]))
        var sequence=original;sequence.layers?[0].imageSequence=LayerImageSequence(frames:[
            .init(startFrame:0,endFrame:30,sourceRect:.init(x:0,y:0,width:0.5,height:1)),
            .init(startFrame:30,endFrame:60,sourceRect:.init(x:0.5,y:0,width:0.5,height:1))])
        XCTAssertNoThrow(try LayerRules.validate(scene:sequence,assets:[asset]))
        for value in [true,false] {
            for kind in SceneLayer.Kind.allCases where kind != .image {
                var bad=original;bad.layers?[0].kind=kind;bad.layers?[0].imageFlipHorizontal=value
                XCTAssertThrowsError(try bad.layers?[0].validateImagePresentation())
            }
            var textured=original;textured.layers?[0].imageFlipHorizontal=value
            textured.layers?[0].texturedPath=LayerTexturedPath(paths:[.init(points:[.init(x:0.2,y:0.3),.init(x:0.8,y:0.3)],width:0.06)])
            XCTAssertThrowsError(try LayerRules.validate(scene:textured,assets:[asset]))
            textured.layers?[0].imageFlipHorizontal=nil
            XCTAssertNoThrow(try LayerRules.validate(scene:textured,assets:[asset]))
        }
    }
    func testFlipChangesRevisionIdentityAndRevokesExistingCaptionConfirmation() throws {
        let asset=asset();var original=scene(asset)
        original.captions=[Caption(text:"同一人物转向",startFrame:0,endFrame:60,confirmed:true)]
        let project=project(original);var changed=original;changed.layers?[0].imageFlipHorizontal=true
        XCTAssertNotEqual(try Codec.digest(original),try Codec.digest(changed))
        let edited=try Editor.apply([.replaceScene(original.id,changed)],to:project,baseRevision:project.current.id,assets:[asset],message:"转向对方")
        XCTAssertEqual(edited.current.scenes[0].layers?[0].imageFlipHorizontal,true)
        XCTAssertFalse(try XCTUnwrap(edited.current.scenes[0].captions.first).confirmed)
        XCTAssertTrue(edited.current.invalidated.contains("图片取景、序列、源窗口与声音字幕重新复核"))
        var locked=original;locked.layers?[0].locked=true
        let protected=self.project(locked);var lockedChange=locked;lockedChange.layers?[0].imageFlipHorizontal=true
        XCTAssertThrowsError(try Editor.apply([.replaceScene(locked.id,lockedChange)],to:protected,baseRevision:protected.current.id,assets:[asset],message:"锁定元素不能转向"))
    }
    func testFlipSurvivesSequenceSplitAndNormalRevisionRestore() throws {
        let asset=asset();var original=scene(asset);original.layers?[0].imageFlipHorizontal=true
        original.layers?[0].imageSequence=LayerImageSequence(frames:[
            .init(startFrame:0,endFrame:30,sourceRect:.init(x:0,y:0,width:0.5,height:1)),
            .init(startFrame:30,endFrame:60,sourceRect:.init(x:0.5,y:0,width:0.5,height:1))])
        let project=project(original)
        let split=try Editor.apply([.splitScene(original.id,10)],to:project,baseRevision:project.current.id,assets:[asset],message:"保留镜像源窗")
        XCTAssertEqual(split.current.scenes.compactMap{$0.layers?.first?.imageFlipHorizontal},[true,true])
        XCTAssertEqual(split.current.scenes.last?.layers?.first?.imageSequence?.sourceOffsetFrames,10)
        let restored=try Editor.apply([.restore(project.current.id)],to:split,baseRevision:split.current.id,assets:[asset],message:"恢复镜像原版")
        XCTAssertEqual(restored.current.scenes,project.current.scenes)
        XCTAssertEqual(try Codec.data(Codec.decoder().decode(Project.self,from:Codec.data(restored))),try Codec.data(restored))
    }
}
