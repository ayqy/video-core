import XCTest
import Foundation
import CoreText
import VideoCore
import VideoMedia

final class MaterialImporterTests:XCTestCase {
    func testPresentationOrderAndNotesSurviveRearrangementWithoutImportingOrphans()async throws {
        let directory=try temporaryDirectory();defer{try? FileManager.default.removeItem(at:directory)}
        let repository=try Repository(root:directory.appendingPathComponent("workspace"))
        var parts=fixture()
        // The author moved physical slide 2 before slide 1. Its notes deliberately
        // have a different part name; neither filename sorting nor number matching works.
        parts["ppt/slides/slide9.xml"]=slide("Unused deleted-page remnant")
        let original=archive(parts),source=directory.appendingPathComponent("rearranged.pptx")
        try original.write(to:source)
        let asset=try await MaterialImporter.importFile(source,workspaceID:"course",repository:repository)
        XCTAssertEqual(asset.pages.map(\.number),[1,2])
        XCTAssertEqual(asset.pages.map(\.text),["Second physical slide, first teaching step","First physical slide, second teaching step"])
        XCTAssertEqual(asset.pages.map(\.notes),["Speaker note belonging to step one","Speaker note belonging to step two"])
        XCTAssertTrue(asset.pages.allSatisfy{!$0.confirmed && !$0.requiresOCR})
        XCTAssertEqual(asset.workspaceID,"course")
        XCTAssertEqual(asset.hash,Codec.hash(original))
        XCTAssertEqual(try Data(contentsOf:repository.assetURL(asset)),original)
    }

    func testMissingOrAmbiguousPresentationOrderIsRejectedInsteadOfInventingPages()async throws {
        let base=fixture()
        var cases:[[String:String]]=[]
        var missing=base;missing.removeValue(forKey:"ppt/presentation.xml");cases.append(missing)
        var empty=base;empty["ppt/presentation.xml"]=presentation([]);cases.append(empty)
        var duplicateOrder=base;duplicateOrder["ppt/presentation.xml"]=presentation(["second","second"]);cases.append(duplicateOrder)
        var missingID=base;missingID["ppt/presentation.xml"]=presentation(["not-in-relationships"]);cases.append(missingID)
        var duplicateID=base;duplicateID["ppt/_rels/presentation.xml.rels"]=relationships([
            relation("second",type:"slide",target:"slides/slide2.xml"),relation("second",type:"slide",target:"slides/slide1.xml")]);cases.append(duplicateID)
        var duplicateTarget=base;duplicateTarget["ppt/_rels/presentation.xml.rels"]=relationships([
            relation("second",type:"slide",target:"slides/slide2.xml"),relation("first",type:"slide",target:"slides/slide2.xml")]);cases.append(duplicateTarget)
        var missingTarget=base;missingTarget.removeValue(forKey:"ppt/slides/slide2.xml");cases.append(missingTarget)
        for (index,parts) in cases.enumerated(){try await assertRejected(archive(parts),label:"order-\(index)")}
    }

    func testExternalEscapingAndBrokenNotesRelationshipsNeverIngestAnAuthorizedLookingAsset()async throws {
        let base=fixture()
        var cases:[[String:String]]=[]
        for row in [
            relation("second",type:"slide",target:"https://example.invalid/slide.xml",mode:"External"),
            relation("second",type:"slide",target:"../../../outside.xml"),
            relation("second",type:"slide",target:"slides/%2e%2e/%2e%2e/outside.xml"),
            relation("second",type:"notesSlide",target:"slides/slide2.xml")
        ] {
            var parts=base;parts["ppt/_rels/presentation.xml.rels"]=relationships([row,relation("first",type:"slide",target:"slides/slide1.xml")]);cases.append(parts)
        }
        for rows in [
            [relation("notes",type:"notesSlide",target:"https://example.invalid/notes.xml",mode:"External")],
            [relation("notes",type:"notesSlide",target:"../../../outside.xml")],
            [relation("notes",type:"notesSlide",target:"../notesSlides/missing.xml")],
            [relation("notes",type:"notesSlide",target:"../notesSlides/first-note.xml"),relation("other",type:"notesSlide",target:"../notesSlides/second-note.xml")]
        ] {
            var parts=base;parts["ppt/slides/_rels/slide2.xml.rels"]=relationships(rows);cases.append(parts)
        }
        for (index,parts) in cases.enumerated(){try await assertRejected(archive(parts),label:"unsafe-\(index)")}
        var duplicateParts=base.sorted{$0.key<$1.key}.map{($0.key,$0.value)}
        duplicateParts.append(("ppt/slides/slide2.xml",slide("Ambiguous same-path replacement")))
        try await assertRejected(archiveEntries(duplicateParts),label:"duplicate-package-part")
    }

    func testPageSpecificPreviewRisksDistinguishMissingFontsThemesAndAnimation()async throws {
        let directory=try temporaryDirectory();defer{try? FileManager.default.removeItem(at:directory)}
        let repository=try Repository(root:directory.appendingPathComponent("workspace"))
        let names=CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []
        let available=try XCTUnwrap(names.first)
        let missing="FF1480-Missing-Typeface-For-Material-Import"
        XCTAssertFalse(names.contains(missing))
        var parts=fixture()
        parts["ppt/slides/slide2.xml"]=slide("Step with animated handoff",font:missing,animation:true)
        parts["ppt/slides/slide1.xml"]=slide("Step with theme and installed fonts",font:available,extraFont:"+mj-lt")
        let source=directory.appendingPathComponent("preview-risks.pptx");try archive(parts).write(to:source)
        let asset=try await MaterialImporter.importFile(source,workspaceID:"course",repository:repository)
        let pageOne=try XCTUnwrap(asset.warnings.first{$0.hasPrefix("第1页")})
        let pageTwo=try XCTUnwrap(asset.warnings.first{$0.hasPrefix("第2页")})
        XCTAssertTrue(pageOne.contains(missing));XCTAssertTrue(pageOne.contains("动画或切换"))
        XCTAssertFalse(pageTwo.contains("本机缺少显式字体"));XCTAssertFalse(pageTwo.contains("检测到动画"))
        XCTAssertTrue(pageTwo.contains("主题字体需由原应用解析：+mj-lt"))
        XCTAssertTrue(asset.warnings.allSatisfy{!$0.hasPrefix("第") || ($0.contains("未完整渲染") && $0.contains("原录屏"))})
        XCTAssertTrue(asset.pages.allSatisfy{!$0.confirmed})
    }

    private let presentationNamespace="http://schemas.openxmlformats.org/presentationml/2006/main"
    private let drawingNamespace="http://schemas.openxmlformats.org/drawingml/2006/main"
    private let officeNamespace="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private func presentation(_ ids:[String])->String {
        "<p:presentation xmlns:p=\"\(presentationNamespace)\" xmlns:rel=\"\(officeNamespace)\"><p:sldIdLst>" +
        ids.enumerated().map{"<p:sldId id=\"\(256+$0.offset)\" rel:id=\"\($0.element)\"/>"}.joined() +
        "</p:sldIdLst></p:presentation>"
    }
    private func relation(_ id:String,type:String,target:String,mode:String?=nil)->String {
        "<Relationship Id=\"\(id)\" Type=\"\(officeNamespace)/\(type)\" Target=\"\(target)\"" +
        (mode.map{" TargetMode=\"\($0)\""} ?? "")+"/>"
    }
    private func relationships(_ records:[String])->String {
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"+records.joined()+"</Relationships>"
    }
    private func slide(_ text:String,font:String?=nil,extraFont:String?=nil,animation:Bool=false)->String {
        let fonts=(font.map{"<a:latin typeface=\"\($0)\"/>"} ?? "")+(extraFont.map{"<a:ea typeface=\"\($0)\"/>"} ?? "")
        return "<p:sld xmlns:p=\"\(presentationNamespace)\" xmlns:a=\"\(drawingNamespace)\"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:rPr>" +
        fonts+"</a:rPr><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>" +
        (animation ? "<p:timing><p:tnLst><p:par><p:cTn id=\"1\" dur=\"indefinite\"/></p:par></p:tnLst></p:timing><p:transition><p:fade/></p:transition>":"")+"</p:sld>"
    }
    private func note(_ text:String)->String {
        "<p:notes xmlns:p=\"\(presentationNamespace)\" xmlns:a=\"\(drawingNamespace)\"><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:notes>"
    }
    private func fixture()->[String:String] {
        ["[Content_Types].xml":"<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/></Types>",
         "_rels/.rels":relationships([relation("document",type:"officeDocument",target:"ppt/presentation.xml")]),
         "ppt/presentation.xml":presentation(["second","first"]),
         "ppt/_rels/presentation.xml.rels":relationships([relation("first",type:"slide",target:"slides/slide1.xml"),relation("second",type:"slide",target:"slides/slide2.xml")]),
         "ppt/slides/slide1.xml":slide("First physical slide, second teaching step"),
         "ppt/slides/slide2.xml":slide("Second physical slide, first teaching step"),
         "ppt/slides/_rels/slide1.xml.rels":relationships([relation("notes",type:"notesSlide",target:"../notesSlides/second-note.xml")]),
         "ppt/slides/_rels/slide2.xml.rels":relationships([relation("notes",type:"notesSlide",target:"../notesSlides/first-note.xml")]),
         "ppt/notesSlides/first-note.xml":note("Speaker note belonging to step one"),
         "ppt/notesSlides/second-note.xml":note("Speaker note belonging to step two")]
    }
    private func temporaryDirectory()throws->URL {
        let result=FileManager.default.temporaryDirectory.appendingPathComponent("material-import-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:result,withIntermediateDirectories:true)
        return result
    }
    private func assertRejected(_ data:Data,label:String)async throws {
        let directory=try temporaryDirectory();defer{try? FileManager.default.removeItem(at:directory)}
        let repository=try Repository(root:directory.appendingPathComponent("workspace"))
        let source=directory.appendingPathComponent(label+".pptx");try data.write(to:source)
        do{_ = try await MaterialImporter.importFile(source,workspaceID:"course",repository:repository);XCTFail("Invalid source was ingested: "+label)}
        catch{XCTAssertNotNil(error as? VideoError,label)}
        let assets=repository.root.appendingPathComponent("assets")
        let files=(try? FileManager.default.contentsOfDirectory(at:assets,includingPropertiesForKeys:nil)) ?? []
        XCTAssertTrue(files.isEmpty,"Rejected metadata must not produce a source asset: "+label)
    }
    // Independent stored-entry ZIP fixture writer. Production reads these archive
    // bytes through the public importer, including central-directory and CRC checks.
    private func archive(_ parts:[String:String])->Data{archiveEntries(parts.sorted{$0.key<$1.key}.map{($0.key,$0.value)})}
    private func archiveEntries(_ entries:[(String,String)])->Data {
        var result=Data(),directory=Data()
        func integer(_ value:UInt32,_ count:Int)->Data{Data((0..<count).map{UInt8(truncatingIfNeeded:value >> ($0*8))})}
        func crc(_ data:Data)->UInt32 {
            var value:UInt32=0xffffffff
            for byte in data{value ^= UInt32(byte);for _ in 0..<8{value=(value >> 1) ^ (value & 1 == 0 ? 0:0xedb88320)}}
            return value ^ 0xffffffff
        }
        for (name,text) in entries {
            let filename=Data(name.utf8),body=Data(text.utf8),checksum=crc(body),offset=UInt32(result.count)
            result.append(integer(0x04034b50,4));result.append(integer(20,2));result.append(integer(0,2));result.append(integer(0,2));result.append(integer(0,4))
            result.append(integer(checksum,4));result.append(integer(UInt32(body.count),4));result.append(integer(UInt32(body.count),4));result.append(integer(UInt32(filename.count),2));result.append(integer(0,2));result.append(filename);result.append(body)
            directory.append(integer(0x02014b50,4));directory.append(integer(20,2));directory.append(integer(20,2));directory.append(integer(0,2));directory.append(integer(0,2));directory.append(integer(0,4))
            directory.append(integer(checksum,4));directory.append(integer(UInt32(body.count),4));directory.append(integer(UInt32(body.count),4));directory.append(integer(UInt32(filename.count),2));directory.append(integer(0,2));directory.append(integer(0,2));directory.append(integer(0,2));directory.append(integer(0,2));directory.append(integer(0,4));directory.append(integer(offset,4));directory.append(filename)
        }
        let offset=UInt32(result.count);result.append(directory)
        result.append(integer(0x06054b50,4));result.append(integer(0,4));result.append(integer(UInt32(entries.count),2));result.append(integer(UInt32(entries.count),2));result.append(integer(UInt32(directory.count),4));result.append(integer(offset,4));result.append(integer(0,2))
        return result
    }
}
