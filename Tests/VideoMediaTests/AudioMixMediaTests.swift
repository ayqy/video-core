import XCTest
import AVFoundation
import VideoCore
@testable import VideoMedia

final class AudioMixMediaTests:XCTestCase {
    private func tone(_ url:URL,seconds:Double,frequency:Double,level:Double=0.12,leadFrequency:Double?=nil,leadSeconds:Double=0,sampleRate:Double=48000,channels:AVAudioChannelCount=1,rightFrequency:Double?=nil)throws {
        let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:sampleRate,channels:channels))
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4800))
        let file=try AVAudioFile(forWriting:url,settings:format.settings)
        let total=Int((seconds*sampleRate).rounded())
        for start in stride(from:0,to:total,by:4800) {
            let count=min(4800,total-start);buffer.frameLength=AVAudioFrameCount(count)
            for i in 0..<count {
                let time=Double(start+i)/sampleRate
                let current=time<leadSeconds ? (leadFrequency ?? frequency):frequency
                for channel in 0..<Int(channels) {
                    let channelFrequency=channel==1 ? (rightFrequency ?? current):current
                    buffer.floatChannelData![channel][i]=Float(level*sin(2 * .pi * channelFrequency*time))
                }
            }
            try file.write(from:buffer)
        }
    }
    private func decodedStereo(_ url:URL)async throws->[[Double]] {
        let asset=AVURLAsset(url:url)
        let tracks=try await asset.loadTracks(withMediaType:.audio)
        let track=try XCTUnwrap(tracks.first)
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false])
        reader.add(output);XCTAssertTrue(reader.startReading())
        var result:[[Double]]=[[],[]]
        while let buffer=output.copyNextSampleBuffer() {
            guard let block=CMSampleBufferGetDataBuffer(buffer)else{continue}
            let bytes=CMBlockBufferGetDataLength(block)
            var values=[Float](repeating:0,count:bytes/4)
            let status=values.withUnsafeMutableBytes{CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:bytes,destination:$0.baseAddress!)}
            XCTAssertEqual(status,kCMBlockBufferNoErr)
            for i in stride(from:0,to:values.count,by:2){result[0].append(Double(values[i]));result[1].append(Double(values[i+1]))}
        }
        XCTAssertEqual(reader.status,.completed);return result
    }
    private func decodedMono(_ url:URL)async throws->[Double] {
        let channels=try await decodedStereo(url)
        return zip(channels[0],channels[1]).map{pair in (pair.0+pair.1)/2}
    }
    private func amplitude(_ values:[Double],from:Double,to:Double,frequency:Double)throws->Double {
        let lower=Int(from*48000),upper=Int(to*48000)
        guard lower>=0,upper<=values.count,upper>lower else{throw VideoError.invalid("隔离音频检查窗口超出解码范围")}
        var s=0.0,c=0.0
        for i in lower..<upper {let phase=2 * .pi * frequency*Double(i)/48000;s += values[i]*sin(phase);c += values[i]*cos(phase)}
        return 2*sqrt(s*s+c*c)/Double(upper-lower)
    }

    func testCopiedMixerPCMRetainsTimestampsFramesAndRejectsWrongFormat()throws {
        func buffer(channels:UInt32=2)throws->CMSampleBuffer {
            var format=AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,mBytesPerPacket:channels*4,mFramesPerPacket:1,mBytesPerFrame:channels*4,mChannelsPerFrame:channels,mBitsPerChannel:32,mReserved:0)
            var description:CMAudioFormatDescription?
            XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&format,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&description),noErr)
            var block:CMBlockBuffer?
            let values:[Float]=channels==2 ? [0.1,-0.2,0.3,-0.4]:[0.1,0.3]
            let bytes=values.count*MemoryLayout<Float>.size
            XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:bytes,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:bytes,flags:0,blockBufferOut:&block),kCMBlockBufferNoErr)
            let owned=try XCTUnwrap(block)
            XCTAssertEqual(values.withUnsafeBytes{CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:owned,offsetIntoDestination:0,dataLength:bytes)},kCMBlockBufferNoErr)
            var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:48000),presentationTimeStamp:CMTime(value:37,timescale:30),decodeTimeStamp:.invalid)
            var size=Int(channels)*4,sample:CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:owned,formatDescription:try XCTUnwrap(description),sampleCount:2,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&size,sampleBufferOut:&sample),noErr)
            return try XCTUnwrap(sample)
        }
        func samples(_ sample:CMSampleBuffer)throws->[Float] {
            let block=try XCTUnwrap(CMSampleBufferGetDataBuffer(sample)),bytes=CMBlockBufferGetDataLength(block)
            var values=[Float](repeating:0,count:bytes/4)
            XCTAssertEqual(values.withUnsafeMutableBytes{CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:bytes,destination:$0.baseAddress!)},kCMBlockBufferNoErr)
            return values
        }
        let sample=try buffer(),before=try samples(sample)
        let pts=CMSampleBufferGetPresentationTimeStamp(sample),duration=CMSampleBufferGetDuration(sample)
        try MediaRenderer.restoreMixerPCM(sample,headroom:1)
        XCTAssertEqual(try samples(sample).map(\.bitPattern),before.map(\.bitPattern))
        try MediaRenderer.restoreMixerPCM(sample,headroom:2)
        XCTAssertEqual(try samples(sample),before.map{Float(Double($0)*2)})
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample),2)
        XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),pts),0)
        XCTAssertEqual(CMTimeCompare(CMSampleBufferGetDuration(sample),duration),0)
        let mono=try buffer(channels:1),monoBefore=try samples(mono)
        XCTAssertThrowsError(try MediaRenderer.restoreMixerPCM(mono,headroom:2))
        XCTAssertEqual(try samples(mono),monoBefore)
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

    func testThreeTrackAACDucksSourceWindowAndMusicPreservesVoiceTailAndPause()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("three-track-calibration-"+Codec.id())
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let sourceFile=root.appendingPathComponent("source-calibration.caf")
        let voiceFile=root.appendingPathComponent("voice-calibration.caf")
        let musicFile=root.appendingPathComponent("music-calibration.caf")
        // Isolated calibration signals identify each decoded track; they are not music,
        // spoken narration, a rights declaration or human listening evidence.
        try tone(sourceFile,seconds:4,frequency:613,level:0.6,leadFrequency:701,leadSeconds:1)
        try tone(voiceFile,seconds:1,frequency:997)
        try tone(musicFile,seconds:5,frequency:400,level:0.6)
        let repo=try Repository(root:root.appendingPathComponent("workspace"))
        let sourceTone=try repo.ingest(Data(contentsOf:sourceFile),name:"isolated-source.caf",workspaceID:"w",mediaType:"audio",durationFrames:120)
        var sourceScene=VideoCore.Scene(title:"原片校准信号",body:"隔离媒体规则",durationFrames:120)
        sourceScene.musicGain=0.4
        var sourceRevision=try Planner.create(workspaceID:"w",name:"源片段校准",aspect:.landscape,scenes:[sourceScene])
        sourceRevision.musicAssetID=sourceTone.id
        sourceRevision.dependencies=try DependencyRules.freeze(revision:sourceRevision,assets:[sourceTone],evidence:[])
        try repo.transaction {db in
            var w=Workspace(name:"三轨隔离规则",owner:"rules");w.id="w"
            db.workspaces=[w];db.assets=[sourceTone];db.projects=[Project(workspaceID:"w",name:"源片段校准",revision:sourceRevision)]
        }
        let sourceRender=try await MediaRenderer().render(revision:sourceRevision,repository:repo,output:root.appendingPathComponent("source-output"))
        let sourceMovie=try XCTUnwrap(sourceRender.artifacts.first{$0.mime=="video/mp4"})
        let video=try repo.ingest(Data(contentsOf:URL(fileURLWithPath:sourceMovie.path)),name:"isolated-source.mp4",workspaceID:"w",mediaType:"video",durationFrames:120)
        let voice=try repo.ingest(Data(contentsOf:voiceFile),name:"isolated-voice.caf",workspaceID:"w",mediaType:"audio",durationFrames:30)
        let music=try repo.ingest(Data(contentsOf:musicFile),name:"isolated-music.caf",workspaceID:"w",mediaType:"audio",durationFrames:150)
        func scene(_ title:String,frames:Int,speed:Double=1,pause:Int=0,muted:Bool=false,voiceGain:Double=1.5)throws->VideoCore.Scene {
            var s=VideoCore.Scene(title:title,body:"隔离校准，不是完整知识成片。",narration:"测试口播",durationFrames:frames)
            s.kind = .video;s.assetID=video.id;s.sourceStartFrame=30;s.speed=speed;s.pauseFrames=pause
            s.preservePitch=false;s.sourceGain=0.6;s.musicGain=0.3;s.voiceGain=voiceGain;s.muted=muted
            s.voice=VoiceTake(assetID:voice.id,textDigest:try s.speechDigest(),durationFrames:30,method:"isolated_test_tone")
            return s
        }
        let spoken=try scene("变速源窗与句尾",frames:90,speed:2,pause:30)
        let muted=try scene("全轨静音",frames:30,muted:true)
        let zeroVoice=try scene("旁白音量为零",frames:30,voiceGain:0)
        var revision=try Planner.create(workspaceID:"w",name:"三轨实际AAC规则",aspect:.landscape,scenes:[spoken,muted,zeroVoice])
        revision.musicAssetID=music.id
        let assets=[sourceTone,video,voice,music]
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:assets,evidence:[])
        try repo.transaction {db in db.assets=assets;db.projects.append(Project(workspaceID:"w",name:"三轨实际AAC规则",revision:revision))}
        let rendered=try await MediaRenderer().render(revision:revision,repository:repo,output:root.appendingPathComponent("mixed-output"))
        let movie=URL(fileURLWithPath:try XCTUnwrap(rendered.artifacts.first{$0.mime=="video/mp4"}).path)
        let inspection=try await MediaInspection.inspect(movie)
        XCTAssertEqual(inspection.audioCodec,"aac ");XCTAssertEqual(inspection.sampleRate,48000)
        XCTAssertEqual(inspection.duration,4.5,accuracy:0.025)
        let samples=try await decodedMono(movie)
        let sourceDuck=try amplitude(samples,from:0.15,to:0.35,frequency:1226)
        let sourceRecovered=try amplitude(samples,from:0.9,to:1.3,frequency:1226)
        let musicDuck=try amplitude(samples,from:0.15,to:0.35,frequency:400)
        let musicRecovered=try amplitude(samples,from:0.9,to:1.3,frequency:400)
        XCTAssertGreaterThan(sourceDuck,0.015);XCTAssertGreaterThan(sourceRecovered,sourceDuck*2.5)
        XCTAssertGreaterThan(musicDuck,0.02);XCTAssertGreaterThan(musicRecovered,musicDuck*2.5)
        XCTAssertLessThan(try amplitude(samples,from:0.15,to:0.35,frequency:1402),0.003,"必须使用从1秒开始的613Hz源窗，不能混入701Hz前段")
        XCTAssertGreaterThan(try amplitude(samples,from:0.4,to:0.47,frequency:1994),0.06,"变速后旁白最后70毫秒仍在最终AAC中")
        XCTAssertLessThan(try amplitude(samples,from:0.9,to:1.3,frequency:1994),0.003)
        XCTAssertLessThan(try amplitude(samples,from:1.7,to:2.2,frequency:1226),0.001,"原片声不能延入停顿")
        XCTAssertGreaterThan(try amplitude(samples,from:1.7,to:2.2,frequency:400),0.08,"停顿仍保原配乐行为")
        for frequency in [400.0,613,997,1226,1994] {
            XCTAssertLessThan(try amplitude(samples,from:2.7,to:3.2,frequency:frequency),0.001,"静音镜头须关闭全部三轨")
        }
        XCTAssertGreaterThan(try amplitude(samples,from:3.7,to:4.2,frequency:613),sourceDuck*2.5,"旁白音量为0时原片声不应duck")
        XCTAssertGreaterThan(try amplitude(samples,from:3.7,to:4.2,frequency:400),musicDuck*2.5)
        XCTAssertLessThan(try amplitude(samples,from:3.7,to:4.2,frequency:997),0.001)
        let notes=try String(contentsOf:URL(fileURLWithPath:try XCTUnwrap(rendered.artifacts.first{$0.mime=="text/plain"}).path),encoding:.utf8)
        XCTAssertTrue(notes.contains("平台账号/挂载资格：未核实（仅通用文件交付）"))
        XCTAssertEqual(rendered.artifacts.count,4)
        XCTAssertEqual(revision.scenes[0].sourceStartFrame,30);XCTAssertEqual(revision.scenes[0].sourceGain,0.6)
        XCTAssertFalse(revision.review.sound);XCTAssertFalse(revision.review.complete,"校准信号和测量不能代替人工审核")
    }

    func testActualThreeTrackAACPreservesOneOnePointFiveAndTwoGainRatios()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("three-track-gain-ratios-"+Codec.id())
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let sourceFile=root.appendingPathComponent("source.caf"),voiceFile=root.appendingPathComponent("voice.caf"),musicFile=root.appendingPathComponent("music.caf")
        // Frequencies separate the actual decoded tracks. This synthetic fixture
        // proves signal gain and timing, never narration quality or listening.
        try tone(sourceFile,seconds:2,frequency:613,level:0.08)
        try tone(voiceFile,seconds:0.5,frequency:997,level:0.08)
        try tone(musicFile,seconds:2,frequency:400,level:0.08)
        let sourceBytes=try Data(contentsOf:sourceFile),voiceBytes=try Data(contentsOf:voiceFile),musicBytes=try Data(contentsOf:musicFile)
        let repo=try Repository(root:root.appendingPathComponent("workspace"))
        let sourceTone=try repo.ingest(sourceBytes,name:"source.caf",workspaceID:"w",mediaType:"audio",durationFrames:60)
        var base=VideoCore.Scene(title:"校准源片",body:"隔离校准",durationFrames:60);base.musicGain=1
        var baseRevision=try Planner.create(workspaceID:"w",name:"源片",aspect:.landscape,scenes:[base]);baseRevision.musicAssetID=sourceTone.id
        baseRevision.dependencies=try DependencyRules.freeze(revision:baseRevision,assets:[sourceTone],evidence:[])
        try repo.transaction { db in
            var workspace=Workspace(name:"音量比例规则",owner:"rules");workspace.id="w"
            db.workspaces=[workspace];db.assets=[sourceTone];db.projects=[Project(workspaceID:"w",name:"源片",revision:baseRevision)]
        }
        let sourceResult=try await MediaRenderer().render(revision:baseRevision,repository:repo,output:root.appendingPathComponent("source-output"))
        let sourceMovie=URL(fileURLWithPath:try XCTUnwrap(sourceResult.artifacts.first{$0.mime=="video/mp4"}).path)
        let sourceMovieBytes=try Data(contentsOf:sourceMovie)
        let video=try repo.ingest(sourceMovieBytes,name:"source.mp4",workspaceID:"w",mediaType:"video",durationFrames:60)
        let voice=try repo.ingest(voiceBytes,name:"voice.caf",workspaceID:"w",mediaType:"audio",durationFrames:15)
        let music=try repo.ingest(musicBytes,name:"music.caf",workspaceID:"w",mediaType:"audio",durationFrames:60)
        let gains=[1.0,1.5,2.0]
        func scene(_ gain:Double,muted:Bool=false)throws->VideoCore.Scene {
            var scene=VideoCore.Scene(title:"三轨比例",body:"只验证声音信号",narration:"隔离信号",durationFrames:45)
            scene.kind = .video;scene.assetID=video.id;scene.sourceStartFrame=15;scene.sourceEndFrame=60;scene.pauseFrames=15
            scene.voiceGain=gain;scene.sourceGain=gain;scene.musicGain=gain;scene.muted=muted
            scene.voice=VoiceTake(assetID:voice.id,textDigest:try scene.speechDigest(),durationFrames:15,method:"isolated_test_tone")
            return scene
        }
        var scenes=try gains.map{try scene($0)}
        scenes.append(try scene(2,muted:true));scenes.append(try scene(1.5))
        var revision=try Planner.create(workspaceID:"w",name:"三轨音量比例",aspect:.landscape,scenes:scenes);revision.musicAssetID=music.id
        let assets=[sourceTone,video,voice,music]
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:assets,evidence:[])
        try repo.transaction {db in db.assets=assets;db.projects.append(Project(workspaceID:"w",name:"三轨音量比例",revision:revision))}
        let before=try Codec.digest(repo.read())
        let rendered=try await MediaRenderer().render(revision:revision,repository:repo,output:root.appendingPathComponent("output"))
        let movie=URL(fileURLWithPath:try XCTUnwrap(rendered.artifacts.first{$0.mime=="video/mp4"}).path)
        let inspection=try await MediaInspection.inspect(movie)
        XCTAssertEqual(inspection.audioCodec,"aac ");XCTAssertEqual(inspection.sampleRate,48000)
        XCTAssertEqual(inspection.duration,10,accuracy:1.0/48000)
        let samples=try await decodedMono(movie)
        XCTAssertEqual(samples.count,480000)
        var voiceLevels:[Double]=[],sourceLevels:[Double]=[],musicLevels:[Double]=[]
        for index in gains.indices {
            let start=Double(index)*2
            let voiceLevel=try amplitude(samples,from:start+0.15,to:start+0.35,frequency:997)
            let sourceDuck=try amplitude(samples,from:start+0.15,to:start+0.35,frequency:613)
            let sourceLevel=try amplitude(samples,from:start+0.9,to:start+1.3,frequency:613)
            let musicDuck=try amplitude(samples,from:start+0.15,to:start+0.35,frequency:400)
            let musicLevel=try amplitude(samples,from:start+0.9,to:start+1.3,frequency:400)
            XCTAssertGreaterThan(voiceLevel,0.03);XCTAssertGreaterThan(sourceLevel,0.03);XCTAssertGreaterThan(musicLevel,0.03)
            XCTAssertEqual(sourceDuck/sourceLevel,0.3,accuracy:0.03)
            XCTAssertEqual(musicDuck/musicLevel,0.3,accuracy:0.03)
            XCTAssertGreaterThan(try amplitude(samples,from:start+0.39,to:start+0.47,frequency:997),voiceLevel*0.9,"恢复增益不能截断最后80毫秒")
            XCTAssertLessThan(try amplitude(samples,from:start+1.6,to:start+1.9,frequency:613),0.001,"原片不能延入停顿")
            XCTAssertLessThan(try amplitude(samples,from:start+1.6,to:start+1.9,frequency:997),0.001)
            XCTAssertEqual(try amplitude(samples,from:start+1.6,to:start+1.9,frequency:400)/musicLevel,1,accuracy:0.03)
            voiceLevels.append(voiceLevel);sourceLevels.append(sourceLevel);musicLevels.append(musicLevel)
        }
        for levels in [voiceLevels,sourceLevels,musicLevels] {
            XCTAssertEqual(levels[1]/levels[0],1.5,accuracy:0.05)
            XCTAssertEqual(levels[2]/levels[0],2,accuracy:0.05,"0到2工程请求必须体现为实际幅度，不能被1钳住")
        }
        for frequency in [400.0,613,997] {
            XCTAssertLessThan(try amplitude(samples,from:6.2,to:7.8,frequency:frequency),0.001,"相邻静音镜头不能留下前景声音")
        }
        let resumedMusic=try amplitude(samples,from:8.9,to:9.3,frequency:400)
        let resumedSource=try amplitude(samples,from:8.9,to:9.3,frequency:613)
        XCTAssertEqual(try amplitude(samples,from:8.15,to:8.35,frequency:400)/resumedMusic,0.3,accuracy:0.03,"静音后新景必须立即使用明确duck增益")
        XCTAssertEqual(try amplitude(samples,from:8.15,to:8.35,frequency:613)/resumedSource,0.3,accuracy:0.03)
        XCTAssertEqual(resumedMusic/musicLevels[0],1.5,accuracy:0.05)
        XCTAssertEqual(try amplitude(samples,from:8.15,to:8.35,frequency:997)/voiceLevels[0],1.5,accuracy:0.05)
        XCTAssertEqual(try Codec.digest(repo.read()),before)
        for (asset,bytes) in [(sourceTone,sourceBytes),(video,sourceMovieBytes),(voice,voiceBytes),(music,musicBytes)] {
            XCTAssertEqual(try Data(contentsOf:repo.assetURL(asset)),bytes)
        }
        XCTAssertEqual(revision.scenes.map(\.voiceGain),gains+[2,1.5])
        XCTAssertFalse(revision.review.sound);XCTAssertFalse(revision.review.complete)
    }

    func testActualBoostOverloadAndCancellationCleanPreparedAudioWithoutChangingSources()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("mix-boost-failure-"+Codec.id())
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        for overload in [true,false] {
            let name=overload ? "overload":"cancelled"
            let source=root.appendingPathComponent(name+".caf")
            try tone(source,seconds:overload ? 1:2,frequency:997,level:overload ? 0.9:0.12)
            let bytes=try Data(contentsOf:source),repo=try Repository(root:root.appendingPathComponent(name))
            let voiceFrames=overload ? 30:60
            let asset=try repo.ingest(bytes,name:name+".caf",workspaceID:"w",mediaType:"audio",durationFrames:voiceFrames)
            var scene=VideoCore.Scene(title:"过载与取消边界",body:"隔离信号，不是作品",narration:"校准",durationFrames:voiceFrames)
            scene.voiceGain=2;scene.preservePitch=false
            if !overload {scene.speed=0.5;scene.pauseFrames=30}
            scene.voice=VoiceTake(assetID:asset.id,textDigest:try scene.speechDigest(),durationFrames:voiceFrames,method:"isolated_test_tone")
            var revision=try Planner.create(workspaceID:"w",name:name,aspect:.landscape,scenes:[scene])
            revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[asset],evidence:[])
            try repo.transaction {db in
                var workspace=Workspace(name:name,owner:"rules");workspace.id="w"
                db.workspaces=[workspace];db.assets=[asset];db.projects=[Project(workspaceID:"w",name:name,revision:revision)]
            }
            let before=try Codec.digest(repo.read()),output=repo.root.appendingPathComponent("output")
            do {
                _=try await MediaRenderer().render(revision:revision,repository:repo,output:output) { value in
                    if !overload && value>=0.8 {throw CancellationError()}
                }
                XCTFail(overload ? "真实满幅过载必须在编码前拒绝":"混音阶段取消必须退出")
            } catch {
                if overload {
                    guard case VideoError.review(let message)=error else {XCTFail("应由实际混合PCM过载门拒绝：\(error)");continue}
                    XCTAssertTrue(message.contains("AAC编码前达到满幅过载"),message)
                } else {XCTAssertTrue(error is CancellationError,"实际取消不应伪装为编码成功：\(error)")}
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath:output.appendingPathComponent("video.mp4").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath:output.appendingPathComponent("working.mp4").path))
            let cache=repo.root.appendingPathComponent("cache")
            let remaining=try FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil)
            XCTAssertFalse(remaining.contains{$0.lastPathComponent.hasPrefix("audio-preparation-") || $0.lastPathComponent=="silence.caf"})
            XCTAssertEqual(try Codec.digest(repo.read()),before)
            XCTAssertEqual(try Data(contentsOf:repo.assetURL(asset)),bytes)
            XCTAssertEqual(try Data(contentsOf:source),bytes)
            XCTAssertFalse(revision.review.sound);XCTAssertFalse(revision.review.complete)
        }
    }

    func testActual44100MonoAndStereoSlowPCMRetainsRoundedVoiceTailAndSilence()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("slow-native-pcm-calibration-"+Codec.id())
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let sourceSeconds=1.23,sourceRate=44100.0,sourceFrames=54243
        let voiceFrames=37,speed=0.5,targetVoiceSeconds=Double(voiceFrames)/30/0.5
        let slowedLeft=997*sourceSeconds/targetVoiceSeconds
        let slowedRight=1709*sourceSeconds/targetVoiceSeconds
        for channelCount in [AVAudioChannelCount(1),AVAudioChannelCount(2)] {
            let label=channelCount==1 ? "mono-caf":"stereo-wav"
            let source=root.appendingPathComponent(label+(channelCount==1 ? ".caf":".wav"))
            // Deliberately not an integer 30fps duration. These are isolated known
            // signals, never speech, production sound or a listening declaration.
            try tone(source,seconds:sourceSeconds,frequency:997,sampleRate:sourceRate,channels:channelCount,rightFrequency:1709)
            let sourceFile=try AVAudioFile(forReading:source)
            XCTAssertEqual(sourceFile.length,AVAudioFramePosition(sourceFrames))
            XCTAssertEqual(sourceFile.fileFormat.sampleRate,sourceRate)
            XCTAssertEqual(sourceFile.fileFormat.channelCount,channelCount)
            let sourceBytes=try Data(contentsOf:source)
            let repo=try Repository(root:root.appendingPathComponent(label))
            let voice=try repo.ingest(sourceBytes,name:source.lastPathComponent,workspaceID:"w",mediaType:"audio",durationFrames:voiceFrames)
            var scene=VideoCore.Scene(title:"慢速声音边界",body:"真实采样时长与向上取整帧分别核对。",narration:"隔离校准信号",durationFrames:45)
            scene.speed=speed;scene.preservePitch=false;scene.voiceGain=0.5
            scene.voice=VoiceTake(assetID:voice.id,textDigest:try scene.speechDigest(),durationFrames:voiceFrames,method:"isolated_test_tone")
            var revision=try Planner.create(workspaceID:"w",name:label,aspect:.landscape,scenes:[scene])
            revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[voice],evidence:[])
            try repo.transaction {db in
                var workspace=Workspace(name:"44.1k慢速隔离规则",owner:"rules");workspace.id="w"
                db.workspaces=[workspace];db.assets=[voice];db.projects=[Project(workspaceID:"w",name:label,revision:revision)]
            }
            let before=try Codec.digest(repo.read())
            let rendered=try await MediaRenderer().render(revision:revision,repository:repo,output:repo.root.appendingPathComponent("output"))
            let movie=URL(fileURLWithPath:try XCTUnwrap(rendered.artifacts.first{$0.mime=="video/mp4"}).path)
            let inspection=try await MediaInspection.inspect(movie)
            XCTAssertEqual(inspection.audioCodec,"aac ");XCTAssertEqual(inspection.sampleRate,48000)
            XCTAssertEqual(inspection.duration,3,accuracy:1.0/48000)
            let channels=try await decodedStereo(movie)
            XCTAssertEqual(channels[0].count,144000);XCTAssertEqual(channels[1].count,144000)
            let tailStart=targetVoiceSeconds-0.12,tailEnd=targetVoiceSeconds-0.03
            let leftTail=try amplitude(channels[0],from:tailStart,to:tailEnd,frequency:slowedLeft)
            XCTAssertGreaterThan(leftTail,channelCount==1 ? 0.035:0.045,"原生44.1k声音最后90毫秒仍在，且0.5增益没有重复应用")
            XCTAssertLessThan(leftTail,0.075,"整备不应提前乘入增益后又改变声轨电平")
            XCTAssertGreaterThan(try amplitude(channels[0],from:0.4,to:0.6,frequency:slowedLeft),0.035)
            XCTAssertLessThan(try amplitude(channels[0],from:0.4,to:0.6,frequency:997),0.004,"慢速varispeed须保留其实际变调语义")
            if channelCount==2 {
                let rightTail=try amplitude(channels[1],from:tailStart,to:tailEnd,frequency:slowedRight)
                XCTAssertGreaterThan(rightTail,0.045);XCTAssertLessThan(rightTail,0.075)
                XCTAssertLessThan(try amplitude(channels[0],from:tailStart,to:tailEnd,frequency:slowedRight),0.006,"不能把双声道合并成mono")
                XCTAssertLessThan(try amplitude(channels[1],from:tailStart,to:tailEnd,frequency:slowedLeft),0.006)
            }
            for channel in channels {
                XCTAssertLessThan(try amplitude(channel,from:targetVoiceSeconds+0.1,to:2.9,frequency:slowedLeft),0.001)
                XCTAssertLessThan(try amplitude(channel,from:targetVoiceSeconds+0.1,to:2.9,frequency:slowedRight),0.001)
            }
            XCTAssertEqual(try Codec.digest(repo.read()),before,"制作不得改写源声、历史、向上取整时长或人工审核")
            XCTAssertEqual(try Data(contentsOf:source),sourceBytes)
            XCTAssertEqual(try Data(contentsOf:repo.assetURL(voice)),sourceBytes)
            XCTAssertEqual(revision.scenes[0].voice?.durationFrames,37)
            XCTAssertEqual(revision.scenes[0].speed,0.5);XCTAssertEqual(revision.scenes[0].voiceGain,0.5)
            XCTAssertFalse(revision.scenes[0].voice?.listened ?? true)
            XCTAssertFalse(revision.review.sound);XCTAssertFalse(revision.review.complete)
            let cache=repo.root.appendingPathComponent("cache")
            let leftovers=try FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("audio-preparation-")}
            XCTAssertTrue(leftovers.isEmpty,"整备临时文件应在正常制作结束时完整回收")
            XCTAssertEqual(rendered.artifacts.count,4)
        }
    }
}
