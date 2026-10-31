import XCTest
@testable import VideoCore

final class RouteLayoutTests:XCTestCase {
    func testBentRouteVisitsJunctionContinuouslyAndKeepsCargoOffset()throws {
        let a=StoryPoint(x:0.1,y:0.1),junction=StoryPoint(x:0.1,y:0.6),b=StoryPoint(x:0.6,y:0.6)
        var action=StoryAction(id:"cart",kind:.move,subjectID:"cart",startFrame:0,endFrame:11,from:a,to:b)
        action.waypoints=[junction]
        try StoryActionRules.validate([action],durationFrames:11,subjectIDs:["cart"])
        XCTAssertEqual(StoryActionRules.presentation(subjectID:"cart",actions:[action],frame:5).position,junction)
        XCTAssertEqual(StoryActionRules.presentation(subjectID:"cart",actions:[action],frame:20).position,b)
        for frame in 0...10 {
            let p=try XCTUnwrap(StoryActionRules.presentation(subjectID:"cart",actions:[action],frame:frame).position)
            XCTAssertTrue(frame<=5 ? abs(p.x-a.x)<1e-9:abs(p.y-b.y)<1e-9)
            let shifted=StoryActionRules.routePoint(from:.init(x:a.x+0.05,y:a.y+0.03),to:.init(x:b.x+0.05,y:b.y+0.03),waypoints:[.init(x:junction.x+0.05,y:junction.y+0.03)],progress:Double(frame)/10)
            XCTAssertEqual(shifted.x-p.x,0.05,accuracy:1e-9);XCTAssertEqual(shifted.y-p.y,0.03,accuracy:1e-9)
        }
    }
    func testLegacyMovesKeepWireShapeAndRejectInvalidHiddenRoutes()throws {
        let a=StoryPoint(x:0.1,y:0.1),b=StoryPoint(x:0.5,y:0.5)
        var action=StoryAction(id:"a",kind:.move,subjectID:"a",startFrame:0,endFrame:10,from:a,to:b)
        let old=try Codec.data(action)
        XCTAssertNil((try JSONSerialization.jsonObject(with:old) as? [String:Any])?["waypoints"])
        XCTAssertEqual(try Codec.decoder().decode(StoryAction.self,from:old),action)
        XCTAssertEqual(StoryActionRules.presentation(subjectID:"a",actions:[action],frame:0).position,a)
        action.waypoints=[a];XCTAssertThrowsError(try StoryActionRules.validate([action],durationFrames:10,subjectIDs:["a"]))
        action.waypoints=[.init(x:2,y:0.2)];XCTAssertThrowsError(try StoryActionRules.validate([action],durationFrames:10,subjectIDs:["a"]))
        action.waypoints=[];XCTAssertThrowsError(try StoryActionRules.validate([action],durationFrames:10,subjectIDs:["a"]))
        action.kind = .show;action.from=nil;action.to=nil;action.waypoints=[b]
        XCTAssertThrowsError(try StoryActionRules.validate([action],durationFrames:10,subjectIDs:["a"]))
    }
    func testNewRouteAndPresenterAnchorNeverReachOldModuleSilently()throws {
        var action=StoryAction(id:"a",kind:.move,subjectID:"a",startFrame:0,endFrame:10,from:.init(x:0.1,y:0.1),to:.init(x:0.5,y:0.5))
        action.waypoints=[.init(x:0.1,y:0.5)]
        for id in ["video.game","video.cartoon"] {
            XCTAssertThrowsError(try PluginInputCompatibility.requireStorySupport(storyActions:[action],gameWorld:nil,cartoonRig:nil,pluginID:id,inputSchema:7))
            XCTAssertNoThrow(try PluginInputCompatibility.requireStorySupport(storyActions:[action],gameWorld:nil,cartoonRig:nil,pluginID:id,inputSchema:8))
            let old=PluginRPCSchemas.definitions(inputSchemaVersion:7,pluginID:id),new=PluginRPCSchemas.definitions(inputSchemaVersion:8,pluginID:id)
            XCTAssertNil(old["StoryAction"]?.object?["properties"]?.object?["waypoints"])
            XCTAssertNotNil(new["StoryAction"]?.object?["properties"]?.object?["waypoints"])
            XCTAssertNil(old["SceneLayer"]?.object?["properties"]?.object?["texturedPath"])
            XCTAssertNotNil(new["SceneLayer"]?.object?["properties"]?.object?["texturedPath"])
        }
        let old=PluginRPCSchemas.definitions(inputSchemaVersion:7,pluginID:"video.cartoon"),new=PluginRPCSchemas.definitions(inputSchemaVersion:8,pluginID:"video.cartoon")
        XCTAssertNil(old["CartoonPresenter"]?.object?["properties"]?.object?["anchor"])
        XCTAssertNotNil(new["CartoonPresenter"]?.object?["properties"]?.object?["anchor"])
    }
}
