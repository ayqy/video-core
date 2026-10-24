import XCTest
@testable import VideoCore

final class TeachingTests: XCTestCase {
    private let now=Date(timeIntervalSince1970:1_790_000_000)
    private func fixture(_ grammar:NarrativeGrammar = .practice)->(TeachingInput,[Asset],[Evidence],NarrativeTemplate,StyleKit){
        var source=Asset(workspaceID:"w",name:"讲稿.txt",hash:"source-hash",ext:"txt",bytes:42,mediaType:"text")
        var page=CoursePage(number:1,text:"提出问题，再用原文依据检验结论。");page.confirmed=true;source.pages=[page]
        var evidence=Evidence(workspaceID:"w",title:"原文事实与权利",source:"https://example.org/document",claim:page.text,owner:"原作者",commercialAllowed:true,verified:true);evidence.checkedAt=now.addingTimeInterval(-10)
        var mapping=CourseMapping(title:"核对原文",knowledge:page.text,audience:"学习者",task:"标注依据",outcome:"留下有来源的结论",prerequisite:"能阅读原文",assetID:source.id,rangeKind:.pages,start:1,end:1,evidenceIDs:[evidence.id],confirmed:true)
        mapping.id="mapping"
        var context=ContentContext(workspaceID:"w",name:"材料小课");context.assetIDs=[source.id];context.courseMappings=[mapping]
        let topic=TeachingTopic(workspaceID:"w",name:"材料小课",audience:"学习者",task:"标注依据",knowledge:page.text,hook:"如何区分摘抄和结论？",outcome:"写下一条可检验的结论",prerequisite:"能阅读原文",proof:"打开原文，标记结论对应的句子。",boundary:"只说明材料核对方法，不承诺学习结果。",evidenceIDs:[evidence.id],mappingIDs:[mapping.id])
        var input=TeachingInput(topic:topic,contentContext:context,grammar:grammar,sources:[NarrativeSource(assetID:source.id,pages:[1],excerpt:page.text,confirmed:true)],aspect:.landscape)
        input.steps=["提出问题","标出原文依据"];input.startingPoint="没有标注来源的摘抄";input.response="每条结论应能回到原文";input.result="本例留下一条可核对的笔记";input.analogy="像给抽屉标记来源，人的记忆并非抽屉。";input.counterargument="摘抄多是否更可靠？";input.comparedSubject="另一种整理方式";input.comparisonBasis="同一段原文";input.simulation=Simulation();input.costItems=[NarrativeCostItem(label:"纸张",money:Money(2),evidenceID:evidence.id)]
        return(input,[source],[evidence],NarrativeTemplate(workspaceID:"w",name:"原文教学"),StyleKit(workspaceID:"w",name:"纯讲解"))
    }
    private func compose(_ input:TeachingInput,_ assets:[Asset],_ evidence:[Evidence],_ template:NarrativeTemplate,_ style:StyleKit)throws->TeachingDocument{
        try TeachingPlanner.compose(input:input,assets:assets,evidence:evidence,template:template,style:style,now:now)
    }
    func testHistoricalMappingsRemainReadableAfterSourceCorrectionButCurrentConfirmationFails()throws{
        let(i,a,e,t,s)=fixture();let document=try compose(i,a,e,t,s)
        var database=Database();var workspace=Workspace(name:"真实工作区",owner:"作者");workspace.id="w"
        database.workspaces=[workspace];database.assets=a;database.evidence=e
        database.projects=[Project(workspaceID:"w",name:"材料小课",revision:document.revision)]
        database.teachingTopics=[i.topic];database.teachingDocuments=[document]
        database.assets[0].pages[0].text="修改后的校对稿，等待核实";database.assets[0].pages[0].confirmed=false
        XCTAssertNoThrow(try database.validate())
        XCTAssertFalse(TeachingPlanner.confirmationIssues(document:document,assets:database.assets,evidence:e,now:now).isEmpty)
        XCTAssertThrowsError(try DependencyRules.validateMappings(context:i.contentContext,assets:database.assets,evidence:e))
    }
    func testOrdinaryTeachingHasTrueContentContextAndNoProductOrForcedAction()throws{
        let(i,a,e,t,s)=fixture();let document=try compose(i,a,e,t,s)
        XCTAssertNil(document.revision.product);XCTAssertEqual(document.revision.schemaVersion,2)
        XCTAssertEqual(document.revision.cta,"");XCTAssertFalse(document.beats.contains{$0.role == .action})
        XCTAssertEqual(document.revision.contentContext?.id,i.contentContext.id)
        XCTAssertTrue(document.beats.contains{$0.role == .knowledge && $0.text == i.topic.knowledge})
        XCTAssertTrue(document.beats.contains{$0.role == .demonstration && $0.text == i.topic.proof})
        XCTAssertEqual(document.revision.dependencies?.contentContextID,i.contentContext.id)
    }
    func testAllGrammarsUseActualInputsAndSeriesBinding()throws{
        for grammar in NarrativeGrammar.allCases{
            let(i,a,e,t,s)=fixture(grammar)
            let series=grammar == .series ? SeriesProfile(workspaceID:"w",name:"知识小课",style:s,template:t,episodePrefix:"小课",recurringQuestion:"如何核对？"):nil
            let document=try TeachingPlanner.compose(input:i,assets:a,evidence:e,template:t,style:s,series:series,now:now)
            XCTAssertTrue(document.beats.contains{$0.role == .knowledge})
            XCTAssertTrue(document.beats.contains{$0.role == .boundary})
            XCTAssertFalse(document.revision.scenes.contains{$0.kind == .cartoon})
            XCTAssertFalse(document.confirmed)
        }
    }
    func testLongKnowledgeIsSplitWithoutLosingUnicodeContent()throws{
        var(i,a,e,t,s)=fixture();i.topic.knowledge=String(repeating:"原文依据🙂",count:95)
        let document=try compose(i,a,e,t,s),texts=document.beats.filter{$0.role == .knowledge}.map(\.text)
        XCTAssertGreaterThan(texts.count,1);XCTAssertEqual(texts.joined(),i.topic.knowledge)
        XCTAssertTrue(texts.allSatisfy{$0.count<=160})
    }
    func testUnconfirmedPageAndCrossWorkspaceSourcesAreRejected()throws{
        var(i,a,e,t,s)=fixture();a[0].pages[0].confirmed=false
        XCTAssertThrowsError(try compose(i,a,e,t,s));a[0].pages[0].confirmed=true;a[0].workspaceID="other"
        XCTAssertThrowsError(try compose(i,a,e,t,s))
    }
    func testActualDemonstrationUsesExactRecordingRange()throws{
        var(i,a,e,t,s)=fixture();var recording=Asset(workspaceID:"w",name:"recording.mov",hash:"video",ext:"mov",bytes:10,mediaType:"video",durationFrames:900)
        recording.id="recording";a.append(recording);i.sources=[NarrativeSource(assetID:recording.id,startFrame:210,endFrame:330,excerpt:"真实演示",confirmed:true)]
        let document=try compose(i,a,e,t,s),scenes=document.revision.scenes.filter{$0.kind == .video}
        XCTAssertFalse(scenes.isEmpty);XCTAssertTrue(scenes.allSatisfy{$0.assetID==recording.id && $0.sourceStartFrame==210 && $0.sourceEndFrame==330 && $0.durationFrames<=120})
        i.sources[0].endFrame=901;XCTAssertThrowsError(try compose(i,a,e,t,s))
    }
    func testExpiredEvidenceCannotConfirmAndNeverBecomesVerified()throws{
        let(i,a,e,t,s)=fixture();var document=try compose(i,a,e,t,s);var expired=e;expired[0].expiresAt=now.addingTimeInterval(-1)
        XCTAssertThrowsError(try document.confirm(reviewer:"作者",assets:a,evidence:expired,now:now));XCTAssertFalse(document.confirmed)
        XCTAssertFalse(TeachingPlanner.confirmationIssues(document:document,assets:a,evidence:expired,now:now).isEmpty)
    }
    func testUnsupportedQuantitativeClaimRemainsDraft()throws{
        var(i,a,e,t,s)=fixture(.beforeAfter);i.topic.evidenceIDs=[];i.result="效率提升99%"
        var document=try compose(i,a,e,t,s)
        XCTAssertThrowsError(try document.confirm(reviewer:"作者",assets:a,evidence:e,now:now));XCTAssertFalse(document.confirmed)
    }
    func testAbsoluteGuaranteeCannotBeConfirmedByUnrelatedEvidence()throws{
        var(i,a,e,t,s)=fixture();i.topic.knowledge="保证收益，无风险收益。"
        var document=try compose(i,a,e,t,s);XCTAssertThrowsError(try document.confirm(reviewer:"作者",assets:a,evidence:e,now:now))
    }
    func testRewriteRecordsDiffAndInvalidatesConfirmationAndVoice()throws{
        var(i,a,e,t,s)=fixture();var document=try compose(i,a,e,t,s)
        a.append(Asset(workspaceID:"w",name:"voice.wav",hash:"audio",ext:"wav",bytes:20,mediaType:"audio",durationFrames:60));a[a.count-1].id="voice"
        let id=document.revision.scenes[0].id,old=document.revision.scenes[0].body
        document.revision.scenes[0].voice=VoiceTake(assetID:"voice",textDigest:try document.revision.scenes[0].speechDigest(),durationFrames:60,method:"import",listened:true)
        document.revision.dependencies=try DependencyRules.freeze(revision:document.revision,assets:a,evidence:e,now:now)
        try document.confirm(reviewer:"作者",assets:a,evidence:e,now:now);XCTAssertTrue(document.confirmed)
        try document.rewrite(sceneID:id,text:"先提出一个可核对的问题。",author:"作者",reason:"明确知识边界",assets:a,now:now)
        XCTAssertFalse(document.confirmed);XCTAssertNil(document.revision.scenes[0].voice)
        XCTAssertEqual(document.rewrites[0].before,old);XCTAssertEqual(document.rewrites[0].after,"先提出一个可核对的问题。")
        XCTAssertFalse(document.revision.review.complete)
    }
    func testPaperRewriteKeepsShortVisualTextAndChangesOnlyCompleteNarration()throws{
        let(i,a,e,t,s)=fixture();var document=try compose(i,a,e,t,s)
        document.revision.scenes[0].paperPresentation=PaperPresentation(layout:.cover)
        document.revision.scenes[0].body="先找到原文"
        let id=document.revision.scenes[0].id,oldNarration=document.revision.scenes[0].narration
        document.revision.scenes[0].voice=VoiceTake(assetID:"voice",textDigest:try document.revision.scenes[0].speechDigest(),durationFrames:60,method:"import",listened:true)
        try document.rewrite(sceneID:id,text:"看似相同的摘抄，为什么会得出不同结论？",author:"作者",reason:"加入有依据的开场问题",assets:a,now:now)
        XCTAssertEqual(document.revision.scenes[0].body,"先找到原文")
        XCTAssertEqual(document.revision.scenes[0].narration,"看似相同的摘抄，为什么会得出不同结论？")
        XCTAssertEqual(document.rewrites[0].before,oldNarration)
        XCTAssertNil(document.revision.scenes[0].voice);XCTAssertFalse(document.confirmed)
    }
    func testPaperNarrationClaimsCannotHideBehindAShortVisualSummary()throws{
        let(i,a,e,t,s)=fixture();var document=try compose(i,a,e,t,s)
        document.revision.scenes[0].paperPresentation=PaperPresentation()
        document.revision.scenes[0].body="核对依据"
        document.revision.scenes[0].narration="保证收益，效率提升99%。"
        document.revision.scenes[0].captions=[Caption(text:"保证收益，效率提升99%。",startFrame:0,endFrame:60)]
        document.input.topic.evidenceIDs=[]
        let issues=TeachingPlanner.confirmationIssues(document:document,assets:a,evidence:e,now:now)
        XCTAssertEqual(issues.filter{$0.contains("绝对效果或收益保证")}.count,1)
        XCTAssertEqual(issues.filter{$0.contains("效果、数值或对比主张")}.count,1)
    }
    func testVerticalChecklistRejectsExpiredOrUncheckedFactsAndSupportsCustomItems()throws{
        let(_,_,e,_,_)=fixture()
        let requirement=ChecklistRequirement(label:"当期政策来源",maximumAgeDays:30)
        var checklist=WorkspaceVerticalChecklist(workspaceID:"w",template:VerticalChecklistTemplate(name:"留学",requirements:[requirement]))
        XCTAssertEqual(checklist.reviewIssues(evidence:e,commercial:false,now:now).count,2)
        checklist.checked[requirement.id]=true;checklist.evidence[requirement.id]=[e[0].id]
        XCTAssertTrue(checklist.reviewIssues(evidence:e,commercial:false,now:now).isEmpty)
        var old=e;old[0].checkedAt=now.addingTimeInterval(-31*86400)
        XCTAssertFalse(checklist.reviewIssues(evidence:old,commercial:false,now:now).isEmpty)
    }
    func testOptionalProductPreservesExactFactsAndStalesOnPriceChange()throws{
        var(i,a,e,t,s)=fixture()
        let product=Product(workspaceID:"w",sku:"actual-course",name:"已有课程",checkout:"https://example.org/existing-course",audience:"学习者",task:"核对原文",outcome:"标注依据",prerequisite:"中文阅读",scope:"材料整理",prices:[Price(money:Money(99),from:now.addingTimeInterval(-100),source:"原页面",verified:true)])
        i.topic.productID=product.id;i.topic.mappingIDs=[];i.contentContext.courseMappings=[]
        var document=try TeachingPlanner.compose(input:i,product:product,assets:a,evidence:e,template:t,style:s,now:now)
        XCTAssertEqual(document.revision.product,product);XCTAssertEqual(document.revision.schemaVersion,1);XCTAssertNil(document.revision.contentContext)
        try document.confirm(reviewer:"作者",assets:a,evidence:e,currentProduct:product,now:now)
        var changed=product;changed.prices[0].money=Money(200)
        XCTAssertThrowsError(try document.confirm(reviewer:"作者",assets:a,evidence:e,currentProduct:changed,now:now))
    }
    func testTemplateReuseRequiresExplicitSeriesVersionAndNoFamiliarCharacterSubstitute()throws{
        let(i,a,e,t,s)=fixture(.series);let series=SeriesProfile(workspaceID:"w",name:"固定栏目",style:s,template:t,episodePrefix:"栏目",recurringQuestion:"如何核对")
        var other=s;other.version+=1
        XCTAssertThrowsError(try TeachingPlanner.compose(input:i,assets:a,evidence:e,template:t,style:other,series:series,now:now))
        var cartoon=t;cartoon.beats=[TemplateBeat(role:.knowledge,frames:120,kind:.cartoon)]
        let original=StyleKit(workspaceID:"w",name:"原创圆方",characters:[CharacterProfile(name:"抽象圆仔")])
        XCTAssertThrowsError(try TeachingPlanner.compose(input:i,assets:a,evidence:e,template:cartoon,style:original,series:SeriesProfile(workspaceID:"w",name:"栏目",style:original,template:cartoon,episodePrefix:"栏目",recurringQuestion:"如何核对"),now:now))
    }
}


final class ContentAssetMatchingTests:XCTestCase{
    func testSearchMatchesChineseTagsAndNeverOtherWorkspace()throws{
        var first=Asset(workspaceID:"w",name:"资料.png",hash:"a",ext:"png",bytes:1,mediaType:"image");first.tags=["时间轴剪辑"]
        var second=first;second.id="second";second.workspaceID="another";second.name="时间轴剪辑.png"
        let matches=ContentAssetMatching.search(query:"怎样进行时间轴剪辑",workspaceID:"w",assets:[first,second],evidence:[])
        XCTAssertEqual(matches.map(\.id),[first.id]);XCTAssertTrue(matches[0].fields.contains("标签"));XCTAssertFalse(matches[0].matchedTerms.isEmpty)
        XCTAssertTrue(ContentAssetMatching.search(query:"无关法语",workspaceID:"w",assets:[first],evidence:[]).isEmpty)
    }
    func testReplacementPreservesOtherSceneAndRefusesLockedScene()throws{
        let image=Asset(workspaceID:"w",name:"真正图片.png",hash:"image",ext:"png",bytes:10,mediaType:"image")
        let original=Scene(title:"保留的文字",body:"准确知识",narration:"准确知识",durationFrames:180)
        let other=Scene(title:"另一个场景",body:"不变",durationFrames:180)
        let revision=Revision(contentContext:ContentContext(workspaceID:"w",name:"普通片"),aspect:.landscape,scenes:[original,other])
        let project=Project(workspaceID:"w",name:"普通片",revision:revision)
        let replacement=try ContentAssetMatching.replacing(scene:original,asset:image,workspaceID:"w",lockAfter:true,assets:[image])
        let updated=try Editor.apply([.replaceScene(original.id,replacement)],to:project,baseRevision:revision.id,assets:[image],message:"手动替换")
        XCTAssertEqual(updated.current.scenes[0].assetID,image.id);XCTAssertEqual(updated.current.scenes[0].body,original.body)
        XCTAssertTrue(updated.current.scenes[0].locked);XCTAssertEqual(updated.current.scenes[1],other)
        XCTAssertThrowsError(try ContentAssetMatching.replacing(scene:replacement,asset:image,workspaceID:"w",lockAfter:false,assets:[image]))
    }
    func testReplacementChecksActualMediaRangeAndProtectsSentenceTail()throws{
        let video=Asset(workspaceID:"w",name:"录屏.mov",hash:"video",ext:"mov",bytes:10,mediaType:"video",durationFrames:900)
        var scene=Scene(title:"原镜头",body:"保留旁白",durationFrames:300);scene.voice=VoiceTake(assetID:"voice",textDigest:try scene.speechDigest(),durationFrames:270,method:"import",listened:true)
        XCTAssertThrowsError(try ContentAssetMatching.replacing(scene:scene,asset:video,workspaceID:"w",startFrame:0,endFrame:200,lockAfter:false,assets:[video]))
        XCTAssertThrowsError(try ContentAssetMatching.replacing(scene:scene,asset:video,workspaceID:"w",startFrame:800,endFrame:1000,lockAfter:false,assets:[video]))
        let replacement=try ContentAssetMatching.replacing(scene:scene,asset:video,workspaceID:"w",startFrame:300,endFrame:600,lockAfter:false,assets:[video])
        XCTAssertEqual(replacement.sourceStartFrame,300);XCTAssertEqual(replacement.sourceEndFrame,600);XCTAssertEqual(replacement.durationFrames,300)
        XCTAssertThrowsError(try ContentAssetMatching.replacing(scene:scene,asset:video,workspaceID:"other",startFrame:300,endFrame:600,lockAfter:false,assets:[video]))
    }
}
