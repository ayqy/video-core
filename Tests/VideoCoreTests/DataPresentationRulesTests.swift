import XCTest
import VideoCore

final class DataPresentationRulesTests: XCTestCase {
    func chart() -> DataChart {
        DataChart(title:"作者给定数据",axisLabel:"代币",minimum:0,maximum:8,
            series:[DataSeries(id:"a",label:"甲",color:"38BDF8",keyframes:[.init(frame:0,value:4),.init(frame:60,value:3),.init(frame:120,value:5)])])
    }
    func layer() -> SceneLayer {
        var value=SceneLayer(kind:.chart,endFrame:120)
        value.dataPresentation=DataPresentation(chart:chart());return value
    }
    func project(_ scene: Scene? = nil) -> Project {
        var s=scene ?? Scene(title:"数据动画",body:"作者给定简化模型",narration:"读图",durationFrames:120)
        if s.layers == nil {s.layers=[layer()]}
        return Project(workspaceID:"w",name:"普通数据工程",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"知识"),aspect:.landscape,scenes:[s]))
    }
    func testValuesInterpolateAndCodeHighlightsUseTheSameAbsoluteSourceClock() throws {
        XCTAssertEqual(try chart().series[0].value(at:30),3.5,accuracy:1e-12)
        XCTAssertEqual(try chart().series[0].value(at:90),4,accuracy:1e-12)
        let code=CodePresentation(title:"只展示",lines:["cost = 1","balance = 4 - cost"],highlights:[.init(startFrame:0,endFrame:60,line:0),.init(startFrame:60,endFrame:120,line:1)])
        let data=DataPresentation(code:code,sourceOffsetFrames:45)
        XCTAssertEqual(try code.highlightedLine(at:data.sourceFrame(at:15)),1)
        XCTAssertNil(try code.highlightedLine(at:120))
    }
    func testPublicSamplingRejectsNegativeExtremeFramesAndOffsetsWithoutTrap() throws {
        for frame in [Int.min,-1,54001,Int.max] {
            XCTAssertThrowsError(try chart().values(at:frame))
            XCTAssertThrowsError(try DataPresentation(chart:chart()).sourceFrame(at:frame))
            XCTAssertThrowsError(try CodePresentation(title:"展示",lines:["x = 1"]).highlightedLine(at:frame))
        }
        for offset in [Int.min,-1,54001,Int.max] {
            XCTAssertThrowsError(try DataPresentation(chart:chart(),sourceOffsetFrames:offset).advancingSource(by:1))
        }
        XCTAssertThrowsError(try DataPresentation(chart:chart(),sourceOffsetFrames:54000).sourceFrame(at:1))
    }
    func testInvalidNumbersArraysAndCodeTimeRangesAreRejected() throws {
        for number in [Double.nan,Double.infinity,-Double.infinity,1e10] {
            var value=chart();value.series[0].keyframes[0].value=number;XCTAssertThrowsError(try value.validate())
        }
        var value=chart();value.maximum=value.minimum;XCTAssertThrowsError(try value.validate())
        value=chart();value.series[0].keyframes[1].frame=0;XCTAssertThrowsError(try value.validate())
        value=chart();value.series[0].keyframes=Array(repeating:.init(frame:0,value:1),count:129);XCTAssertThrowsError(try value.validate())
        value=chart();value.series=(0..<9).map{DataSeries(id:String($0),label:"系列",color:"38BDF8",keyframes:[.init(frame:0,value:1)])};XCTAssertThrowsError(try value.validate())
        value=chart();value.series[0].keyframes[0].value=9;XCTAssertThrowsError(try value.validate())
        var code=CodePresentation(title:"展示",lines:["a","b"],highlights:[.init(startFrame:0,endFrame:60,line:0),.init(startFrame:59,endFrame:80,line:1)])
        XCTAssertThrowsError(try code.validate())
        code.highlights=[.init(startFrame:0,endFrame:2,line:2)];XCTAssertThrowsError(try code.validate())
        code.highlights=[];code.lines=Array(repeating:"x",count:17);XCTAssertThrowsError(try code.validate())
        code.lines=["line\nsecond"];XCTAssertThrowsError(try code.validate())
    }
    func testWrongOrAmbiguousPayloadCannotHideUnderAnotherLayerKind() throws {
        var scene=project().current.scenes[0]
        scene.layers?[0].dataPresentation=nil;XCTAssertThrowsError(try scene.validate(assets:[]))
        scene.layers=[layer()];scene.layers?[0].kind = .text;scene.layers?[0].text="错误绑定";XCTAssertThrowsError(try scene.validate(assets:[]))
        scene.layers=[layer()];scene.layers?[0].dataPresentation?.code=CodePresentation(title:"代码",lines:["x"]);XCTAssertThrowsError(try scene.validate(assets:[]))
        scene.layers=[layer()];scene.layers?[0].assetID="hidden";XCTAssertThrowsError(try scene.validate(assets:[]))
        scene.layers=[layer()];scene.layers?[0].dataPresentation?.version=2;XCTAssertThrowsError(try scene.validate(assets:[]))
    }
    func testStrictTypedDecodingRejectsUnknownFieldsAtEveryNestedLevel() throws {
        let samples:[(String,Data)]=[
            ("presentation",Data(#"{"version":1,"execute":"never"}"#.utf8)),
            ("chart",Data(#"{"title":"t","axisLabel":"u","minimum":0,"maximum":1,"series":[],"execute":"never"}"#.utf8)),
            ("series",Data(#"{"id":"a","label":"A","color":"FFFFFF","keyframes":[],"execute":"never"}"#.utf8)),
            ("value",Data(#"{"frame":0,"value":1,"execute":"never"}"#.utf8)),
            ("code",Data(#"{"title":"t","lines":["x"],"highlights":[],"execute":"never"}"#.utf8)),
            ("highlight",Data(#"{"startFrame":0,"endFrame":1,"line":0,"execute":"never"}"#.utf8))]
        for (name,data) in samples {
            switch name {
            case "presentation":XCTAssertThrowsError(try Codec.decoder().decode(DataPresentation.self,from:data))
            case "chart":XCTAssertThrowsError(try Codec.decoder().decode(DataChart.self,from:data))
            case "series":XCTAssertThrowsError(try Codec.decoder().decode(DataSeries.self,from:data))
            case "value":XCTAssertThrowsError(try Codec.decoder().decode(DataValueKeyframe.self,from:data))
            case "code":XCTAssertThrowsError(try Codec.decoder().decode(CodePresentation.self,from:data))
            default:XCTAssertThrowsError(try Codec.decoder().decode(CodeHighlight.self,from:data))
            }
        }
    }
    func testLegacyLayerEncodingBytesAndDigestStayUnchanged() throws {
        let legacy=Data(#"{"color":"FFFFFF","endFrame":120,"height":0.2,"id":"legacy-layer","keyframes":[],"kind":"文字","locked":false,"opacity":1,"startFrame":0,"text":"旧元素","width":0.5,"x":0.5,"y":0.5}"#.utf8)
        let value=try Codec.decoder().decode(SceneLayer.self,from:legacy)
        XCTAssertNil(value.dataPresentation)
        XCTAssertEqual(try Codec.data(value),legacy)
        XCTAssertEqual(try Codec.digest(value),Codec.hash(legacy))
    }
    func testLockedDataLayerCannotBeMutatedThroughNormalEditor() throws {
        var p=project();p.revisions[0].scenes[0].layers?[0].locked=true
        var scene=p.current.scenes[0];scene.layers?[0].dataPresentation?.chart?.series[0].keyframes[0].value=3
        XCTAssertThrowsError(try Editor.apply([.replaceScene(scene.id,scene)],to:p,baseRevision:p.current.id,assets:[],message:"修改锁定图表"))
    }
    func testDataAndSpeedChangesClearVoiceCaptionsAndGlobalReview() throws {
        for speedChange in [false,true] {
            var p=project();var scene=p.current.scenes[0]
            scene.captions=[Caption(text:"读图",startFrame:0,endFrame:100)];scene.captions[0].confirmed=true
            scene.voice=VoiceTake(assetID:"voice",textDigest:try scene.speechDigest(),durationFrames:100,method:"import",listened:true)
            p.revisions[0].scenes[0]=scene;p.revisions[0].review.sound=true;p.revisions[0].review.captions=true
            if speedChange {scene.speed=2} else {scene.layers?[0].dataPresentation?.chart?.series[0].keyframes[0].value=3}
            let next=try Editor.apply([.replaceScene(scene.id,scene)],to:p,baseRevision:p.current.id,assets:[],message:"实际编辑")
            XCTAssertFalse(try XCTUnwrap(next.current.scenes[0].voice).listened)
            XCTAssertFalse(next.current.scenes[0].captions[0].confirmed)
            XCTAssertFalse(next.current.review.sound);XCTAssertFalse(next.current.review.captions)
            XCTAssertTrue(next.current.invalidated.contains("数据、代码步骤、时间轴与声音字幕重新复核"))
            XCTAssertTrue(p.current.scenes[0].voice!.listened)
        }
    }
    func testSplittingRetainsAbsoluteDataAndCodeClockWithNonzeroLayerStart() throws {
        var p=project();var original=p.current.scenes[0]
        original.layers?[0].startFrame=20;original.layers?[0].dataPresentation?.sourceOffsetFrames=5
        var code=SceneLayer(kind:.code,endFrame:120);code.startFrame=20
        code.dataPresentation=DataPresentation(code:CodePresentation(title:"代码",lines:["cost = 1","balance = 5"],highlights:[.init(startFrame:0,endFrame:70,line:0),.init(startFrame:70,endFrame:140,line:1)]),sourceOffsetFrames:5)
        original.layers?.append(code);p.revisions[0].scenes[0]=original
        let next=try Editor.apply([.splitScene(original.id,60)],to:p,baseRevision:p.current.id,assets:[],message:"按源拆分")
        let right=next.current.scenes[1],rightChart=try XCTUnwrap(right.layers?[0].dataPresentation)
        XCTAssertEqual(rightChart.sourceOffsetFrames,65)
        let originalFrame=try original.layers![0].dataPresentation!.sourceFrame(at:75)
        let splitFrame=try rightChart.sourceFrame(at:15)
        XCTAssertEqual(originalFrame,splitFrame)
        XCTAssertEqual(try chart().values(at:originalFrame),try rightChart.chart!.values(at:splitFrame))
        let rightCode=try XCTUnwrap(right.layers?[1].dataPresentation)
        XCTAssertEqual(try rightCode.code!.highlightedLine(at:rightCode.sourceFrame(at:15)),1)
        XCTAssertEqual(p.current.scenes[0].layers![0].dataPresentation?.sourceOffsetFrames,5)
    }
    func testSpeedMappingDoesNotResetDataAtTheSplit() throws {
        var p=project();p.revisions[0].scenes[0].speed=2
        let original=p.current.scenes[0]
        let next=try Editor.apply([.splitScene(original.id,60)],to:p,baseRevision:p.current.id,assets:[],message:"2倍速对齐切口")
        let right=next.current.scenes[1],data=try XCTUnwrap(right.layers?[0].dataPresentation)
        XCTAssertEqual(try data.sourceFrame(at:right.renderSourceFrame(atTimelineFrame:10)),original.renderSourceFrame(atTimelineFrame:40))
    }
    func testMediaFramingEditInvalidatesVoiceAndCaptionAssertions() throws {
        let image=Asset(workspaceID:"w",name:"实图",hash:String(repeating:"a",count:64),ext:"png",bytes:1,mediaType:"image")
        var scene=Scene(kind:.image,title:"图片取景",body:"原件",narration:"解释",durationFrames:120)
        scene.assetID=image.id;scene.captions=[Caption(text:"解释",startFrame:0,endFrame:100)];scene.captions[0].confirmed=true
        scene.voice=VoiceTake(assetID:"voice",textDigest:try scene.speechDigest(),durationFrames:100,method:"import",listened:true)
        let p=project(scene);scene=p.current.scenes[0];scene.mediaFraming=MediaFraming(x:0.1,y:0.1,width:0.8,height:0.8)
        let next=try Editor.apply([.replaceScene(scene.id,scene)],to:p,baseRevision:p.current.id,assets:[image],message:"正常取景")
        XCTAssertFalse(next.current.scenes[0].voice!.listened);XCTAssertFalse(next.current.scenes[0].captions[0].confirmed)
    }
    func testNormalDiscoveryContainsStrictTypedDefinitionsAndOptionalOldCompatibleField() throws {
        let definitions=AgentSchemas.definitions()
        for type in ["DataPresentation","DataChart","DataSeries","DataValueKeyframe","CodePresentation","CodeHighlight","MediaFraming"] {
            XCTAssertEqual(definitions[type]?.object?["additionalProperties"],.boolean(false))
        }
        XCTAssertNotNil(definitions["SceneLayer"]?.object?["properties"]?.object?["dataPresentation"])
        XCTAssertNotNil(definitions["Scene"]?.object?["properties"]?.object?["mediaFraming"])
        let text=String(decoding:try Codec.data(AgentContract.catalog()),as:UTF8.self)
        XCTAssertTrue(text.contains("数据图表"));XCTAssertTrue(text.contains("代码演示"))
    }
}
