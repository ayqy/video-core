import XCTest
import VideoCore

final class LayerTests:XCTestCase {
    func testVisualPauseHoldsTheFinalSourceWithoutExtendingCaptionWindowsOrAuthoredExits() throws {
        for speed in [0.25,0.5,1,1.5,2,4] {
            var scene=Scene(title:"翻页前看清结果",body:"画面停留，口播已结束。",durationFrames:120)
            scene.speed=speed;scene.pauseFrames=12
            scene.captions=[Caption(text:"路修好了。",startFrame:0,endFrame:120)]
            let complete=SceneLayer(kind:.text,text:"路已修好",endFrame:120)
            var earlier=SceneLayer(kind:.rectangle,endFrame:90);earlier.startFrame=30
            scene.layers=[complete,earlier]
            let firstPause=scene.timelineFrames-scene.pauseFrames
            for local in firstPause..<scene.timelineFrames {
                let source=scene.renderSourceFrame(atTimelineFrame:local)
                let held=LayerRules.renderSourceFrame(scene:scene,sourceFrame:source)
                XCTAssertEqual(held,119)
                XCTAssertTrue(complete.startFrame<=held && held<complete.endFrame)
                XCTAssertFalse(earlier.startFrame<=held && held<earlier.endFrame,"作者已结束的元素不能在留白期复活")
                XCTAssertFalse(scene.captions.contains{$0.startFrame<=source && source<$0.endFrame},"字幕继续使用原始源帧，不跟随视觉持画延长")
            }
            XCTAssertEqual(try SpeechRules.captionTimelineRanges(for:scene).last?.frames.upperBound,firstPause)
        }
    }
    func testPlainLayerPauseAndMotionSurviveAlignedSpeedSplits() throws {
        for speed in [0.5,1,2,4] {
            var scene=Scene(title:"同一张图",body:"拆分保留最后停顿",durationFrames:120)
            scene.speed=speed;scene.pauseFrames=7
            var layer=SceneLayer(kind:.text,text:"保留结果",endFrame:120)
            layer.keyframes=[Keyframe(frame:0,x:0.3,y:0.4,scale:1),Keyframe(frame:119,x:0.7,y:0.6,scale:1.2)]
            scene.layers=[layer]
            let original=Project(workspaceID:"w",name:"普通图层停顿",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"知识"),aspect:.landscape,scenes:[scene]))
            let split=try Editor.apply([.splitScene(scene.id,60)],to:original,baseRevision:original.current.id,assets:[],message:"保留图形末态")
            XCTAssertEqual(split.current.scenes.map(\.pauseFrames),[0,7])
            func samples(_ scenes:[Scene])throws->[(Double,Double,Double)] {
                try scenes.flatMap { scene in
                    let layer=try XCTUnwrap(scene.layers?.first)
                    return (0..<scene.timelineFrames).map { local in
                        let frame=LayerRules.renderSourceFrame(scene:scene,sourceFrame:scene.renderSourceFrame(atTimelineFrame:local))
                        let point=layer.layout(at:frame)
                        return (point.x,point.y,point.scale)
                    }
                }
            }
            let before=try samples([scene]),after=try samples(split.current.scenes)
            XCTAssertEqual(before.count,after.count)
            for (a,b) in zip(before,after) {XCTAssertEqual(a.0,b.0,accuracy:1e-12);XCTAssertEqual(a.1,b.1,accuracy:1e-12);XCTAssertEqual(a.2,b.2,accuracy:1e-12)}
        }
    }
    func project() -> Project { let p=Product(workspaceID:"w",sku:"s",name:"课程",checkout:"https://example.com",audience:"学员",task:"练习",outcome:"能复现",prerequisite:"无",scope:"软件",prices:[Price(money:Money(99),source:"购买页",verified:true)]);return Project(workspaceID:"w",name:"图层",revision:Revision(product:p,purpose:.education,aspect:.landscape,scenes:[Scene(title:"标题",body:"知识",durationFrames:120)],cta:"动手复现")) }
    func testLayerLocksAndExplicitUnlock() throws { var p=project();var l=SceneLayer(kind:.text,text:"真实价格",endFrame:120);l.locked=true;p.revisions[0].scenes[0].layers=[l];var s=p.current.scenes[0];s.layers?[0].text="改动";XCTAssertThrowsError(try Editor.apply([.replaceScene(s.id,s)],to:p,baseRevision:p.current.id,assets:[],message:"改锁定层"));p=try Editor.apply([.lockLayer(s.id,l.id,false),.replaceScene(s.id,{var copy=s;copy.layers?[0].locked=false;return copy}())],to:p,baseRevision:p.current.id,assets:[],message:"先解锁后修改");XCTAssertEqual(p.current.scenes[0].layers?[0].text,"改动") }
    func testSplitRetimesLayerAndKeepsHistory() throws { var p=project();var l=SceneLayer(kind:.text,text:"一二三",endFrame:110);l.startFrame=20;l.keyframes=[Keyframe(frame:20,x:0.2,y:0.3,scale:1),Keyframe(frame:100,x:0.8,y:0.6,scale:1)];p.revisions[0].scenes[0].layers=[l];let original=p.current;p=try Editor.apply([.splitScene(original.scenes[0].id,60)],to:p,baseRevision:original.id,assets:[],message:"拆分元素");XCTAssertEqual(p.revisions.first?.scenes[0].layers?[0].endFrame,110);XCTAssertEqual(p.current.scenes[0].layers?[0].endFrame,60);XCTAssertEqual(p.current.scenes[1].layers?[0].startFrame,0);XCTAssertEqual(p.current.scenes[1].layers?[0].endFrame,50);XCTAssertEqual(p.current.scenes[1].layers![0].layout(at:0).x,l.layout(at:60).x,accuracy:0.00001) }
    func testCommentCannotReferenceOtherVersionSceneOrTime() throws { let p=project();let r=p.current;let c=Comment(revisionID:r.id,sceneID:r.scenes[0].id,frame:10,element:"标题",text:"核对术语",author:"owner");try CommentRules.validate(c,project:p);var bad=c;bad.frame=120;XCTAssertThrowsError(try CommentRules.validate(bad,project:p));bad=c;bad.sceneID="other";XCTAssertThrowsError(try CommentRules.validate(bad,project:p));bad=c;bad.element="unknown-layer";XCTAssertThrowsError(try CommentRules.validate(bad,project:p));bad=c;bad.revisionID="other";XCTAssertThrowsError(try CommentRules.validate(bad,project:p)) }
}
