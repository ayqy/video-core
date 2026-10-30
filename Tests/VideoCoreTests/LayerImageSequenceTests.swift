import XCTest
import VideoCore

final class LayerImageSequenceTests: XCTestCase {
    private let left=MediaFraming(x:0,y:0,width:0.5,height:1)
    private let right=MediaFraming(x:0.5,y:0,width:0.5,height:1)
    private func sequence()->LayerImageSequence {
        LayerImageSequence(frames:[.init(startFrame:0,endFrame:20,sourceRect:left),.init(startFrame:20,endFrame:40,sourceRect:right),.init(startFrame:40,endFrame:60,sourceRect:left)])
    }
    private func asset()->Asset {Asset(workspaceID:"w",name:"真实图集",hash:"atlas",ext:"png",bytes:16,mediaType:"image/png")}
    private func scene(asset:Asset,speed:Double=1,pause:Int=0)->Scene {
        var s=Scene(title:"人物连续行动",body:"同一原图切换姿态",durationFrames:60)
        s.speed=speed;s.pauseFrames=pause
        var l=SceneLayer(kind:.image,assetID:asset.id,endFrame:60);l.imageSequence=sequence();s.layers=[l]
        return s
    }
    private func project(_ scene:Scene)->Project {
        Project(workspaceID:"w",name:"图集源时序",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"知识"),aspect:.landscape,scenes:[scene]))
    }
    private func samples(_ scene:Scene)throws->[MediaFraming?] {
        let layer=try XCTUnwrap(scene.layers?.first),sequence=try XCTUnwrap(layer.imageSequence)
        return try (0..<scene.timelineFrames).map { local in
            let source=LayerRules.renderSourceFrame(scene:scene,sourceFrame:scene.renderSourceFrame(atTimelineFrame:local))
            return layer.startFrame<=source && source<layer.endFrame ? try sequence.sourceRect(at:source):nil
        }
    }
    func testAtlasUsesContinuousIntervalsWithRealDistinctRegionsAndBoundedCycles() throws {
        let value=sequence()
        try value.validate(kind:.image,startFrame:0,endFrame:60)
        for frame in 0..<60 {XCTAssertEqual(try value.sourceRect(at:frame),frame<20 || frame>=40 ? left:right)}
        for frame in [Int.min,-1,60,Int.max] {XCTAssertThrowsError(try value.sourceRect(at:frame))}
        XCTAssertEqual(try Codec.decoder().decode(LayerImageSequence.self,from:Codec.data(value)),value)
        var bound=value;bound.frames=(0..<512).map{.init(startFrame:$0,endFrame:$0+1,sourceRect:$0%2==0 ? left:right)}
        XCTAssertNoThrow(try bound.validate(kind:.image,startFrame:0,endFrame:512))
        bound.frames.append(.init(startFrame:512,endFrame:513,sourceRect:left))
        XCTAssertThrowsError(try bound.validate(kind:.image,startFrame:0,endFrame:513))
    }
    func testRejectsWrongVersionMissingMotionGapsOverlapsAndOutOfLayerFrames() throws {
        var value=sequence();value.version=2
        XCTAssertThrowsError(try value.validate(kind:.image,startFrame:0,endFrame:60))
        value=sequence();value.frames=[value.frames[0]]
        XCTAssertThrowsError(try value.validate(kind:.image,startFrame:0,endFrame:20))
        value=sequence();value.frames[1].sourceRect=left
        XCTAssertThrowsError(try value.validate(kind:.image,startFrame:0,endFrame:60))
        value=sequence();value.frames[1].startFrame=21
        XCTAssertThrowsError(try value.validate(kind:.image,startFrame:0,endFrame:60))
        value=sequence();value.frames[1].startFrame=19
        XCTAssertThrowsError(try value.validate(kind:.image,startFrame:0,endFrame:60))
        value=sequence();value.frames[0].sourceRect.x=0.75
        XCTAssertThrowsError(try value.validate(kind:.image,startFrame:0,endFrame:60))
        XCTAssertThrowsError(try sequence().validate(kind:.image,startFrame:1,endFrame:60))
        XCTAssertThrowsError(try sequence().validate(kind:.image,startFrame:0,endFrame:59))
        XCTAssertThrowsError(try sequence().validate(kind:.text,startFrame:0,endFrame:60))
        for offset in [Int.min,-1,54001,Int.max] {
            value=sequence();value.sourceOffsetFrames=offset
            XCTAssertThrowsError(try value.validate(kind:.image,startFrame:0,endFrame:60))
        }
        for offset in [Int.min,-1,54001,Int.max] {XCTAssertThrowsError(try sequence().advancingSource(by:offset))}
    }
    func testStrictNestedDecodingRejectsUnknownFieldsAndMissingVersion() throws {
        let data=try Codec.data(sequence())
        let original=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        var raw=original;raw["extra"]="hidden"
        XCTAssertThrowsError(try Codec.decoder().decode(LayerImageSequence.self,from:JSONSerialization.data(withJSONObject:raw)))
        raw=original;raw.removeValue(forKey:"version")
        XCTAssertThrowsError(try Codec.decoder().decode(LayerImageSequence.self,from:JSONSerialization.data(withJSONObject:raw)))
        raw=original;var frames=try XCTUnwrap(raw["frames"] as? [[String:Any]]);frames[0]["assetID"]="second-atlas";raw["frames"]=frames
        XCTAssertThrowsError(try Codec.decoder().decode(LayerImageSequence.self,from:JSONSerialization.data(withJSONObject:raw)))
        raw=original;frames=try XCTUnwrap(raw["frames"] as? [[String:Any]]);var rect=try XCTUnwrap(frames[0]["sourceRect"] as? [String:Any]);rect["unknown"]=1;frames[0]["sourceRect"]=rect;raw["frames"]=frames
        XCTAssertThrowsError(try Codec.decoder().decode(LayerImageSequence.self,from:JSONSerialization.data(withJSONObject:raw)))
    }
    func testLayerRulesKeep32LimitAndRequireActualImage() throws {
        let a=asset();var s=scene(asset:a)
        XCTAssertNoThrow(try LayerRules.validate(scene:s,assets:[a]))
        XCTAssertThrowsError(try LayerRules.validate(scene:s,assets:[]))
        s.layers?[0].kind = .rectangle
        XCTAssertThrowsError(try LayerRules.validate(scene:s,assets:[a]))
        s=scene(asset:a);let layer=s.layers![0]
        s.layers=(0..<32).map{index in var copy=layer;copy.id="layer-\(index)";return copy}
        XCTAssertNoThrow(try LayerRules.validate(scene:s,assets:[a]))
        var extra=layer;extra.id="layer-32";s.layers?.append(extra)
        XCTAssertThrowsError(try LayerRules.validate(scene:s,assets:[a]))
    }
    func testLegacyLayerEncodingAndSchemaKeepOptionalSequenceDistinct() throws {
        let bytes=Data(#"{"color":"FFFFFF","endFrame":60,"height":0.2,"id":"legacy","keyframes":[],"kind":"文字","locked":false,"opacity":1,"startFrame":0,"text":"旧图层","width":0.5,"x":0.5,"y":0.5}"#.utf8)
        let layer=try Codec.decoder().decode(SceneLayer.self,from:bytes)
        XCTAssertNil(layer.imageSequence);XCTAssertNil(layer.sourceRect);XCTAssertEqual(try Codec.data(layer),bytes)
        let defs=AgentSchemas.definitions()
        XCTAssertNotNil(defs["SceneLayer"]?.object?["properties"]?.object?["imageSequence"])
        XCTAssertNotNil(defs["SceneLayer"]?.object?["properties"]?.object?["sourceRect"])
        XCTAssertEqual(defs["LayerImageSequence"]?.object?["additionalProperties"],.boolean(false))
        XCTAssertEqual(defs["LayerImageSequence"]?.object?["properties"]?.object?["frames"]?.object?["minItems"],.number(2))
        XCTAssertNotNil(defs["LayerImageSequenceFrame"]?.object?["properties"]?.object?["sourceRect"])
    }
    func testSplitInsideSinglePoseRetainsWholeOriginalSequenceAndEverySample() throws {
        let a=asset()
        for speed in [0.5,1,2] {
            let original=scene(asset:a,speed:speed,pause:5),p=project(original)
            let split=try Editor.apply([.splitScene(original.id,10)],to:p,baseRevision:p.current.id,assets:[a],message:"在单姿态中拆分")
            XCTAssertEqual(split.current.scenes.map(\.pauseFrames),[0,5])
            XCTAssertEqual(split.current.scenes[0].layers?[0].imageSequence?.frames,original.layers?[0].imageSequence?.frames)
            XCTAssertEqual(split.current.scenes[0].layers?[0].imageSequence?.sourceOffsetFrames,0)
            XCTAssertEqual(split.current.scenes[1].layers?[0].imageSequence?.sourceOffsetFrames,10)
            XCTAssertEqual(try split.current.scenes.flatMap{try samples($0)},try samples(original))
            let right=split.current.scenes[1]
            let again=try Editor.apply([.splitScene(right.id,20)],to:split,baseRevision:split.current.id,assets:[a],message:"重复源窗口拆分")
            XCTAssertEqual(again.current.scenes.last?.layers?.first?.imageSequence?.sourceOffsetFrames,30)
            XCTAssertEqual(try again.current.scenes.flatMap{try samples($0)},try samples(original))
            for cut in again.current.scenes {try LayerRules.validate(scene:cut,assets:[a])}
        }
    }
    func testRetimingHoldsLastPoseAndChangesInvalidateSoundAndCaptions() throws {
        let a=asset();var original=scene(asset:a)
        original.captions=[Caption(text:"连续行动",startFrame:0,endFrame:60,confirmed:true)]
        let p=project(original);var changed=original;changed.speed=0.5;changed.pauseFrames=5
        let next=try Editor.apply([.replaceScene(original.id,changed)],to:p,baseRevision:p.current.id,assets:[a],message:"放慢并持画")
        XCTAssertFalse(try XCTUnwrap(next.current.scenes[0].captions.first).confirmed)
        XCTAssertTrue(next.current.invalidated.contains("图片取景、序列、源窗口与声音字幕重新复核"))
        XCTAssertEqual(Array(try samples(next.current.scenes[0]).suffix(5)),Array(repeating:Optional(left),count:5))
        changed=original;changed.layers?[0].imageSequence?.frames[1].sourceRect=MediaFraming(x:0,y:0,width:1,height:1)
        let replaced=try Editor.apply([.replaceScene(original.id,changed)],to:p,baseRevision:p.current.id,assets:[a],message:"改真实图集区域")
        XCTAssertFalse(try XCTUnwrap(replaced.current.scenes[0].captions.first).confirmed)
        XCTAssertNotEqual(try Codec.digest(original),try Codec.digest(changed))
    }
    func testStaticImageCropIsNotAnimationAndIsExclusiveToImageLayers() throws {
        let a=asset();var original=scene(asset:a)
        original.layers?[0].imageSequence=nil;original.layers?[0].sourceRect=left
        original.captions=[Caption(text:"独立静止素材",startFrame:0,endFrame:60,confirmed:true)]
        XCTAssertNoThrow(try LayerRules.validate(scene:original,assets:[a]))
        var bad=original;bad.layers?[0].imageSequence=sequence()
        XCTAssertThrowsError(try LayerRules.validate(scene:bad,assets:[a]))
        bad=original;bad.layers?[0].kind = .rectangle
        XCTAssertThrowsError(try LayerRules.validate(scene:bad,assets:[a]))
        bad=original;bad.layers?[0].sourceRect=MediaFraming(x:0.9,width:0.2)
        XCTAssertThrowsError(try LayerRules.validate(scene:bad,assets:[a]))
        let p=project(original)
        let split=try Editor.apply([.splitScene(original.id,10)],to:p,baseRevision:p.current.id,assets:[a],message:"静止裁区拆分")
        XCTAssertEqual(split.current.scenes.compactMap{$0.layers?.first?.sourceRect},[left,left])
        var changed=original;changed.layers?[0].sourceRect=right
        let revised=try Editor.apply([.replaceScene(original.id,changed)],to:p,baseRevision:p.current.id,assets:[a],message:"改变静止取景")
        XCTAssertFalse(try XCTUnwrap(revised.current.scenes[0].captions.first).confirmed)
        XCTAssertTrue(revised.current.invalidated.contains("图片取景、序列、源窗口与声音字幕重新复核"))
    }
}
