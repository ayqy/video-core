import Foundation
import AVFoundation
import CoreText
import VideoCore

public struct DiagnosticItem: Identifiable, Sendable {
    public enum State: String, Sendable { case passed="通过", warning="需留意", failed="需修复", optional="可跳过" }
    public var id:String; public var title:String; public var state:State; public var detail:String;public var action:String
}
public enum Diagnostics {
    @MainActor public static func inspect(repository:Repository?,providers:[ProviderProfile]) -> [DiagnosticItem] {
        var items:[DiagnosticItem]=[]
        if let repo=repository {
            let probe=repo.root.appendingPathComponent("cache/doctor-"+Codec.id())
            do { try FileManager.default.createDirectory(at:probe.deletingLastPathComponent(),withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:probe)};let data=Data("知幕本地读写自检".utf8);try data.write(to:probe,options:.atomic);guard try Data(contentsOf:probe)==data else {throw VideoError.invalid("读写不一致")};_ = try repo.read();items.append(.init(id:"storage",title:"工程读写",state:.passed,detail:"实际写入、回读及SQLite读取成功",action:"")) }
            catch { items.append(.init(id:"storage",title:"工程读写",state:.failed,detail:"无法读写当前工程，原数据保留",action:"检查可用空间；在设置从备份恢复到新目录")) }
            if let attrs=try? FileManager.default.attributesOfFileSystem(forPath:repo.root.path),let free=attrs[.systemFreeSize] as? NSNumber {
                items.append(.init(id:"space",title:"可用空间",state:free.int64Value<512*1024*1024 ? .failed:free.int64Value<2*1024*1024*1024 ? .warning:.passed,detail:ByteCountFormatter.string(fromByteCount:free.int64Value,countStyle:.file),action:"空间不足时只清可重建缓存；源素材和历史成片须先备份"))
            } else { items.append(.init(id:"space",title:"可用空间",state:.warning,detail:"系统未提供可用空间值",action:"在系统设置核对设备存储")) }
        } else { items.append(.init(id:"storage",title:"工程读写",state:.failed,detail:"当前工程不可用",action:"在设置校验备份并恢复到新目录")) }
        let font=CTFontCreateWithName("PingFangSC-Medium" as CFString,32,nil),chars=Array("知识价格字幕旁白课程".utf16);var glyphs=Array(repeating:CGGlyph(0),count:chars.count)
        let chinese=CTFontGetGlyphsForCharacters(font,chars,&glyphs,chars.count) && glyphs.allSatisfy{$0 != 0}
        items.append(.init(id:"font",title:"中文字体",state:chinese ? .passed:.failed,detail:chinese ? "实际查询的中文字符均有字形":"系统字体缺少所需中文字形",action:chinese ? "":"检查系统字体与语言组件后重试"))
        let video:[String:Any]=[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:720,AVVideoHeightKey:1280]
        let audio:[String:Any]=[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2]
        let codecs=AVAssetWriterInput(mediaType:.video,outputSettings:video).mediaType == .video && AVAssetWriterInput(mediaType:.audio,outputSettings:audio).mediaType == .audio
        items.append(.init(id:"codec",title:"本机编码配置",state:codecs ? .passed:.failed,detail:"H.264 720p 与 AAC48kHz 输入配置已建立；成片仍需逐次实际解码核验",action:""))
        let voices=SpeechService.voices()
        items.append(.init(id:"speech",title:"本机中文配音",state:voices.isEmpty ? .optional:.passed,detail:voices.isEmpty ? "未发现中文声音，可导入自备授权音频":"实际可用中文声音 \(voices.count) 个",action:voices.isEmpty ? "到系统朗读设置下载中文声音后刷新，或跳过自动配音":""))
        if providers.isEmpty { items.append(.init(id:"provider",title:"付费生成服务",state:.optional,detail:"未配置；基础本地制作不依赖它",action:"有需要时在生成服务中自行绑定账户与报价")) }
        for p in providers {
            do { try p.validate();let key=SecureCredentials.contains(p.keyReference);items.append(.init(id:p.id,title:p.name,state:key ? .warning:.failed,detail:key ? "本地配置和凭据引用可用；未调用远端，不代表官方服务可用或价格有效":"未找到系统凭据引用",action:key ? "首次实际调用前核对官方能力、价格、上传范围和预算":"在当前设备重新绑定凭据")) }
            catch { items.append(.init(id:p.id,title:p.name,state:.failed,detail:"服务配置未通过本地校验",action:"检查HTTPS端点、准确模型ID和参数声明")) }
        }
        return items
    }
}
