import XCTest
import VideoCore

final class MediaPresentationTests: XCTestCase {
    private func videoAsset() -> Asset {
        Asset(workspaceID:"w",name:"recording.mp4",hash:String(repeating:"a",count:64),ext:"mp4",bytes:100,
              mediaType:"video",durationFrames:360)
    }

    private func mediaScene(_ asset:Asset) -> Scene {
        var scene=Scene(kind:.video,title:"真实录屏",body:"原来的说明",narration:"完整原文。",durationFrames:120)
        scene.assetID=asset.id;scene.sourceStartFrame=30;scene.sourceEndFrame=150
        scene.mediaFraming=MediaFraming(x:0.1,y:0.1,width:0.8,height:0.8)
        return scene
    }

    private func project(_ scene:Scene) -> Project {
        Project(workspaceID:"w",name:"普通媒体",revision:Revision(
            contentContext:ContentContext(workspaceID:"w",name:"真实源"),aspect:.landscape,scenes:[scene]))
    }

    func testStrictDecodeDefaultsRoundTripAndInvalidInputs() throws {
        let value=MediaPresentation()
        XCTAssertEqual(value.version,1);XCTAssertEqual(value.layout,.fullFrame);XCTAssertEqual(value.backgroundColor,"FFFFFF")
        XCTAssertEqual(try Codec.decoder().decode(MediaPresentation.self,from:Codec.data(value)),value)
        for color in ["000000","abcdef","A0b1C2"] {XCTAssertNoThrow(try MediaPresentation(backgroundColor:color).validate())}
        for raw in [
            #"{"version":1,"layout":"fullFrame","backgroundColor":"FFFFFF","execute":"never"}"#,
            #"{"layout":"fullFrame","backgroundColor":"FFFFFF"}"#,
            #"{"version":2,"layout":"fullFrame","backgroundColor":"FFFFFF"}"#,
            #"{"version":true,"layout":"fullFrame","backgroundColor":"FFFFFF"}"#,
            #"{"version":1,"layout":"poster","backgroundColor":"FFFFFF"}"#,
            #"{"version":1,"layout":"fullFrame"}"#,
            #"{"version":1,"layout":"fullFrame","backgroundColor":"FFF"}"#,
            #"{"version":1,"layout":"fullFrame","backgroundColor":"FFFFFF\n"}"#,
            #"{"version":1,"layout":"fullFrame","backgroundColor":null}"#,
            ##"{"version":1,"layout":"fullFrame","backgroundColor":"#FFFFFF"}"##
        ] {XCTAssertThrowsError(try Codec.decoder().decode(MediaPresentation.self,from:Data(raw.utf8)))}
        for color in ["GGGGGG","ＦＦＦＦＦＦ","FFFFF ","FFFFFF\n"] {
            XCTAssertThrowsError(try MediaPresentation(backgroundColor:color).validate())
        }
        var bad=value;bad.version=Int.max;XCTAssertThrowsError(try bad.validate())
    }

    func testLegacySceneDTOBytesAndDigestRemainUnchangedWithNilPresentation() throws {
        // Pre-feature c26cf761 Scene fields and Codec JSONEncoder(.sortedKeys).
        // Keep the expected wire literal independent of the current Scene encoder.
        // JSONSerialization is unsuitable: its NSNumber bridge expands musicGain
        // 0.15 to 0.14999999999999999, unlike the historical JSONEncoder wire.
        let legacy=Data(#"{"id":"legacy-scene","kind":"图文讲解","title":"原工程","body":"原画面","narration":"原文。","durationFrames":120,"evidenceIDs":[],"sourceStartFrame":0,"speed":1,"preservePitch":true,"locked":false,"x":0.5,"y":0.5,"scale":1,"voiceGain":1,"sourceGain":0,"musicGain":0.15,"muted":false,"pauseFrames":0,"captions":[],"simulation":{"seed":42,"initial":100,"capacity":200,"unit":"上下文单位","events":[]},"character":"圆仔","emotion":"好奇","color":"6366F1","showPrice":false,"keyframes":[],"classicArtworkRequired":true}"#.utf8)
        let canonical=Data(#"{"body":"原画面","captions":[],"character":"圆仔","classicArtworkRequired":true,"color":"6366F1","durationFrames":120,"emotion":"好奇","evidenceIDs":[],"id":"legacy-scene","keyframes":[],"kind":"图文讲解","locked":false,"musicGain":0.15,"muted":false,"narration":"原文。","pauseFrames":0,"preservePitch":true,"scale":1,"showPrice":false,"simulation":{"capacity":200,"events":[],"initial":100,"seed":42,"unit":"上下文单位"},"sourceGain":0,"sourceStartFrame":0,"speed":1,"title":"原工程","voiceGain":1,"x":0.5,"y":0.5}"#.utf8)
        let legacyDigest="9ce0a0481d3427541298650d34639ee64f65a307d972de42148b2b2238594eab"
        XCTAssertEqual(canonical.count,538)
        XCTAssertEqual(Codec.hash(canonical),legacyDigest)
        let decoded=try Codec.decoder().decode(Scene.self,from:legacy)
        XCTAssertNil(decoded.mediaPresentation)
        XCTAssertEqual(try Codec.data(decoded),canonical)
        XCTAssertEqual(try Codec.digest(decoded),legacyDigest)
        XCTAssertFalse(String(decoding:try Codec.data(decoded),as:UTF8.self).contains("mediaPresentation"))
        var explicit=decoded;explicit.mediaPresentation=MediaPresentation()
        XCTAssertNotEqual(try Codec.digest(explicit),try Codec.digest(decoded))
        explicit.mediaPresentation=nil
        XCTAssertEqual(try Codec.data(explicit),canonical)
    }

    func testOnlyActualMatchingImageOrVideoAssetsCanBindPresentation() throws {
        for type in ["image","image/png","video","video/mp4"] {
            let image=type.hasPrefix("image")
            let asset=Asset(workspaceID:"w",name:"actual",hash:String(repeating:"b",count:64),ext:image ? "png":"mp4",
                bytes:100,mediaType:type,durationFrames:image ? nil:360)
            var scene=Scene(kind:image ? .image:.video,title:"实际原件",body:"",durationFrames:120)
            scene.assetID=asset.id;scene.mediaPresentation=MediaPresentation()
            XCTAssertNoThrow(try scene.validate(assets:[asset]))
            XCTAssertThrowsError(try scene.validate(assets:[]))
            var wrong=scene;wrong.assetID=nil;XCTAssertThrowsError(try wrong.validate(assets:[asset]))
            wrong=scene;wrong.assetID="unknown";XCTAssertThrowsError(try wrong.validate(assets:[asset]))
            wrong=scene;wrong.kind=image ? .video:.image;XCTAssertThrowsError(try wrong.validate(assets:[asset]))
            for kind in [SceneKind.explanation,.simulation,.cartoon] {
                wrong=scene;wrong.kind=kind;XCTAssertThrowsError(try wrong.validate(assets:[asset]))
            }
            wrong=scene;wrong.paperPresentation=PaperPresentation();XCTAssertThrowsError(try wrong.validate(assets:[asset]))
            wrong=scene;wrong.mediaPresentation?.backgroundColor="notRGB";XCTAssertThrowsError(try wrong.validate(assets:[asset]))
        }
    }

    func testNormalSchemaExposesStrictOptionalPresentationAndLayout() throws {
        let definitions=AgentSchemas.definitions()
        XCTAssertEqual(definitions["MediaPresentation"]?.object?["additionalProperties"],.boolean(false))
        XCTAssertEqual(definitions["MediaPresentation"]?.object?["properties"]?.object?["version"]?.object?["const"],.number(1))
        XCTAssertEqual(definitions["MediaPresentation"]?.object?["properties"]?.object?["backgroundColor"]?.object?["pattern"],.string("^[A-Fa-f0-9]{6}$"))
        XCTAssertEqual(definitions["MediaLayout"]?.object?["enum"],.array([.string("fullFrame")]))
        XCTAssertNotNil(definitions["Scene"]?.object?["properties"]?.object?["mediaPresentation"])
        let schema=try XCTUnwrap(AgentContract.inputSchema("edit apply").object)
        XCTAssertNotNil(schema["$defs"]?.object?["MediaPresentation"])
    }

    func testPresentationChangesInvalidateVoiceCaptionsAndReviewButPreserveSourcesAndHistory() throws {
        let asset=videoAsset()
        let voiceAsset=Asset(workspaceID:"w",name:"complete.wav",hash:String(repeating:"c",count:64),ext:"wav",bytes:100,
            mediaType:"audio",durationFrames:90)
        for change in 0..<3 {
            var scene=mediaScene(asset)
            if change != 0 {scene.mediaPresentation=MediaPresentation()}
            scene.speed=1.25;scene.pauseFrames=9
            scene.voice=VoiceTake(assetID:voiceAsset.id,textDigest:try scene.speechDigest(),durationFrames:90,method:"imported-recording",listened:true)
            scene.captions=[Caption(text:scene.narration,startFrame:0,endFrame:90,confirmed:true)]
            var before=project(scene)
            before.revisions[0].review.sound=true;before.revisions[0].review.captions=true;before.revisions[0].review.fullPreview=true
            let oldBytes=try Codec.data(before.current)
            var edited=scene
            if change == 0 {edited.mediaPresentation=MediaPresentation()}
            else if change == 1 {edited.mediaPresentation?.backgroundColor="112233"}
            else {edited.mediaPresentation=nil}
            let after=try Editor.apply([.replaceScene(scene.id,edited)],to:before,baseRevision:before.current.id,
                assets:[asset,voiceAsset],message:"显式改变普通媒体版式")
            let current=after.current.scenes[0]
            XCTAssertFalse(try XCTUnwrap(current.voice).listened);XCTAssertFalse(current.captions[0].confirmed)
            XCTAssertFalse(after.current.review.sound);XCTAssertFalse(after.current.review.captions);XCTAssertFalse(after.current.review.fullPreview)
            XCTAssertTrue(after.current.invalidated.contains("录屏/图片取景与声音字幕重新复核"))
            XCTAssertEqual(current.assetID,scene.assetID);XCTAssertEqual(current.sourceStartFrame,30);XCTAssertEqual(current.sourceEndFrame,150)
            XCTAssertEqual(current.durationFrames,120);XCTAssertEqual(current.speed,1.25);XCTAssertEqual(current.pauseFrames,9)
            XCTAssertEqual(current.mediaFraming,scene.mediaFraming);XCTAssertEqual(current.narration,scene.narration)
            XCTAssertEqual(current.voice?.assetID,scene.voice?.assetID);XCTAssertEqual(current.voice?.textDigest,scene.voice?.textDigest)
            XCTAssertEqual(try Codec.data(after.revisions[0]),oldBytes);XCTAssertEqual(try Codec.data(before.current),oldBytes)
            XCTAssertEqual(after.revisions.count,before.revisions.count+1)
        }
    }

    func testNormalEditorKeepsLockedSceneAndStaleCASProtected() throws {
        let asset=videoAsset();let scene=mediaScene(asset)
        var before=project(scene);before.revisions[0].scenes[0].locked=true
        var edited=before.current.scenes[0];edited.mediaPresentation=MediaPresentation()
        let original=try Codec.data(before)
        XCTAssertThrowsError(try Editor.apply([.replaceScene(scene.id,edited)],to:before,baseRevision:before.current.id,
            assets:[asset],message:"不能改锁定媒体"))
        XCTAssertEqual(try Codec.data(before),original)
        before=project(scene);edited=scene;edited.mediaPresentation=MediaPresentation()
        let next=try Editor.apply([.replaceScene(scene.id,edited)],to:before,baseRevision:before.current.id,
            assets:[asset],message:"正常新版本")
        XCTAssertThrowsError(try Editor.apply([.replaceScene(scene.id,scene)],to:next,baseRevision:before.current.id,
            assets:[asset],message:"不能覆盖过时版本"))
    }

    func testSplitAndNormalRestorePreserveExplicitModeAndActualSourceWindows() throws {
        let asset=videoAsset();var scene=mediaScene(asset);scene.mediaPresentation=MediaPresentation()
        let before=project(scene)
        let split=try Editor.apply([.splitScene(scene.id,60)],to:before,baseRevision:before.current.id,assets:[asset],message:"正常拆分")
        XCTAssertEqual(split.current.scenes.map(\.mediaPresentation),[scene.mediaPresentation,scene.mediaPresentation])
        XCTAssertEqual(split.current.scenes.map(\.sourceStartFrame),[30,90])
        XCTAssertEqual(split.current.scenes.map(\.sourceEndFrame),[90,150])
        let restored=try Editor.apply([.restore(before.current.id)],to:split,baseRevision:split.current.id,assets:[asset],message:"恢复原完整源窗")
        XCTAssertEqual(restored.current.scenes,[scene])
        XCTAssertEqual(try Codec.data(restored.revisions[0]),try Codec.data(before.current))
        XCTAssertEqual(try Codec.decoder().decode(Scene.self,from:Codec.data(scene)),scene)
    }
}
