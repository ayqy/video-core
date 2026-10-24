import Foundation
import PDFKit
import AVFoundation
import ImageIO
import CoreText
import CZlib
import VideoCore

public enum MaterialImporter {
    public static func importFile(_ url:URL,workspaceID:String,repository:Repository) async throws -> Asset {
        let size=(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0; guard size>0,size<=256*1024*1024 else { throw VideoError.invalid("文件为空或超过256MiB；请先裁短媒体") }
        let ext=url.pathExtension.lowercased(); var type="text"; var frames:Int?; var pages:[CoursePage]=[]; var warnings:[String]=[]
        switch ext {
        case "pdf":
            type="pdf"; guard let document=PDFDocument(url:url),!document.isLocked,document.pageCount<=200 else { throw VideoError.invalid("PDF无法读取、已加密或超过200页") }
            for i in 0..<document.pageCount { guard let page=document.page(at:i) else { throw VideoError.invalid("PDF页面损坏") }; let text=page.string ?? ""; pages.append(CoursePage(number:i+1,text:text,requiresOCR:text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)) }; if pages.contains(where:{$0.requiresOCR}) { warnings.append("部分页面为扫描图，请执行OCR或人工录入并逐页核对") }
        case "pptx":
            type="slides"; guard size<=64*1024*1024 else { throw VideoError.invalid("PPTX超过64MiB，请移除无关大媒体") }; let zip=try BoundedZIP(Data(contentsOf:url))
            guard !zip.names.contains(where:{$0.lowercased().contains("vbaproject") || $0.lowercased().contains("externallinks")}) else { throw VideoError.permission("拒绝含宏或外部自动链接的演示文稿") }
            let slides=try PPTXParts.slides(in:zip)
            let availableFonts=PPTXFeatures.availableFontNames()
            for (i,name) in slides.enumerated() {
                let bytes=try zip.file(name)
                let features=try PPTXFeatures.read(bytes)
                let text=try XMLText.extract(bytes)
                let notes=try PPTXParts.notes(for:name,in:zip)
                warnings.append(features.report(page:i+1,availableFonts:availableFonts))
                pages.append(CoursePage(number:i+1,text:text,notes:notes,requiresOCR:text.isEmpty))
            }; warnings.append("保留原始课件供系统预览；字体、动画与复杂公式不能保证还原，请逐页核对或改用原录屏")
        case "ppt": throw VideoError.unavailable("旧PPT请先用原应用转换为PPTX或PDF；不会把解析失败当空课")
        case "txt","md","srt","csv":
            guard size<=10*1024*1024,let text=String(data:try Data(contentsOf:url),encoding:.utf8) else { throw VideoError.invalid("文本超过10MiB或不是UTF-8编码") }; pages=[CoursePage(number:1,text:text)]
        case "mp4","mov","m4v","wav","caf","mp3","m4a","aac":
            let media=AVURLAsset(url:url); let duration=try await media.load(.duration); guard duration.seconds.isFinite,duration.seconds>0,duration.seconds<=3600 else { throw VideoError.invalid("媒体实长无效或超过一小时") }; frames=Int(ceil(duration.seconds*30)); let video=try await media.loadTracks(withMediaType:.video); let audio=try await media.loadTracks(withMediaType:.audio); guard !video.isEmpty || !audio.isEmpty else { throw VideoError.invalid("媒体没有有效音视频轨") }; type=video.isEmpty ? "audio":"video"; if !video.isEmpty { warnings.append("按实际媒体时间裁切；可变帧率源不会按文件名猜时长") }
        case "png","jpg","jpeg","heic","webp": guard let image=CGImageSourceCreateWithURL(url as CFURL,nil),CGImageSourceGetCount(image)>0 else { throw VideoError.invalid("图片无法解析") }; type="image"
        default: throw VideoError.invalid("支持PDF、PPTX、UTF-8讲稿、常见音视频与图片；拒绝可执行文件")
        }
        var asset=try repository.ingest(Data(contentsOf:url),name:url.lastPathComponent,workspaceID:workspaceID,mediaType:type,durationFrames:frames); asset.pages=pages; asset.warnings=warnings; return asset
    }
}

private final class XMLText:NSObject,XMLParserDelegate {
    var result="", inside=false
    static func extract(_ data:Data) throws -> String { guard data.count<=5*1024*1024 else { throw VideoError.invalid("单页XML过大") }; let delegate=XMLText(); let parser=XMLParser(data:data); parser.shouldResolveExternalEntities=false; parser.delegate=delegate; guard parser.parse() else { throw VideoError.invalid("课件XML损坏") }; return delegate.result.trimmingCharacters(in:.whitespacesAndNewlines) }
    func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) { if elementName=="a:t" || elementName=="t" { inside=true } }
    func parser(_ parser:XMLParser,foundCharacters string:String) { if inside { result += string } }
    func parser(_ parser:XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName:String?) { if elementName=="a:t" || elementName=="t" { inside=false }; if elementName=="a:p" || elementName=="p" { result += "\n" } }
}
/// OPC relationships describe presentation order; directory names do not.
private enum PPTXParts {
    static let presentationNamespaces:Set<String>=["http://schemas.openxmlformats.org/presentationml/2006/main","http://purl.oclc.org/ooxml/presentationml/main"]
    static let officeNamespaces:Set<String>=["http://schemas.openxmlformats.org/officeDocument/2006/relationships","http://purl.oclc.org/ooxml/officeDocument/relationships"]
    static func parse(_ data:Data,delegate:XMLParserDelegate)throws {
        guard data.count<=5*1024*1024,let text=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.utf16),
              text.range(of:"<!DOCTYPE",options:.caseInsensitive)==nil,
              text.range(of:"<!ENTITY",options:.caseInsensitive)==nil else {throw VideoError.invalid("课件XML过大、编码无效或含不支持的实体声明")}
        let parser=XMLParser(data:data);parser.shouldProcessNamespaces=true;parser.shouldReportNamespacePrefixes=true
        parser.shouldResolveExternalEntities=false;parser.delegate=delegate
        guard parser.parse() else{throw VideoError.invalid("课件顺序或关联XML损坏")}
    }
    static func slides(in zip:BoundedZIP)throws->[String] {
        guard Set(zip.names).count==zip.names.count else{throw VideoError.invalid("PPTX含重复部件，无法唯一核对来源")}
        let order=PPTXOrder();try parse(zip.file("ppt/presentation.xml"),delegate:order)
        guard order.validRoot,order.listCount==1,!order.ids.isEmpty,order.ids.count<=200,
              Set(order.ids).count==order.ids.count else{throw VideoError.invalid("PPTX缺少有效页面顺序、页面重复或超过200页")}
        let relations=try PPTXRelations.read(zip.file("ppt/_rels/presentation.xml.rels"))
        var paths:[String]=[]
        for id in order.ids {
            guard let relation=relations.first(where:{$0.id==id}) else{throw VideoError.invalid("PPTX页面顺序引用了缺失关联")}
            let path=try target(relation,kind:"slide",relativeTo:"ppt/presentation.xml",directory:"ppt/slides")
            guard zip.names.contains(path),!paths.contains(path) else{throw VideoError.invalid("PPTX引用的页面缺失或重复")}
            paths.append(path)
        }
        return paths
    }
    static func notes(for slide:String,in zip:BoundedZIP)throws->String {
        let url=slide as NSString
        let relationships=url.deletingLastPathComponent+"/_rels/"+url.lastPathComponent+".rels"
        guard zip.names.contains(relationships) else{return ""}
        let notes=try PPTXRelations.read(zip.file(relationships)).filter{$0.type.hasSuffix("/notesSlide")}
        guard notes.count<=1 else{throw VideoError.invalid("PPTX同页备注关联不唯一")}
        guard let note=notes.first else{return ""}
        let path=try target(note,kind:"notesSlide",relativeTo:slide,directory:"ppt/notesSlides")
        guard zip.names.contains(path) else{throw VideoError.invalid("PPTX备注关联指向缺失文件")}
        let data=try zip.file(path)
        _ = try PPTXFeatures.read(data)
        return try XMLText.extract(data)
    }
    static func target(_ relation:PPTXRelations.Record,kind:String,relativeTo part:String,directory:String)throws->String {
        guard officeNamespaces.contains(where:{relation.type==$0+"/"+kind}),
              relation.mode==nil || relation.mode=="Internal" else{throw VideoError.permission("拒绝外部或不支持的课件页面/备注关联")}
        guard !relation.target.isEmpty,relation.target.utf8.count<=4096,
              let decoded=relation.target.removingPercentEncoding,!decoded.contains("%"),
              !decoded.contains("\\"),!decoded.contains(":"),!decoded.contains("?"),!decoded.contains("#"),
              !decoded.hasPrefix("//"),!decoded.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else{throw VideoError.invalid("课件关联目标不是安全的包内部件")}
        var components=decoded.hasPrefix("/") ? []:part.split(separator:"/").dropLast().map(String.init)
        for segment in decoded.split(separator:"/") {
            if segment=="." {continue}
            if segment==".." {guard !components.isEmpty else{throw VideoError.invalid("课件关联逃出文件包")};components.removeLast()}
            else{components.append(String(segment))}
        }
        let path=components.joined(separator:"/")
        guard components.count==3,components.dropLast().joined(separator:"/")==directory,
              components.last?.lowercased().hasSuffix(".xml")==true else{throw VideoError.invalid("课件关联越出允许的页面/备注目录")}
        return path
    }
}
private final class PPTXOrder:NSObject,XMLParserDelegate {
    var ids:[String]=[],listCount=0,validRoot=false
    var stack:[String]=[],prefixes:[String:[String]]=[:]
    func parser(_ parser:XMLParser,didStartMappingPrefix prefix:String,toURI uri:String){prefixes[prefix,default:[]].append(uri)}
    func parser(_ parser:XMLParser,didEndMappingPrefix prefix:String){_ = prefixes[prefix]?.popLast()}
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        let supported=namespaceURI.map{PPTXParts.presentationNamespaces.contains($0)} ?? false
        if stack.isEmpty{validRoot=supported && name=="presentation"}
        if supported && name=="sldIdLst" && stack==["presentation"]{listCount+=1}
        if supported && name=="sldId" && stack==["presentation","sldIdLst"] {
            let references=attributes.filter { key,_ in
                let pieces=key.split(separator:":",omittingEmptySubsequences:false)
                guard pieces.count==2,pieces[1]=="id",let namespace=prefixes[String(pieces[0])]?.last else{return false}
                return PPTXParts.officeNamespaces.contains(namespace)
            }.map(\.value)
            guard references.count==1,!references[0].isEmpty,ids.count<200 else{parser.abortParsing();return}
            ids.append(references[0])
        }
        stack.append(supported ? name:"#other")
    }
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?){_ = stack.popLast()}
}
private final class PPTXRelations:NSObject,XMLParserDelegate {
    struct Record{var id:String;var type:String;var target:String;var mode:String?}
    var records:[Record]=[],depth=0,validRoot=false
    static func read(_ data:Data)throws->[Record] {
        let delegate=PPTXRelations();try PPTXParts.parse(data,delegate:delegate)
        guard delegate.validRoot,Set(delegate.records.map(\.id)).count==delegate.records.count else{throw VideoError.invalid("课件关联根无效或ID重复")}
        return delegate.records
    }
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        let supported=namespaceURI=="http://schemas.openxmlformats.org/package/2006/relationships"
        if depth==0{validRoot=supported && name=="Relationships"}
        if depth==1 && supported && name=="Relationship" {
            guard let id=attributes["Id"],!id.isEmpty,let type=attributes["Type"],!type.isEmpty,
                  let target=attributes["Target"],!target.isEmpty,records.count<2000 else{parser.abortParsing();return}
            records.append(Record(id:id,type:type,target:target,mode:attributes["TargetMode"]))
        }
        depth+=1
    }
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?){depth-=1}
}
/// A risk report accompanies each actual page; no PowerPoint layout is claimed to be rendered.
private final class PPTXFeatures:NSObject,XMLParserDelegate {
    var fonts:Set<String>=[],themeFonts:Set<String>=[],hasAnimation=false
    static func read(_ data:Data)throws->PPTXFeatures{let result=PPTXFeatures();try PPTXParts.parse(data,delegate:result);return result}
    static func availableFontNames()->Set<String> {
        let collection=CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors=CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        var result:Set<String>=[]
        for descriptor in descriptors {for key in [kCTFontNameAttribute,kCTFontFamilyNameAttribute,kCTFontDisplayNameAttribute] {
            if let value=CTFontDescriptorCopyAttribute(descriptor,key) as? String{result.insert(value.lowercased())}
        }}
        return result
    }
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        if namespaceURI.map({PPTXParts.presentationNamespaces.contains($0)})==true,
           ["timing","transition","anim","animEffect","animMotion","animRot","animScale"].contains(name){hasAnimation=true}
        if namespaceURI=="http://schemas.openxmlformats.org/drawingml/2006/main" || namespaceURI=="http://purl.oclc.org/ooxml/drawingml/main",
           ["latin","ea","cs"].contains(name),let raw=attributes["typeface"] {
            let font=raw.trimmingCharacters(in:.whitespacesAndNewlines)
            guard font.utf8.count<=512,fonts.count+themeFonts.count<256 else{parser.abortParsing();return}
            if font.hasPrefix("+"){themeFonts.insert(font)}else if !font.isEmpty{fonts.insert(font)}
        }
    }
    func report(page:Int,availableFonts:Set<String>)->String {
        var details=["第\(page)页预览差异风险：已提取文字与备注，版式和公式未完整渲染"]
        let missing=fonts.filter{!availableFonts.contains($0.lowercased())}.sorted()
        if !missing.isEmpty{details.append("本机缺少显式字体："+missing.joined(separator:"、"))}
        if !themeFonts.isEmpty{details.append("主题字体需由原应用解析："+themeFonts.sorted().joined(separator:"、"))}
        if hasAnimation{details.append("检测到动画或切换，文本解析未还原时序与效果")}
        details.append("请对照原课件预览；有差异可换原应用导出的PDF或原录屏")
        return details.joined(separator:"；")
    }
}

/// Limited ZIP reader: no extraction, path execution, macros, encryption or unbounded inflation.
struct BoundedZIP {
    struct Entry { var name:String; var method:Int; var compressed:Int; var expanded:Int; var offset:Int; var crc:UInt32 }
    let data:Data; var entries:[Entry]=[]; var names:[String]{entries.map(\.name)}
    init(_ input:Data) throws {
        data=input; guard data.count>=22 else { throw VideoError.invalid("PPTX不是有效ZIP") }
        func u16(_ i:Int)->Int { Int(input[i])|Int(input[i+1])<<8 }; func u32(_ i:Int)->Int { u16(i)|u16(i+2)<<16 }
        var end:Int?; for i in stride(from:data.count-22,through:max(0,data.count-65557),by:-1) { if u32(i)==0x06054b50 { end=i; break } }; guard let end else { throw VideoError.invalid("PPTX目录缺失") }
        let count=u16(end+10); guard count>0,count<=2000,u16(end+4)==0,u16(end+6)==0 else { throw VideoError.invalid("PPTX文件数超限或使用不支持的分卷") }
        var at=u32(end+16),total=0
        for _ in 0..<count { guard at>=0,at+46<=data.count,u32(at)==0x02014b50 else { throw VideoError.invalid("PPTX目录损坏") }; let flags=u16(at+8),method=u16(at+10),compressed=u32(at+20),expanded=u32(at+24),n=u16(at+28),extra=u16(at+30),comment=u16(at+32),local=u32(at+42); guard at+46+n+extra+comment<=data.count,let name=String(data:data.subdata(in:at+46..<at+46+n),encoding:.utf8),!name.hasPrefix("/"),!name.contains(".."),!name.contains("\\"),flags&1==0,[0,8].contains(method),expanded<=20*1024*1024,expanded<=max(1,compressed)*1000 else { throw VideoError.invalid("PPTX含不安全路径、加密或异常解压比") }; total+=expanded; guard total<=256*1024*1024 else { throw VideoError.invalid("PPTX解压总量超过256MiB") }; entries.append(Entry(name:name,method:method,compressed:compressed,expanded:expanded,offset:local,crc:UInt32(u32(at+16)))); at+=46+n+extra+comment }
    }
    func file(_ name:String) throws -> Data {
        guard let e=entries.first(where:{$0.name==name}),e.offset>=0,e.offset+30<=data.count else { throw VideoError.invalid("课件文件缺失") }
        func u16(_ i:Int)->Int { Int(data[i])|Int(data[i+1])<<8 }; guard data[e.offset]==0x50,data[e.offset+1]==0x4b,data[e.offset+2]==0x03,data[e.offset+3]==0x04 else { throw VideoError.invalid("ZIP本地头损坏") }
        let start=e.offset+30+u16(e.offset+26)+u16(e.offset+28); guard start<=data.count,e.compressed<=data.count-start else { throw VideoError.invalid("ZIP数据范围越界") }; let compressed=data.subdata(in:start..<start+e.compressed); let result:Data
        if e.method==0 { result=compressed } else {
            var stream=z_stream(); let initCode=inflateInit2_(&stream,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)); guard initCode==Z_OK else { throw VideoError.unavailable("解压器不可用") }; defer { inflateEnd(&stream) }; var expanded=Data(count:max(e.expanded,1))
            let status=compressed.withUnsafeBytes { src in expanded.withUnsafeMutableBytes { dst -> Int32 in stream.next_in=UnsafeMutablePointer(mutating:src.bindMemory(to:Bytef.self).baseAddress); stream.avail_in=uInt(compressed.count); stream.next_out=dst.bindMemory(to:Bytef.self).baseAddress; stream.avail_out=uInt(dst.count); return inflate(&stream,Z_FINISH) } }; guard status==Z_STREAM_END,Int(stream.total_out)==e.expanded else { throw VideoError.invalid("PPTX压缩数据损坏") }; result=expanded.prefix(e.expanded)
        }
        let crc=result.withUnsafeBytes { crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt($0.count)) }; guard UInt32(crc)==e.crc else { throw VideoError.invalid("PPTX完整性校验失败") }; return result
    }
}
