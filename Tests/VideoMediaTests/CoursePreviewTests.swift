import XCTest
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import VideoCore
import VideoMedia

final class CoursePreviewTests: XCTestCase {
    func testScannedPDFThumbnailAndLocalOCRRemainUnconfirmed() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("course-ocr-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let repository=try Repository(root:root)
        let original=try scannedPDF()
        var asset=try repository.ingest(original,name:"scan.pdf",workspaceID:"w",mediaType:"pdf")
        asset.pages=[CoursePage(number:1,text:"",requiresOCR:true)]
        let imageData=try await CoursePreview.thumbnail(asset:asset,pageNumber:1,repository:repository)
        let source=try XCTUnwrap(CGImageSourceCreateWithData(imageData as CFData,nil))
        let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        XCTAssertEqual(image.width,900);XCTAssertEqual(image.height,600)
        let draft=try await CoursePreview.recognizePage(asset:asset,pageNumber:1,repository:repository)
        XCTAssertTrue(draft.text.uppercased().contains("COURSE"),draft.text)
        XCTAssertEqual(draft.sourceHash,asset.hash);XCTAssertEqual(draft.pageNumber,1)
        XCTAssertGreaterThan(draft.observationCount,0);XCTAssertGreaterThan(draft.minimumConfidence,0)
        XCTAssertFalse(asset.pages[0].confirmed);XCTAssertTrue(asset.pages[0].text.isEmpty)
        XCTAssertEqual(Codec.hash(try Data(contentsOf:repository.assetURL(asset))),asset.hash)
    }
    func testPreviewRejectsHashMismatchAndOutOfRangePage() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("course-ocr-invalid-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let repository=try Repository(root:root)
        let asset=try repository.ingest(scannedPDF(),name:"scan.pdf",workspaceID:"w",mediaType:"pdf")
        do { _=try await CoursePreview.thumbnail(asset:asset,pageNumber:2,repository:repository);XCTFail("越界页不得成功") } catch { XCTAssertTrue(error.localizedDescription.contains("页码")) }
        try Data("changed".utf8).write(to:repository.assetURL(asset))
        do { _=try await CoursePreview.recognizePage(asset:asset,pageNumber:1,repository:repository);XCTFail("哈希不符不得识别") } catch { XCTAssertTrue(error.localizedDescription.contains("哈希")) }
    }
    private func scannedPDF() throws -> Data {
        let width=1200,height=800
        let imageContext=try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        imageContext.setFillColor(CGColor(gray:1,alpha:1));imageContext.fill(CGRect(x:0,y:0,width:width,height:height))
        let font=CTFontCreateWithName("Helvetica-Bold" as CFString,110,nil)
        let label=NSAttributedString(string:"COURSE 27",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)])
        imageContext.textPosition=CGPoint(x:140,y:400);CTLineDraw(CTLineCreateWithAttributedString(label),imageContext)
        let raster=try XCTUnwrap(imageContext.makeImage())
        let result=NSMutableData();let consumer=try XCTUnwrap(CGDataConsumer(data:result as CFMutableData))
        var box=CGRect(x:0,y:0,width:width,height:height)
        let pdf=try XCTUnwrap(CGContext(consumer:consumer,mediaBox:&box,nil));pdf.beginPDFPage(nil);pdf.draw(raster,in:box);pdf.endPDFPage();pdf.closePDF()
        // The label was rasterized before embedding, so extraction alone cannot satisfy this test.
        let document=try XCTUnwrap(PDFDocument(data:result as Data))
        XCTAssertTrue((document.page(at:0)?.string ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
        return result as Data
    }
}
