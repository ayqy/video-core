import XCTest
import AVFoundation
import VideoCore
@testable import VideoMedia

final class SpeechProjectProductionTests: XCTestCase {
    @MainActor private func fixture(needsInstalledVoice:Bool=true) throws -> (Repository,SpeechProjectRequest) {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["SPEECH_TEST_ROOT"] ?? FileManager.default.temporaryDirectory.path).appendingPathComponent("speech-"+Codec.id())
        let repo=try Repository(root:root)
        let w=Workspace(name:"本机中文声音内部检查",owner:"owner")
        let s=Scene(title:"公共品",body:"简化模型",narration:"两位居民共同修桥。每人贡献三枚金币，修桥收益由两人共享。这个简化模型说明，个人激励和共同利益可能不同。",durationFrames:30)
        let p=Project(workspaceID:w.id,name:"中文知识内部开发",revision:Revision(contentContext:.init(workspaceID:w.id,name:"中文知识内部开发"),aspect:.landscape,scenes:[s]))
        try repo.transaction{$0.workspaces=[w];$0.projects=[p]}
        var plan=try ChineseSpeech.normalize(s.narration)
        if needsInstalledVoice {
            let voices=SpeechService.voices();let voice=try XCTUnwrap(voices.first(where:{$0.id=="com.apple.voice.compact.zh-CN.Tingting"}) ?? voices.first(where:{$0.language=="zh-CN"}) ?? voices.first,"本机必须已有真实中文声音；测试不下载")
            plan.voiceIdentifier=voice.id
        }
        plan.confirmed=true
        return(repo,SpeechProjectRequest(workspaceID:w.id,projectID:p.id,sceneID:s.id,baseRevision:p.current.id,plan:plan,extendScene:true,timeoutSeconds:90))
    }
    @MainActor func testRealInstalledChineseSpeechBindsCompleteAudioAndReplaysWithoutNewVersion() async throws {
        let(repo,q)=try fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let producer=SpeechProjectProduction();let result=try await producer.perform(q,repository:repo,principal:"owner")
        XCTAssertEqual(result.object?["state"],.string("needs_review"))
        let d=try repo.read();let a=try XCTUnwrap(d.assets.first);let take=try XCTUnwrap(d.projects[0].current.scenes[0].voice)
        let diagnostics=try await AudioInspection.inspect(repo.assetURL(a))
        XCTAssertGreaterThan(diagnostics.duration,5);XCTAssertGreaterThan(diagnostics.peakDBFS,-70)
        XCTAssertEqual(take.durationFrames,Int(ceil(diagnostics.duration*30)));XCTAssertEqual(d.projects[0].current.scenes[0].durationFrames,take.durationFrames)
        XCTAssertEqual(a.hash,Codec.hash(try Data(contentsOf:repo.assetURL(a))));XCTAssertFalse(take.listened)
        XCTAssertTrue(d.projects[0].current.scenes[0].captions.allSatisfy{!$0.confirmed});XCTAssertFalse(d.evidence[0].verified)
        let before=try Codec.digest(d);let replay=try await producer.perform(q,repository:repo,principal:"owner")
        XCTAssertEqual(result,replay);XCTAssertEqual(before,try Codec.digest(repo.read()));XCTAssertEqual(d.projects[0].revisions.count,2)
    }
    @MainActor func testUnavailableVoiceAndPreCancelledOperationNeverWriteSuccess() async throws {
        let(repo,q)=try fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let before=try Codec.digest(repo.read());var bad=q;bad.plan.voiceIdentifier="missing.zh.voice"
        do {_=try await SpeechProjectProduction().perform(bad,repository:repo,principal:"owner");XCTFail("missing voice must fail")}catch{}
        let operation=Task { @MainActor in try await SpeechProjectProduction().perform(q,repository:repo,principal:"owner") };operation.cancel()
        do{_=try await operation.value;XCTFail("cancel must fail")}catch{}
        XCTAssertEqual(before,try Codec.digest(repo.read()));XCTAssertTrue(try repo.read().agentReplayRecords?.isEmpty ?? true)
    }
    @MainActor func testMacEntitlementCommitFailurePreservesVersionAndNoSuccessReceipt() async throws {
        let(repo,q)=try fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let before=try Codec.digest(repo.read());var actualCommitReached=false
        do {_=try await SpeechProjectProduction().perform(q,repository:repo,principal:"owner",authorizeChanges:{_,_,_ in actualCommitReached=true;throw VideoError.permission("test denied at actual Mac commit")});XCTFail("entitlement denial must fail")}catch{guard case VideoError.permission = error else {XCTFail("must reach actual Mac permission callback: \(error)");return}}
        XCTAssertTrue(actualCommitReached)
        XCTAssertEqual(before,try Codec.digest(repo.read()));XCTAssertTrue(try repo.read().assets.isEmpty)
    }

    @MainActor func testNormalImportedAudioAttachChecksRealBytesAndKeepsHumanReviewPending() async throws {
        let(repo,original)=try fixture(needsInstalledVoice:false);defer{try? FileManager.default.removeItem(at:repo.root)}
        // This authored test tone verifies source integrity, not Chinese speech quality.
        let url=repo.root.appendingPathComponent("authored-test.wav")
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!
        buffer.frameLength=48000
        for i in 0..<48000 {buffer.floatChannelData![0][i]=Float(sin(Double(i)*2*Double.pi*440/48000)*0.1)}
        do {let file=try AVAudioFile(forWriting:url,settings:format.settings);try file.write(from:buffer)}
        var a=try await MaterialImporter.importFile(url,workspaceID:original.workspaceID,repository:repo)
        let e=Evidence(workspaceID:original.workspaceID,title:"原创测试音",source:"test authored sine PCM",claim:"only source-integrity fixture",owner:"test",commercialAllowed:false,uploadConsent:false,verified:true,assetID:a.id);a.evidenceID=e.id
        try repo.transaction{$0.assets.append(a);$0.evidence.append(e)}
        var q=original;q.assetID=a.id;q.plan.voiceIdentifier=nil
        let before=try Codec.digest(repo.read())
        _=try AgentPreview.evaluate(command:"speech attach",data:Codec.data(q),database:repo.read(),principal:"owner")
        XCTAssertEqual(before,try Codec.digest(repo.read()))
        let producer=SpeechProjectProduction();let value=try await producer.perform(q,repository:repo,principal:"owner")
        XCTAssertEqual(value.object?["state"],.string("needs_review"));let d=try repo.read()
        XCTAssertEqual(d.assets.count,1);XCTAssertEqual(d.evidence.count,1);XCTAssertFalse(d.projects[0].current.scenes[0].voice!.listened)
        XCTAssertEqual(d.projects[0].current.scenes[0].voice?.durationFrames,30)
        let replay=try await producer.perform(q,repository:repo,principal:"owner");XCTAssertEqual(value,replay)
        var changed=q;changed.requestID=Codec.id();changed.baseRevision=d.projects[0].current.id
        try Data("tampered".utf8).write(to:repo.assetURL(a))
        let frozen=try Codec.digest(repo.read())
        do{_=try await producer.perform(changed,repository:repo,principal:"owner");XCTFail("tampered source must fail")}catch{}
        XCTAssertEqual(frozen,try Codec.digest(repo.read()))
    }

    @MainActor func testImported22050AudioKeepsContainerTailAndChecksMacCommitAfterDecode() async throws {
        let(repo,original)=try fixture(needsInstalledVoice:false);defer{try? FileManager.default.removeItem(at:repo.root)}
        let url=repo.root.appendingPathComponent("container-boundary.wav")
        let format=AVAudioFormat(standardFormatWithSampleRate:22050,channels:1)!
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:80128)!
        buffer.frameLength=80128
        for i in 0..<80128 {buffer.floatChannelData![0][i]=Float(sin(Double(i)*2*Double.pi*440/22050)*0.1)}
        do {let file=try AVAudioFile(forWriting:url,settings:format.settings);try file.write(from:buffer)}
        var asset=try await MaterialImporter.importFile(url,workspaceID:original.workspaceID,repository:repo)
        let evidence=Evidence(workspaceID:original.workspaceID,title:"原容器跨帧测试音",source:"authored PCM, not speech-quality evidence",claim:"complete source integrity only",owner:"test",commercialAllowed:false,uploadConsent:false,verified:true,assetID:asset.id)
        asset.evidenceID=evidence.id
        try repo.transaction{$0.assets.append(asset);$0.evidence.append(evidence)}
        var request=original;request.assetID=asset.id;request.plan.voiceIdentifier=nil
        XCTAssertEqual(asset.durationFrames,110)
        let sourceHash=Codec.hash(try Data(contentsOf:repo.assetURL(asset)))
        let before=try Codec.digest(repo.read());var commitReached=false
        do {
            _=try await SpeechProjectProduction().perform(request,repository:repo,principal:"owner",authorizeChanges:{_,_,_ in
                commitReached=true;throw VideoError.permission("editor permission denied at normal Mac commit")
            })
            XCTFail("the normal commit permission must still be required")
        } catch {guard case VideoError.permission = error else {XCTFail("must finish source decode before commit denial: \(error)");return}}
        XCTAssertTrue(commitReached);XCTAssertEqual(before,try Codec.digest(repo.read()))
        XCTAssertTrue(try repo.read().agentReplayRecords?.isEmpty ?? true)
        let result=try await SpeechProjectProduction().perform(request,repository:repo,principal:"owner")
        let data=try repo.read();let current=data.projects[0].current.scenes[0]
        XCTAssertEqual(result.object?["state"],.string("needs_review"))
        XCTAssertEqual(current.voice?.durationFrames,110);XCTAssertEqual(current.durationFrames,110)
        XCTAssertFalse(current.voice!.listened);XCTAssertTrue(current.captions.allSatisfy{!$0.confirmed})
        XCTAssertEqual(sourceHash,Codec.hash(try Data(contentsOf:repo.assetURL(asset))))
    }
}
