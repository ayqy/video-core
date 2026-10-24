import XCTest
import VideoCore

final class PaperPresentationTests: XCTestCase {
    func testStrictDecodeRejectsUnknownMissingVersionLayoutAndColors() throws {
        let value=PaperPresentation(layout:.cover,paperColor:"FFF9EF",inkColor:"243638")
        XCTAssertEqual(try Codec.decoder().decode(PaperPresentation.self,from:Codec.data(value)),value)
        for raw in [
            #"{"version":1,"layout":"cover","paperColor":"FFF9EF","inkColor":"243638","execute":"never"}"#,
            #"{"layout":"cover","paperColor":"FFF9EF","inkColor":"243638"}"#,
            #"{"version":2,"layout":"cover","paperColor":"FFF9EF","inkColor":"243638"}"#,
            #"{"version":1,"layout":"poster","paperColor":"FFF9EF","inkColor":"243638"}"#,
            #"{"version":1,"layout":"cover","paperColor":"FFF9EF\n","inkColor":"243638"}"#,
            ##"{"version":1,"layout":"cover","paperColor":"FFF9EF","inkColor":"#243638"}"##
        ] {XCTAssertThrowsError(try Codec.decoder().decode(PaperPresentation.self,from:Data(raw.utf8)))}
        var bad=value;bad.paperColor="GGGGGG";XCTAssertThrowsError(try bad.validate())
        bad=value;bad.version=Int.max;XCTAssertThrowsError(try bad.validate())
    }

    func testOldSceneEncodingAndDigestOmitPaperAndEntrance() throws {
        var scene=Scene(title:"原工程",body:"原来的画面",durationFrames:120)
        scene.layers=[SceneLayer(kind:.text,text:"原元素",endFrame:120)]
        let bytes=try Codec.data(scene),text=String(decoding:bytes,as:UTF8.self)
        XCTAssertFalse(text.contains("paperPresentation"));XCTAssertFalse(text.contains("entrance"))
        let decoded=try Codec.decoder().decode(Scene.self,from:bytes)
        XCTAssertNil(decoded.paperPresentation);XCTAssertNil(decoded.layers?[0].entrance)
        XCTAssertEqual(try Codec.data(decoded),bytes);XCTAssertEqual(try Codec.digest(decoded),Codec.hash(bytes))
        scene.paperPresentation=PaperPresentation()
        XCTAssertNotEqual(try Codec.digest(scene),Codec.hash(bytes))
    }

    func testPaperCanOnlyBindOrdinaryExplanationWithoutChangingItsNarration() throws {
        var scene=Scene(title:"不出钱，反而赚更多？",body:"个人选择，共同结果",narration:"这里保存完整讲解，画面只保留一个重点。",durationFrames:120)
        scene.paperPresentation=PaperPresentation(layout:.cover)
        XCTAssertNoThrow(try scene.validate(assets:[]))
        let restored=try Codec.decoder().decode(Scene.self,from:Codec.data(scene))
        XCTAssertEqual(restored.narration,scene.narration);XCTAssertEqual(restored.body,scene.body)
        var legacy=scene;legacy.paperPresentation=nil
        let context=ContentContext(workspaceID:"w",name:"版本复盘")
        let before=Revision(contentContext:context,aspect:.landscape,scenes:[legacy])
        let after=Revision(contentContext:context,aspect:.landscape,scenes:[scene])
        let difference=try XCTUnwrap(RevisionDifference.compare(before,after).first{$0.scope == "纸面呈现"})
        XCTAssertEqual(difference.before,"原版式")
        XCTAssertEqual(difference.after,"封面 · v1 · 纸色 #FFF9EF · 墨色 #243638")
        var recolored=after;recolored.scenes[0].paperPresentation=PaperPresentation(layout:.explanation,paperColor:"FFE4B5",inkColor:"221144")
        let changed=try XCTUnwrap(RevisionDifference.compare(after,recolored).first{$0.scope == "纸面呈现"})
        XCTAssertEqual(changed.before,difference.after)
        XCTAssertEqual(changed.after,"纸面讲解 · v1 · 纸色 #FFE4B5 · 墨色 #221144")
        for kind in SceneKind.allCases where kind != .explanation {
            var wrong=scene;wrong.kind=kind;XCTAssertThrowsError(try wrong.validate(assets:[]))
        }
    }

    func testNormalSchemaDiscoversStrictOptionalPaperAndEntranceTypes() throws {
        let definitions=AgentSchemas.definitions()
        for name in ["PaperPresentation","LayerEntrance"] {
            XCTAssertEqual(definitions[name]?.object?["additionalProperties"],.boolean(false))
            XCTAssertEqual(definitions[name]?.object?["properties"]?.object?["version"]?.object?["const"],.number(1))
        }
        XCTAssertNotNil(definitions["Scene"]?.object?["properties"]?.object?["paperPresentation"])
        XCTAssertNotNil(definitions["SceneLayer"]?.object?["properties"]?.object?["entrance"])
        XCTAssertEqual(definitions["PaperLayout"]?.object?["enum"],.array([.string("cover"),.string("explanation")]))
        XCTAssertEqual(definitions["LayerEntranceKind"]?.object?["enum"],.array([.string("fade"),.string("revealLeft")]))
        let schema=try XCTUnwrap(AgentContract.inputSchema("edit apply").object)
        XCTAssertNotNil(schema["$defs"]?.object?["PaperPresentation"])
    }

    func testPaperAndEntranceEditsInvalidateSpecificVoiceCaptionsAndWholeReview() throws {
        for change in 0..<4 {
            var scene=Scene(title:"单一重点",body:"共同道路",narration:"先看三个人如何投入。",durationFrames:120)
            scene.paperPresentation=PaperPresentation()
            var layer=SceneLayer(kind:.rectangle,endFrame:120);layer.entrance=LayerEntrance(startFrame:10,endFrame:60);scene.layers=[layer]
            scene.voice=VoiceTake(assetID:"voice",textDigest:try scene.speechDigest(),durationFrames:100,method:"import",listened:true)
            var caption=Caption(text:scene.narration,startFrame:0,endFrame:100);caption.confirmed=true;scene.captions=[caption]
            var p=Project(workspaceID:"w",name:"手绘知识",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"手绘知识"),aspect:.landscape,scenes:[scene]))
            p.revisions[0].review.sound=true;p.revisions[0].review.captions=true;p.revisions[0].review.fullPreview=true
            var edited=scene
            switch change {
            case 0:edited.paperPresentation?.paperColor="FFE4B5"
            case 1:edited.layers?[0].entrance?.kind = .revealLeft
            case 2:edited.speed=2
            default:edited.pauseFrames=15
            }
            let next=try Editor.apply([.replaceScene(scene.id,edited)],to:p,baseRevision:p.current.id,assets:[],message:"调整纸面与节拍")
            XCTAssertFalse(try XCTUnwrap(next.current.scenes[0].voice).listened)
            XCTAssertFalse(next.current.scenes[0].captions[0].confirmed)
            XCTAssertFalse(next.current.review.sound);XCTAssertFalse(next.current.review.captions);XCTAssertFalse(next.current.review.fullPreview)
            XCTAssertTrue(next.current.invalidated.contains("纸面呈现、图形入场与声音字幕重新复核"))
            XCTAssertTrue(p.current.scenes[0].voice!.listened)
        }
    }

    func testLockedSceneAndLayerCannotUseNewFieldsToBypassProtection() throws {
        var scene=Scene(title:"锁定内容",body:"保留原版",durationFrames:120)
        scene.paperPresentation=PaperPresentation()
        var layer=SceneLayer(kind:.rectangle,endFrame:120);layer.entrance=LayerEntrance();layer.locked=true;scene.layers=[layer]
        var p=Project(workspaceID:"w",name:"锁定知识",revision:Revision(contentContext:ContentContext(workspaceID:"w",name:"知识"),aspect:.landscape,scenes:[scene]))
        var changed=scene;changed.layers?[0].entrance?.endFrame=30
        XCTAssertThrowsError(try Editor.apply([.replaceScene(scene.id,changed)],to:p,baseRevision:p.current.id,assets:[],message:"拒绝改锁定层"))
        p.revisions[0].scenes[0].locked=true;changed=scene;changed.paperPresentation?.layout = .cover
        XCTAssertThrowsError(try Editor.apply([.replaceScene(scene.id,changed)],to:p,baseRevision:p.current.id,assets:[],message:"拒绝改锁定镜头"))
        XCTAssertThrowsError(try Editor.apply([.splitScene(scene.id,60)],to:p,baseRevision:p.current.id,assets:[],message:"拒绝拆锁定镜头"))
    }
}
