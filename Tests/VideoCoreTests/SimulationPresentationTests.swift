import XCTest
@testable import VideoCore

final class SimulationPresentationTests: XCTestCase {
    private func scene() -> Scene {
        var s=Scene(kind:.simulation,title:"公共品知识",body:"选择与后果",durationFrames:180)
        s.simulation.knowledge=KnowledgeSimulation(knowledgeLabel:"公共品",participants:[
            .init(id:"a",name:"甲",strategy:.contribute),.init(id:"b",name:"乙",strategy:.freeRide)
        ],rounds:1)
        return s
    }
    private func project(_ s:Scene)->Project {
        Project(workspaceID:"window",name:"知识分镜",revision:Revision(contentContext:ContentContext(workspaceID:"window",name:"公共品知识"),aspect:.landscape,scenes:[s]))
    }
    func testWindowUsesIntegerEndpointsAndHoldsPauseWithoutFutureEvents() throws {
        var s=scene();s.durationFrames=91;s.pauseFrames=60
        s.simulationPresentation=SimulationPresentation(sourceStartFrame:60,sourceEndFrame:90,presentationFrames:91)
        XCTAssertEqual(try s.renderSimulationSourceFrame(atTimelineFrame:0),60)
        XCTAssertEqual(try s.renderSimulationSourceFrame(atTimelineFrame:45),74)
        XCTAssertEqual(try s.renderSimulationSourceFrame(atTimelineFrame:90),89)
        XCTAssertEqual(try s.renderSimulationSourceFrame(atTimelineFrame:150),89)
        for f in 0..<s.timelineFrames {
            let state=try KnowledgeSimulationEngine.frameState(model:XCTUnwrap(s.simulation.knowledge),seed:1,frame:s.renderSimulationSourceFrame(atTimelineFrame:f),fps:30)
            XCTAssertEqual(state.phase,.contribution)
            XCTAssertTrue(state.actors.allSatisfy{$0.benefit==0})
        }
    }
    func testEverySplitFramePreservesOriginalSourceMapping() throws {
        let source=SimulationPresentation(sourceStartFrame:41,sourceEndFrame:153,presentationFrames:201)
        for boundary in [1,31,100,200] {
            let a=try source.sliced(from:0,to:boundary,durationFrames:201)
            let b=try source.sliced(from:boundary,to:201,durationFrames:201)
            for f in 0..<201 {
                let actual=try (f<boundary ? a.sourceFrame(atSceneFrame:f,durationFrames:boundary) : b.sourceFrame(atSceneFrame:f-boundary,durationFrames:201-boundary))
                XCTAssertEqual(actual,try source.sourceFrame(atSceneFrame:f,durationFrames:201))
            }
        }
    }
    func testNarrationRetimingKeepsVisibleSliceEndpoints() throws {
        let source=SimulationPresentation(sourceStartFrame:0,sourceEndFrame:180,presentationFrames:181)
        let cut=try source.sliced(from:60,to:120,durationFrames:181)
        let longer=try cut.retimed(to:420,durationFrames:60)
        XCTAssertEqual(try cut.sourceFrame(atSceneFrame:0,durationFrames:60),try longer.sourceFrame(atSceneFrame:0,durationFrames:420))
        XCTAssertEqual(try cut.sourceFrame(atSceneFrame:59,durationFrames:60),try longer.sourceFrame(atSceneFrame:419,durationFrames:420))
        XCTAssertEqual(longer.presentationOffsetFrames,0)
        XCTAssertThrowsError(try cut.retimed(to:Int.max,durationFrames:60))
        XCTAssertThrowsError(try cut.retimed(to:1,durationFrames:60),"单展示帧不可静默丢掉可见源区间")
        let still=SimulationPresentation(sourceStartFrame:30,sourceEndFrame:31,presentationFrames:30)
        XCTAssertNoThrow(try still.retimed(to:1,durationFrames:30))
    }
    func testPartialRecordingRetainsCausalHistoryButOnlySeeksVisibleTicks() throws {
        var s=scene();s.durationFrames=90
        s.simulationPresentation=SimulationPresentation(sourceStartFrame:60,sourceEndFrame:120,presentationFrames:90)
        s.simulationRecording=try SimulationReplay.record(scene:s)
        XCTAssertEqual(s.simulationRecording?.initial,6)
        XCTAssertEqual(s.simulationRecording?.finalState,5)
        XCTAssertEqual(s.simulationRecording?.recordedPresentation,s.simulationPresentation)
        XCTAssertNoThrow(try SimulationReplay.verify(scene:s,requireConfirmation:false))
        let first=try SimulationReplay.replay(scene:s,timelineFrame:0)
        XCTAssertEqual(first.sourceFrame,60);XCTAssertEqual(first.state.value,5)
        XCTAssertThrowsError(try SimulationReplay.replayFrame(scene:s,tick:1))
        let visible=try SimulationReplay.replayFrame(scene:s,tick:3)
        XCTAssertEqual(try s.renderSimulationSourceFrame(atTimelineFrame:visible)/30,3)
        XCTAssertThrowsError(try SimulationReplay.verify(scene:s),"源窗口不能自动授予录制确认")
    }
    func testNormalEditorSplitCreatesTwoReRecordableCausalWindows() throws {
        var s=scene();s.simulationRecording=try SimulationReplay.record(scene:s);s.simulationRecordingConfirmed=true
        let original=project(s)
        let changed=try Editor.apply([.splitScene(s.id,90)],to:original,baseRevision:original.current.id,assets:[],message:"拆知识分镜")
        let a=changed.current.scenes[0],b=changed.current.scenes[1]
        XCTAssertEqual(a.simulationRecordingConfirmed,false);XCTAssertEqual(b.simulationRecordingConfirmed,false)
        XCTAssertNoThrow(try SimulationReplay.record(scene:a));XCTAssertNoThrow(try SimulationReplay.record(scene:b))
        for f in 0..<180 {
            let actual=try (f<90 ? a.renderSimulationSourceFrame(atTimelineFrame:f) : b.renderSimulationSourceFrame(atTimelineFrame:f-90))
            XCTAssertEqual(actual,try s.renderSimulationSourceFrame(atTimelineFrame:f))
        }
    }
    func testPresentationChangesInvalidateRecordingAndReview() throws {
        var s=scene();s.simulationPresentation=SimulationPresentation(sourceStartFrame:0,sourceEndFrame:180,presentationFrames:180)
        s.simulationRecording=try SimulationReplay.record(scene:s);s.simulationRecordingConfirmed=true
        let original=project(s);var update=s
        update.simulationPresentation=SimulationPresentation(sourceStartFrame:30,sourceEndFrame:180,presentationFrames:180)
        let edited=try Editor.apply([.replaceScene(s.id,update)],to:original,baseRevision:original.current.id,assets:[],message:"改知识展示")
        XCTAssertEqual(edited.current.scenes[0].simulationRecordingConfirmed,false)
        XCTAssertThrowsError(try SimulationReplay.verify(scene:edited.current.scenes[0],requireConfirmation:false))
        XCTAssertFalse(edited.current.review.complete)
    }
    func testSplitRejectsSpeedRoundingAndKeepsOneTrailingPause() throws {
        var s=scene();s.simulationPresentation=SimulationPresentation(sourceStartFrame:0,sourceEndFrame:180,presentationFrames:180)
        s.speed=2
        let fast=project(s)
        XCTAssertThrowsError(try Editor.apply([.splitScene(s.id,91)],to:fast,baseRevision:fast.current.id,assets:[],message:"不可通过取整多放一帧"))
        s.speed=1;s.pauseFrames=30
        let paused=project(s)
        let result=try Editor.apply([.splitScene(s.id,90)],to:paused,baseRevision:paused.current.id,assets:[],message:"保留唯一尾停顿")
        let a=result.current.scenes[0],b=result.current.scenes[1]
        XCTAssertEqual(a.pauseFrames,0);XCTAssertEqual(b.pauseFrames,30)
        XCTAssertEqual(a.timelineFrames+b.timelineFrames,s.timelineFrames)
        for f in 0..<s.timelineFrames {
            let actual=try (f<a.timelineFrames ? a.renderSimulationSourceFrame(atTimelineFrame:f) : b.renderSimulationSourceFrame(atTimelineFrame:f-a.timelineFrames))
            XCTAssertEqual(actual,try s.renderSimulationSourceFrame(atTimelineFrame:f))
        }
    }
    func testInvalidAndOverflowWindowsRejectBeforeArithmetic() throws {
        for p in [SimulationPresentation(sourceStartFrame:-1,sourceEndFrame:30,presentationFrames:30),SimulationPresentation(sourceStartFrame:0,sourceEndFrame:Int.max,presentationFrames:30),SimulationPresentation(sourceStartFrame:30,sourceEndFrame:30,presentationFrames:30),SimulationPresentation(sourceStartFrame:0,sourceEndFrame:30,presentationFrames:30,presentationOffsetFrames:Int.max)] {
            XCTAssertThrowsError(try p.sourceFrame(atSceneFrame:0,durationFrames:30))
        }
        let p=SimulationPresentation(sourceStartFrame:0,sourceEndFrame:30,presentationFrames:30)
        XCTAssertThrowsError(try p.sourceFrame(atSceneFrame:Int.max,durationFrames:30))
        XCTAssertThrowsError(try p.sliced(from:29,to:31,durationFrames:30))
        XCTAssertThrowsError(try SimulationPresentation(sourceStartFrame:0,sourceEndFrame:30,presentationFrames:1).validate(durationFrames:1))
        var s=scene();s.kind = .explanation;s.simulationPresentation=p
        XCTAssertThrowsError(try s.validate(assets:[]))
    }
    func testNilPresentationKeepsLegacyEncodingAndMapping() throws {
        var s=scene();s.speed=2;s.pauseFrames=30
        for f in [0,60,119] {XCTAssertEqual(try s.renderSimulationSourceFrame(atTimelineFrame:f),s.renderSourceFrame(atTimelineFrame:f))}
        let raw=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(s)) as? [String:Any])
        XCTAssertNil(raw["simulationPresentation"])
        let decoded=try Codec.decoder().decode(Scene.self,from:Codec.data(s))
        XCTAssertNil(decoded.simulationPresentation)
        let recorded=try SimulationReplay.record(scene:s)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(recorded)) as? [String:Any])
        XCTAssertNil(object["recordedPresentation"])
    }
}
