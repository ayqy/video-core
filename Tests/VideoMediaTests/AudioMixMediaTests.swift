import XCTest
import AVFoundation
import VideoCore
@testable import VideoMedia

final class AudioMixMediaTests:XCTestCase {
    private func tone(_ url:URL,seconds:Double,frequency:Double)throws {
        let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:48000,channels:1))
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4800))
        let file=try AVAudioFile(forWriting:url,settings:format.settings)
        let total=Int(seconds*48000)
        for start in stride(from:0,to:total,by:4800) {
            let count=min(4800,total-start);buffer.frameLength=AVAudioFrameCount(count)
            for i in 0..<count {buffer.floatChannelData![0][i]=Float(0.12*sin(2 * .pi * frequency*Double(start+i)/48000))}
            try file.write(from:buffer)
        }
    }
    private func decodedMono(_ url:URL)async throws->[Double] {
        let asset=AVURLAsset(url:url)
        let tracks=try await asset.loadTracks(withMediaType:.audio)
        let track=try XCTUnwrap(tracks.first)
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false])
        reader.add(output);XCTAssertTrue(reader.startReading())
        var result:[Double]=[]
        while let buffer=output.copyNextSampleBuffer() {
            guard let block=CMSampleBufferGetDataBuffer(buffer)else{continue}
            let bytes=CMBlockBufferGetDataLength(block)
            var values=[Float](repeating:0,count:bytes/4)
            let status=values.withUnsafeMutableBytes{CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:bytes,destination:$0.baseAddress!)}
            XCTAssertEqual(status,kCMBlockBufferNoErr)
            for i in stride(from:0,to:values.count,by:2){result.append((Double(values[i])+Double(values[i+1]))/2)}
        }
        XCTAssertEqual(reader.status,.completed);return result
    }
    private func amplitude(_ values:[Double],from:Double,to:Double,frequency:Double)throws->Double {
        let lower=Int(from*48000),upper=Int(to*48000)
        guard lower>=0,upper<=values.count,upper>lower else{throw VideoError.invalid("隔离音频检查窗口超出解码范围")}
        var s=0.0,c=0.0
        for i in lower..<upper {let phase=2 * .pi * frequency*Double(i)/48000;s += values[i]*sin(phase);c += values[i]*cos(phase)}
        return 2*sqrt(s*s+c*c)/Double(upper-lower)
    }
    func testActualAACDucksOnlyDuringVoiceRestoresMusicAndMutesWholeScene()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("actual-mix-rules-"+Codec.id())
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let voiceFile=root.appendingPathComponent("voice.caf"),musicFile=root.appendingPathComponent("music.caf")
        try tone(voiceFile,seconds:1,frequency:997);try tone(musicFile,seconds:4,frequency:400)
        let repo=try Repository(root:root.appendingPathComponent("workspace"))
        let voice=try repo.ingest(Data(contentsOf:voiceFile),name:"isolated-voice.caf",workspaceID:"w",mediaType:"audio",durationFrames:30)
        let music=try repo.ingest(Data(contentsOf:musicFile),name:"isolated-music.caf",workspaceID:"w",mediaType:"audio",durationFrames:120)
        var spoken=VideoCore.Scene(title:"真实混音检查",body:"这只是隔离媒体规则，不是成品配音。",narration:"测试口播",durationFrames:90)
        spoken.voice=VoiceTake(assetID:voice.id,textDigest:try spoken.speechDigest(),durationFrames:30,method:"isolated_test_tone")
        spoken.voiceGain=0.2;spoken.musicGain=0.5
        var muted=VideoCore.Scene(title:"明确静音",body:"全轨静音窗口。",durationFrames:30);muted.muted=true;muted.musicGain=0.5
        var revision=try Planner.create(workspaceID:"w",name:"声音适配规则",aspect:.landscape,scenes:[spoken,muted])
        revision.musicAssetID=music.id
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[voice,music],evidence:[])
        try repo.transaction {db in var w=Workspace(name:"媒体规则隔离区",owner:"rules");w.id="w";db.workspaces=[w];db.assets=[voice,music];db.projects=[Project(workspaceID:"w",name:"声音规则",revision:revision)]}
        let rendered=try await MediaRenderer().render(revision:revision,repository:repo,output:root.appendingPathComponent("output"))
        let artifact=try XCTUnwrap(rendered.artifacts.first{$0.mime=="video/mp4"})
        let samples=try await decodedMono(URL(fileURLWithPath:artifact.path))
        let duck=try amplitude(samples,from:0.2,to:0.7,frequency:400)
        let recovered=try amplitude(samples,from:1.5,to:2.5,frequency:400)
        XCTAssertGreaterThan(duck,0.009)
        XCTAssertGreaterThan(recovered,duck*2.5)
        XCTAssertLessThan(recovered,0.08)
        let quiet=try amplitude(samples,from:3.2,to:3.8,frequency:400)
        XCTAssertLessThan(quiet,0.001,"镜头静音必须同时关闭背景音乐")
        XCTAssertEqual(rendered.artifacts.count,4)
        XCTAssertFalse(revision.review.sound,"真实混音检测不能代替人工听审")
    }

    func testMusicOnlyWarningMatchesDecodedAACIncludingMutedAndZeroGain()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("music-warning-rules-"+Codec.id())
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source.caf")
        try tone(source,seconds:1,frequency:400)
        let cases:[(name:String,linked:Bool,muted:Bool,gain:Double,audible:Bool)]=[
            ("music-only",true,false,0.5,true),
            ("muted-music",true,true,0.5,false),
            ("zero-gain",true,false,0,false),
            ("no-audio",false,false,0.5,false)
        ]
        for item in cases {
            let repo=try Repository(root:root.appendingPathComponent(item.name))
            let music=try repo.ingest(Data(contentsOf:source),name:"isolated-tone.caf",workspaceID:"w",mediaType:"audio",durationFrames:30)
            var scene=VideoCore.Scene(title:"真实声音提示检查",body:"隔离媒体规则，非成品配音。",durationFrames:30)
            scene.musicGain=item.gain;scene.muted=item.muted
            var revision=try Planner.create(workspaceID:"w",name:item.name,aspect:.landscape,scenes:[scene])
            if item.linked{revision.musicAssetID=music.id}
            revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[music],evidence:[])
            try repo.transaction {db in
                var workspace=Workspace(name:"隔离声音规则",owner:"rules");workspace.id="w"
                db.workspaces=[workspace];db.assets=[music]
                db.projects=[Project(workspaceID:"w",name:item.name,revision:revision)]
            }
            let rendered=try await MediaRenderer().render(revision:revision,repository:repo,output:repo.root.appendingPathComponent("output"))
            let artifact=try XCTUnwrap(rendered.artifacts.first{$0.mime=="video/mp4"})
            let movie=URL(fileURLWithPath:artifact.path)
            let inspection=try await MediaInspection.inspect(movie)
            XCTAssertEqual(inspection.audioCodec,"aac ",item.name)
            XCTAssertEqual(inspection.sampleRate,48000,item.name)
            let samples=try await decodedMono(movie)
            let measured=try amplitude(samples,from:0.2,to:0.8,frequency:400)
            if item.audible{XCTAssertGreaterThan(measured,0.02,item.name)}
            else{XCTAssertLessThan(measured,0.0005,item.name)}
            XCTAssertEqual(rendered.warnings.contains{$0.contains("静音底轨")},!item.audible,item.name)
            XCTAssertEqual(rendered.artifacts.count,4,item.name)
            XCTAssertFalse(revision.review.sound,"实际声音测量不能代替人工听审")
        }
    }
}
