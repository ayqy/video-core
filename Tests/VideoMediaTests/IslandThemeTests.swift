import XCTest
import CoreGraphics
import CoreText
import VideoCore
@testable import VideoMedia

final class IslandThemeTests: XCTestCase {
    func context() throws -> CGContext {
        try XCTUnwrap(CGContext(data:nil,width:960,height:540,bitsPerComponent:8,bytesPerRow:960*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    func testOfficialRoundFaceHasCurrentChineseAndCodeGlyphsWithoutInstallation() throws {
        let font=try IslandTypeface.font(size:32)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String,"ChillRoundF")
        let text="囚徒困境 阿青阿蓝 选择确认取消 两枚还差一枚 total >= 3 { return false; }"
        var characters=Array(text.utf16),glyphs=[CGGlyph](repeating:0,count:text.utf16.count)
        let count=characters.count
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font,&characters,&glyphs,count))
        XCTAssertThrowsError(try IslandTypeface.font(size:0))
        XCTAssertThrowsError(try IslandTypeface.font(size:.nan))
        XCTAssertThrowsError(try IslandTypeface.font(size:4097))
    }

    func testWholeShortAndMultilineTextDrawButOverflowIsRejected() throws {
        let c=try context()
        let rect=CGRect(x:100,y:180,width:420,height:220)
        IslandTheme.drawPopover(in:rect,context:c)
        XCTAssertNoThrow(try IslandTheme.drawText("阿青",in:CGRect(x:120,y:350,width:120,height:40),size:26,context:c))
        let text="若只有阿蓝坦白，阿青判十年，阿蓝获释。"
        let measured=try IslandTheme.measureText(text,width:300,size:26,lineHeight:41.6)
        XCTAssertGreaterThan(measured.height,41)
        XCTAssertNoThrow(try IslandTheme.drawText(text,in:CGRect(x:120,y:200,width:300,height:measured.height+4),
            size:26,lineHeight:41.6,context:c))
        XCTAssertThrowsError(try IslandTheme.drawText(String(repeating:text,count:12),
            in:CGRect(x:120,y:200,width:300,height:60),size:26,lineHeight:41.6,context:c),"不能静默裁掉长台词")
    }

    func testCodeCardKeepsActualLineCountAndRejectsInsufficientSpace() throws {
        let code=CodePresentation(title:"规则",lines:["total = 2","built = total >= 3"],highlights:[])
        let rect=CGRect(x:80,y:180,width:800,height:320)
        let layout=try DataPresentationPainter.islandCodeGeometry(code,rect:rect)
        XCTAssertEqual(layout.rows.count,code.lines.count)
        XCTAssertTrue(layout.rows.allSatisfy {rect.contains($0)})
        XCTAssertFalse(layout.rows[0].intersects(layout.rows[1]))
        XCTAssertGreaterThanOrEqual(layout.text[0].height,40)
        let many=CodePresentation(title:"太多",lines:Array(repeating:"return value",count:20),highlights:[])
        XCTAssertThrowsError(try DataPresentationPainter.islandCodeGeometry(many,rect:rect))
    }

    func testPopoverOutlineIncludesRequestedAnchorAndModalRetainsSoftSilhouette() throws {
        let rect=CGRect(x:100,y:200,width:420,height:150)
        let tail=[CGPoint(x:280,y:200),CGPoint(x:300,y:160),CGPoint(x:320,y:200)]
        let path=IslandTheme.popoverPath(in:rect,tail:tail)
        XCTAssertEqual(path.boundingBoxOfPath.minY,160,accuracy:0.01)
        XCTAssertTrue(path.contains(CGPoint(x:300,y:170)))
        XCTAssertTrue(IslandTheme.panelPath(in:rect).contains(CGPoint(x:rect.midX,y:rect.midY)))
        XCTAssertFalse(IslandTheme.panelPath(in:rect).contains(CGPoint(x:rect.minX,y:rect.minY)))
    }
}
