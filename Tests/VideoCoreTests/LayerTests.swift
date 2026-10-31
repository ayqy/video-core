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
    private func actionProject()->Project {
        var p=project()
        var fixed=SceneLayer(kind:.rectangle,endFrame:120);fixed.id="fixed";fixed.locked=true
        var editable=SceneLayer(kind:.rectangle,endFrame:120);editable.id="editable"
        p.revisions[0].scenes[0].layers=[fixed,editable]
        p.revisions[0].scenes[0].storyActions=[
            StoryAction(id:"fixed-move",kind:.move,subjectID:fixed.id,startFrame:0,endFrame:30,
                from:StoryPoint(x:0.2,y:0.4),to:StoryPoint(x:0.6,y:0.4)),
            StoryAction(id:"fixed-hide",kind:.hide,subjectID:fixed.id,startFrame:60,endFrame:70),
            StoryAction(id:"editable-transfer",kind:.transfer,subjectID:editable.id,targetID:fixed.id,startFrame:30,endFrame:50,
                from:StoryPoint(x:0.8,y:0.6),to:StoryPoint(x:0.6,y:0.4))]
        return p
    }
    func testUnchangedLockedLayerCannotBeMovedThroughItsStoryAction() throws {
        let p=actionProject(),original=p.current.scenes[0]
        var changed=original;changed.storyActions?[0].to=StoryPoint(x:0.9,y:0.4)
        XCTAssertEqual(changed.layers,original.layers,"绕过不能靠修改图层本体复现")
        let before=StoryActionRules.presentation(subjectID:"fixed",actions:original.storyActions ?? [],frame:20)
        let after=StoryActionRules.presentation(subjectID:"fixed",actions:changed.storyActions ?? [],frame:20)
        XCTAssertNotEqual(before.position,after.position,"实际绘图消费的过程坐标已经变化")
        XCTAssertThrowsError(try Editor.apply([.replaceScene(original.id,changed)],to:p,baseRevision:p.current.id,assets:[],message:"只改锁层外部路径")) {error in
            guard case VideoError.permission = error else {return XCTFail("应由锁定权限拒绝：\(error)")}
        }
        XCTAssertEqual(p.current.scenes[0],original)
    }
    func testLockedLayerRejectsRemovingAddingAndChangingItsStoryActions() throws {
        let p=actionProject(),original=p.current.scenes[0]
        var removed=original;removed.storyActions?.removeAll{$0.subjectID=="fixed"}
        var added=original;added.storyActions?.append(StoryAction(id:"fixed-show",kind:.show,subjectID:"fixed",startFrame:80,endFrame:90))
        var visibility=original;visibility.storyActions?[1].endFrame=80
        var speech=original;speech.storyActions?.append(StoryAction(id:"fixed-line",kind:.speak,subjectID:"fixed",startFrame:90,endFrame:100,text:"原主体的过程台词"))
        for changed in [removed,added,visibility,speech] {
            XCTAssertEqual(changed.layers,original.layers)
            XCTAssertThrowsError(try Editor.apply([.replaceScene(original.id,changed)],to:p,baseRevision:p.current.id,assets:[],message:"未解锁不能替换主体过程")) {error in
                guard case VideoError.permission = error else {return XCTFail("应由锁定权限拒绝：\(error)")}
            }
        }
    }
    func testLockedLayerAllowsActionReorderingOtherSubjectsAndRecipientReferences() throws {
        let p=actionProject(),original=p.current.scenes[0]
        var reordered=original;reordered.storyActions=Array((original.storyActions ?? []).reversed())
        let same=try Editor.apply([.replaceScene(original.id,reordered)],to:p,baseRevision:p.current.id,assets:[],message:"动作数组重排不改内容")
        XCTAssertEqual(same.current.scenes[0].layers,original.layers)
        var changed=original;changed.layers?[1].color="FF0000"
        changed.storyActions?[2].from=StoryPoint(x:0.9,y:0.7)
        XCTAssertEqual(changed.storyActions?[2].targetID,"fixed","接收方引用不等于修改锁定主体自身")
        let edited=try Editor.apply([.replaceScene(original.id,changed)],to:p,baseRevision:p.current.id,assets:[],message:"修改其他元素自己的动作")
        XCTAssertEqual(edited.current.scenes[0].layers?[0],original.layers?[0])
        XCTAssertEqual(edited.current.scenes[0].storyActions?.filter{$0.subjectID=="fixed"},original.storyActions?.filter{$0.subjectID=="fixed"})
        XCTAssertEqual(edited.current.scenes[0].storyActions?[2],changed.storyActions?[2])
    }
    func testExplicitLayerUnlockAllowsChangingItsStoryActionAndKeepsLockedHistory() throws {
        let p=actionProject(),original=p.current.scenes[0]
        var changed=original;changed.layers?[0].locked=false
        changed.storyActions?[0].to=StoryPoint(x:0.9,y:0.4)
        let result=try Editor.apply([.lockLayer(original.id,"fixed",false),.replaceScene(original.id,changed)],to:p,baseRevision:p.current.id,assets:[],message:"显式解锁再改路径")
        XCTAssertEqual(result.current.scenes[0].layers?[0].locked,false)
        XCTAssertEqual(result.current.scenes[0].storyActions,changed.storyActions)
        XCTAssertEqual(result.revisions.first?.scenes[0],original,"解锁修改不得重写锁定历史")
    }
    func testSplitRetimesLayerAndKeepsHistory() throws { var p=project();var l=SceneLayer(kind:.text,text:"一二三",endFrame:110);l.startFrame=20;l.keyframes=[Keyframe(frame:20,x:0.2,y:0.3,scale:1),Keyframe(frame:100,x:0.8,y:0.6,scale:1)];p.revisions[0].scenes[0].layers=[l];let original=p.current;p=try Editor.apply([.splitScene(original.scenes[0].id,60)],to:p,baseRevision:original.id,assets:[],message:"拆分元素");XCTAssertEqual(p.revisions.first?.scenes[0].layers?[0].endFrame,110);XCTAssertEqual(p.current.scenes[0].layers?[0].endFrame,60);XCTAssertEqual(p.current.scenes[1].layers?[0].startFrame,0);XCTAssertEqual(p.current.scenes[1].layers?[0].endFrame,50);XCTAssertEqual(p.current.scenes[1].layers![0].layout(at:0).x,l.layout(at:60).x,accuracy:0.00001) }
    func testCommentCannotReferenceOtherVersionSceneOrTime() throws { let p=project();let r=p.current;let c=Comment(revisionID:r.id,sceneID:r.scenes[0].id,frame:10,element:"标题",text:"核对术语",author:"owner");try CommentRules.validate(c,project:p);var bad=c;bad.frame=120;XCTAssertThrowsError(try CommentRules.validate(bad,project:p));bad=c;bad.sceneID="other";XCTAssertThrowsError(try CommentRules.validate(bad,project:p));bad=c;bad.element="unknown-layer";XCTAssertThrowsError(try CommentRules.validate(bad,project:p));bad=c;bad.revisionID="other";XCTAssertThrowsError(try CommentRules.validate(bad,project:p)) }
}
