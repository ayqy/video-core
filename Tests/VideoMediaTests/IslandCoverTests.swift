import XCTest
import CoreGraphics
import CoreText
@testable import VideoMedia
import VideoCore

final class IslandCoverTests:XCTestCase {
    func testCommunityBoardUsesCompleteTransparentOfflineOriginal()throws {
        let image=try CommunityNoticeBoardArtwork.image()
        XCTAssertEqual(image.width,1672);XCTAssertEqual(image.height,941)
        XCTAssertTrue([CGImageAlphaInfo.last,.first,.premultipliedLast,.premultipliedFirst].contains(image.alphaInfo))
        XCTAssertEqual(CommunityNoticeBoardArtwork.sha256,"ee4831de0254aae28c7d3b6ac1affc097b52c73555c502f54df903f9ec0df4ae")
    }
    func testCommunityPaperContainsWholeCenteredHeadlineInEveryTemplate()throws {
        for dimensions in [(1280.0,720.0),(720.0,1280.0)] {
            let canvas=CGRect(x:0,y:0,width:dimensions.0,height:dimensions.1)
            let side=min(canvas.width,canvas.height)
            let square=CGRect(x:canvas.midX-side/2,y:canvas.midY-side/2,width:side,height:side)
            let title=CGRect(x:canvas.midX-210,y:canvas.midY-38,width:420,height:76)
            for variant in 0...2 {
                let paper=CoverPainter.gameDialogueBubble(square:square,canvas:canvas,variant:variant,titleBounds:title)
                let backing=CoverPainter.gameNoticeBoardFrame(square:square,canvas:canvas,variant:variant,titleBounds:title)
                XCTAssertTrue(paper.contains(title));XCTAssertTrue(backing.contains(paper))
                XCTAssertTrue(canvas.contains(backing));XCTAssertEqual(paper.midX,title.midX,accuracy:0.001)
                XCTAssertEqual(paper.midY,title.midY,accuracy:0.001)
                XCTAssertGreaterThan(paper.height,side*0.25)
                for headline in ["囚徒困境","豆子姐讲囚徒困境","合作还是背叛？"] {
                    var revision=try Planner.create(workspaceID:"w",name:headline,
                        aspect:canvas.width>canvas.height ? .landscape:.portrait,
                        scenes:[Scene(title:"选择",body:"观察选择",durationFrames:30)])
                    revision.coverPresentation=CoverPresentation(style:.game,
                        template:[CoverTemplate.spotlight,.editorial,.contrast][variant],
                        title:headline,emphasis:[headline.contains("囚徒困境") ? "囚徒困境":"背叛"])
                    let actual=try CoverPainter.composeTitle(cover:CoverRules.resolved(revision:revision),width:canvas.width,height:canvas.height)
                    let full=CoverPainter.gameNoticeBoardImageFrame(square:square,canvas:canvas,variant:variant,titleBounds:actual.visibleBounds)
                    XCTAssertTrue(canvas.contains(full),"完整社区公告栏不能被画幅裁断")
                }
            }
        }
    }
}
