import XCTest
import VideoCore

final class LayerTexturedPathTests: XCTestCase {
    private func path()->LayerTexturedPath {
        .init(paths:[.init(points:[.init(x:0.2,y:0.2),.init(x:0.7,y:0.2),.init(x:0.7,y:0.7)],width:0.06),
                     .init(points:[.init(x:0.7,y:0.45),.init(x:0.9,y:0.45)],width:0.04)])
    }
    private func asset()->Asset {Asset(workspaceID:"w",name:"原石路纹理",hash:"stone",ext:"png",bytes:1250659,mediaType:"image/png")}
    private func scene(_ asset:Asset)->Scene {
        var scene=Scene(title:"有分支的村路",body:"工队沿路修建",durationFrames:61)
        var layer=SceneLayer(kind:.image,assetID:asset.id,endFrame:61)
        layer.id="road";layer.texturedPath=path();layer.sourceRect=MediaFraming(x:0,y:55.0/887,width:1,height:776.0/887)
        scene.layers=[layer]
        scene.storyActions=[.init(kind:.build,subjectID:"road",startFrame:0,endFrame:61)]
        return scene
    }
    func testActualImagePathRoundTripsWithBoundedIndependentBranches() throws {
        let a=asset(),s=scene(a),value=path()
        try LayerRules.validate(scene:s,assets:[a]);try value.validate()
        XCTAssertEqual(try Codec.decoder().decode(LayerTexturedPath.self,from:Codec.data(value)),value)
        XCTAssertEqual(try Codec.decoder().decode(Scene.self,from:Codec.data(s)),s)
        var bounded=value
        bounded.paths=(0..<8).map{_ in LayerTextureStroke(points:(0..<32).map{.init(x:Double($0)/31,y:0.5)},width:0.01)}
        XCTAssertNoThrow(try bounded.validate())
        bounded.paths[0].width=0.2;XCTAssertNoThrow(try bounded.validate())
        bounded.paths.append(value.paths[0]);XCTAssertThrowsError(try bounded.validate())
    }
    func testInvalidVersionCountsWidthAndStageCoordinatesCannotBeAuthored() throws {
        var bad=path();bad.version=2;XCTAssertThrowsError(try bad.validate())
        bad=path();bad.paths=[];XCTAssertThrowsError(try bad.validate())
        for count in [0,1,33] {
            bad=path();bad.paths[0].points=(0..<count).map{.init(x:Double($0)/max(1,Double(count-1)),y:0.5)}
            XCTAssertThrowsError(try bad.validate())
        }
        for width in [0,0.009,0.201,Double.nan,Double.infinity] {
            bad=path();bad.paths[0].width=width;XCTAssertThrowsError(try bad.validate())
        }
        for point in [StoryPoint(x:-0.001,y:0.5),.init(x:0.5,y:1.001),.init(x:Double.nan,y:0.5),.init(x:0.5,y:Double.infinity)] {
            bad=path();bad.paths[0].points[0]=point;XCTAssertThrowsError(try bad.validate())
        }
        bad=path();bad.paths[0].points[1]=bad.paths[0].points[0]
        XCTAssertThrowsError(try bad.validate())
    }
    func testStrictWireShapeRejectsUnknownNestedFieldsAndMissingVersion() throws {
        let bytes=try Codec.data(path()),raw=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        func reject(_ value:[String:Any]) throws {
            XCTAssertThrowsError(try Codec.decoder().decode(LayerTexturedPath.self,from:JSONSerialization.data(withJSONObject:value)))
        }
        var bad=raw;bad["hidden"]=true;try reject(bad)
        bad=raw;bad.removeValue(forKey:"version");try reject(bad)
        bad=raw;var strokes=try XCTUnwrap(bad["paths"] as? [[String:Any]])
        strokes[0]["assetID"]="other-image";bad["paths"]=strokes;try reject(bad)
        bad=raw;strokes=try XCTUnwrap(bad["paths"] as? [[String:Any]])
        var points=try XCTUnwrap(strokes[0]["points"] as? [[String:Any]])
        points[0]["z"]=0;strokes[0]["points"]=points;bad["paths"]=strokes;try reject(bad)
    }
    func testLayerRulesRejectWrongMediaSequenceAndIgnoredPositionControls() throws {
        let a=asset(),original=scene(a)
        XCTAssertThrowsError(try LayerRules.validate(scene:original,assets:[]))
        var bad=original;bad.layers?[0].kind = .rectangle
        XCTAssertThrowsError(try LayerRules.validate(scene:bad,assets:[a]))
        bad=original;bad.layers?[0].imageSequence=LayerImageSequence(frames:[
            .init(startFrame:0,endFrame:30,sourceRect:.init(x:0,y:0,width:0.5,height:1)),
            .init(startFrame:30,endFrame:61,sourceRect:.init(x:0.5,y:0,width:0.5,height:1))])
        XCTAssertThrowsError(try LayerRules.validate(scene:bad,assets:[a]))
        bad=original;bad.layers?[0].keyframes=[.init(frame:0,x:0.5,y:0.5,scale:1)]
        XCTAssertThrowsError(try LayerRules.validate(scene:bad,assets:[a]))
        for kind in [StoryActionKind.move,.transfer] {
            bad=original;bad.storyActions=[.init(kind:kind,subjectID:"road",startFrame:0,endFrame:30,from:.init(x:0.2,y:0.2),to:.init(x:0.7,y:0.2))]
            XCTAssertThrowsError(try LayerRules.validate(scene:bad,assets:[a]))
        }
        bad=original;bad.layers?[0].sourceRect=MediaFraming(x:0.9,width:0.2)
        XCTAssertThrowsError(try LayerRules.validate(scene:bad,assets:[a]))
        var allowed=original;allowed.storyActions=[.init(kind:.show,subjectID:"road",startFrame:0,endFrame:10),.init(kind:.hide,subjectID:"road",startFrame:50,endFrame:61)]
        allowed.layers?[0].entrance=LayerEntrance(kind:.fade,startFrame:0,endFrame:15)
        XCTAssertNoThrow(try LayerRules.validate(scene:allowed,assets:[a]))
    }
    func testLegacyNilKeepsExactEncodingAndPathChangesRevisionIdentity() throws {
        let bytes=Data(#"{"color":"FFFFFF","endFrame":60,"height":0.2,"id":"legacy","keyframes":[],"kind":"文字","locked":false,"opacity":1,"startFrame":0,"text":"旧图层","width":0.5,"x":0.5,"y":0.5}"#.utf8)
        let layer=try Codec.decoder().decode(SceneLayer.self,from:bytes)
        XCTAssertNil(layer.texturedPath);XCTAssertEqual(try Codec.data(layer),bytes)
        let a=asset(),original=scene(a)
        var changed=original;changed.layers?[0].texturedPath?.paths[0].points[1].x=0.6
        XCTAssertNotEqual(try Codec.digest(original),try Codec.digest(changed))
        changed=original;changed.layers?[0].texturedPath?.paths[0].width=0.08
        XCTAssertNotEqual(try Codec.digest(original),try Codec.digest(changed))
        changed=original;changed.layers?[0].texturedPath=nil
        XCTAssertNotEqual(try Codec.digest(original),try Codec.digest(changed))
    }
}
