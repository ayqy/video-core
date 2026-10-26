import XCTest
@testable import VideoCore

final class ContentProjectTests:XCTestCase {
    private func fixture()throws->(Database,Workspace,Project) {
        let workspace=Workspace(name:"实际视频工程",owner:"owner")
        var revision=try Planner.create(workspaceID:workspace.id,name:"教学剪辑",scenes:[Scene(title:"观察变化",body:"先观察，再记录实际结果。",durationFrames:60)])
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[],evidence:[])
        let project=Project(workspaceID:workspace.id,name:"教学剪辑",revision:revision)
        var database=Database();database.workspaces=[workspace];database.projects=[project]
        return(database,workspace,project)
    }
    private func product(_ workspace:String)->Product {
        Product(workspaceID:workspace,sku:"existing",name:"已有课程",checkout:"https://example.org/course",audience:"学习者",task:"观察",outcome:"记录结果",prerequisite:"无",scope:"实际资料",prices:[Price(money:Money(99),from:.distantPast,source:"实际资料引用",verified:true)])
    }
    func testOrdinaryProjectHasNoSyntheticProductPriceCheckoutOrCTA()throws {
        let(db,w,p)=try fixture()
        XCTAssertNil(p.current.product);XCTAssertEqual(p.current.workspaceID,w.id);XCTAssertEqual(p.current.contentName,p.name);XCTAssertEqual(p.current.cta,"")
        XCTAssertTrue(db.products.isEmpty);XCTAssertNoThrow(try db.validate())
        XCTAssertTrue(try Quality.inspect(p.current,database:db,requireReview:false).isEmpty)
        let encoded=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(p.current)) as? [String:Any])
        XCTAssertNil(encoded["product"]);XCTAssertNotNil(encoded["contentContext"])
        for key in ["sku","prices","checkout"] {XCTAssertNil((encoded["contentContext"] as? [String:Any])?[key])}
    }
    func testEmptyDraftIsEditableButCannotRenderUntilRealContentExists()throws {
        let revision=try Planner.create(workspaceID:"w",name:"新剪辑")
        XCTAssertTrue(revision.scenes.isEmpty)
        XCTAssertTrue(try Quality.inspect(revision,database:Database(),requireReview:false).contains{$0.id=="duration"})
        XCTAssertThrowsError(try Planner.create(workspaceID:"",name:"新剪辑"))
        XCTAssertThrowsError(try Planner.create(workspaceID:"w",name:" \n"))
    }
    func testNarrationCanCarryKnowledgeWithoutRepeatedScreenBodyWhileMediaGatesRemain()throws {
        let(base,w,p)=try fixture()
        let audio=Asset(workspaceID:w.id,name:"narration.wav",hash:String(repeating:"a",count:64),ext:"wav",bytes:10,mediaType:"audio",durationFrames:60)
        for body in [""," \n\t"] {
            var database=base,revision=p.current,scene=p.current.scenes[0]
            scene.body=body;scene.narration="路修成后，邻居都能使用。"
            scene.captions=[Caption(text:scene.narration,startFrame:0,endFrame:60)]
            scene.voice=VoiceTake(assetID:audio.id,textDigest:try scene.speechDigest(),durationFrames:60,method:"recorded")
            revision.scenes=[scene];revision.dependencies=nil;database.assets=[audio]
            XCTAssertTrue(try Quality.inspect(revision,database:database,requireReview:false).isEmpty)
            let pending=try Quality.inspect(revision,database:database,requireReview:true)
            XCTAssertFalse(pending.contains{$0.id==scene.id+"text"})
            XCTAssertTrue(pending.contains{$0.id==scene.id+"listened"})
            XCTAssertTrue(pending.contains{$0.id==scene.id+"captions"})
            XCTAssertTrue(pending.contains{$0.id=="review"})
            var missing=revision;missing.scenes[0].voice=nil
            XCTAssertTrue(try Quality.inspect(missing,database:database,requireReview:false).contains{$0.id==scene.id+"voice_missing"})
            var stale=revision;stale.scenes[0].voice?.textDigest="outdated"
            XCTAssertTrue(try Quality.inspect(stale,database:database,requireReview:false).contains{$0.id==scene.id+"voice"})
            var commercial=revision;commercial.purpose = .course
            XCTAssertTrue(try Quality.inspect(commercial,database:database,requireReview:false).contains{$0.id==audio.id+"audio_rights"})
        }
    }
    func testKnowledgeCannotBeEmptyOrWhitespaceInBothBodyAndNarration()throws {
        let(db,_,p)=try fixture()
        for (body,narration) in [("",""),(" \n\t",""),(""," \n\t"),("\n","\t")] {
            var revision=p.current
            revision.dependencies=nil;revision.scenes[0].body=body;revision.scenes[0].narration=narration
            XCTAssertTrue(try Quality.inspect(revision,database:db,requireReview:false).contains{$0.id==revision.scenes[0].id+"text"})
        }
    }
    func testSceneTitleRequiresVisibleTextEvenWhenKnowledgeExists()throws {
        let(db,_,p)=try fixture()
        for title in [""," \n\t"] {
            var revision=p.current
            revision.dependencies=nil;revision.scenes[0].title=title
            XCTAssertTrue(try Quality.inspect(revision,database:db,requireReview:false).contains{$0.id==revision.scenes[0].id+"text"})
        }
    }
    func testScreenBodyCanCarryKnowledgeWithoutNarration()throws {
        let(db,_,p)=try fixture();var revision=p.current
        revision.dependencies=nil;revision.scenes[0].body=" \n观察人物选择与结果。\t";revision.scenes[0].narration=""
        XCTAssertTrue(try Quality.inspect(revision,database:db,requireReview:false).isEmpty)
    }
    func testEmptyDraftCanAddRealSceneAndReturnToEmptyWithoutPlaceholder()throws {
        let w=Workspace(name:"编辑空间",owner:"owner")
        let revision=try Planner.create(workspaceID:w.id,name:"真实空工程")
        let empty=Project(workspaceID:w.id,name:"真实空工程",revision:revision)
        let scene=Scene(title:"用户输入的内容",body:"实际解释",durationFrames:30)
        let added=try Editor.apply([.insertScene(scene,0)],to:empty,baseRevision:revision.id,assets:[],message:"添加实际片段")
        XCTAssertEqual(added.current.scenes.map(\.id),[scene.id])
        let removed=try Editor.apply([.removeScene(scene.id)],to:added,baseRevision:added.current.id,assets:[],message:"删回空草稿")
        XCTAssertTrue(removed.current.scenes.isEmpty)
        var database=Database();database.workspaces=[w];database.projects=[removed]
        XCTAssertNoThrow(try database.validate())
        XCTAssertTrue(try Quality.inspect(removed.current,database:database,requireReview:false).contains{$0.id=="duration"})
        XCTAssertTrue(try Codec.decoder().decode(Project.self,from:Codec.data(removed)).current.scenes.isEmpty)
    }
    func testOrdinaryAndLegacyIRVersionsCannotBeSilentlyMixed()throws {
        let(_,_,p)=try fixture()
        XCTAssertEqual(p.current.schemaVersion,2);XCTAssertEqual(p.current.dependencies?.version,2)
        var wrong=p.current;wrong.schemaVersion=1
        XCTAssertThrowsError(try wrong.validateContext())
        XCTAssertThrowsError(try Codec.decoder().decode(Revision.self,from:Codec.data(wrong)))
        var legacy=Revision(product:product("w"),purpose:.education,aspect:.landscape,scenes:[Scene(title:"旧内容",body:"旧资料")],cta:"")
        legacy.dependencies=try DependencyRules.freeze(revision:legacy,assets:[],evidence:[])
        XCTAssertEqual(legacy.schemaVersion,1);XCTAssertEqual(legacy.dependencies?.version,1)
        legacy.schemaVersion=2;XCTAssertThrowsError(try legacy.validateContext())
    }
    func testRestoreKeepsHistoricalContextAndItsIRVersionTogether()throws {
        let(db,w,p)=try fixture()
        var legacy=Revision(product:product(w.id),purpose:.education,aspect:.landscape,scenes:p.current.scenes,cta:"")
        legacy.dependencies=try DependencyRules.freeze(revision:legacy,assets:[],evidence:[])
        var mixed=p;mixed.revisions=[legacy,p.current]
        let restored=try Editor.apply([.restore(legacy.id)],to:mixed,baseRevision:p.current.id,assets:[],message:"恢复已有产品版本")
        XCTAssertEqual(restored.current.schemaVersion,1);XCTAssertEqual(restored.current.product?.id,legacy.product?.id);XCTAssertNil(restored.current.contentContext)
        XCTAssertTrue(DependencyRules.diff(revision:restored.current,assets:[],evidence:[]).isEmpty)
        var database=db;database.projects=[restored];XCTAssertNoThrow(try database.validate())
        let ordinary=try Editor.apply([.restore(p.current.id)],to:restored,baseRevision:restored.current.id,assets:[],message:"恢复普通剪辑版本")
        XCTAssertEqual(ordinary.current.schemaVersion,2);XCTAssertEqual(ordinary.current.contentContext,p.current.contentContext);XCTAssertNil(ordinary.current.product)
        database.projects=[ordinary];XCTAssertNoThrow(try database.validate())
    }
    func testLegacyProductRevisionRoundTripKeepsDigestAndProductFacts()throws {
        let original=Revision(product:product("w"),purpose:.course,aspect:.portrait,scenes:[Scene(title:"原项目",body:"保留原内容")],cta:"查看原资料")
        var wire=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(original)) as? [String:Any]);wire.removeValue(forKey:"contentContext")
        let restored=try Codec.decoder().decode(Revision.self,from:JSONSerialization.data(withJSONObject:wire))
        XCTAssertNil(restored.contentContext);XCTAssertEqual(restored.workspaceID,"w")
        XCTAssertEqual(try restored.contentDigest(),try original.contentDigest())
        XCTAssertEqual(restored.product?.sku,"existing");XCTAssertEqual(restored.product?.prices.first?.money,Money(99))
    }
    func testDecodeRejectsMissingOrAmbiguousContextInsteadOfInventingProduct()throws {
        let(_,_,p)=try fixture()
        var wire=try XCTUnwrap(JSONSerialization.jsonObject(with:Codec.data(p.current)) as? [String:Any]);wire.removeValue(forKey:"contentContext")
        XCTAssertThrowsError(try Codec.decoder().decode(Revision.self,from:JSONSerialization.data(withJSONObject:wire)))
        wire["contentContext"]=try JSONSerialization.jsonObject(with:Codec.data(ContentContext(workspaceID:"another",name:"另一工程")))
        wire["product"]=try JSONSerialization.jsonObject(with:Codec.data(product("w")))
        XCTAssertThrowsError(try Codec.decoder().decode(Revision.self,from:JSONSerialization.data(withJSONObject:wire)))
    }
    func testProjectDecodeAndDatabaseRejectForeignWorkspaceRevision()throws {
        let(db,_,p)=try fixture();var foreign=p
        foreign.revisions[0].contentContext?.workspaceID="another"
        XCTAssertThrowsError(try Codec.decoder().decode(Project.self,from:Codec.data(foreign)))
        var invalid=db;invalid.projects=[foreign];XCTAssertThrowsError(try invalid.validate())
        var ambiguous=p.current;ambiguous.product=product(p.workspaceID)
        XCTAssertThrowsError(try ambiguous.validateContext())
    }
    func testSourceGraphStillRejectsCrossWorkspaceAndTracksChangedContent()throws {
        let(_,w,p)=try fixture()
        var asset=Asset(workspaceID:w.id,name:"原录屏.mov",hash:String(repeating:"a",count:64),ext:"mov",bytes:10,mediaType:"video",durationFrames:90)
        var revision=p.current;revision.scenes[0].kind = .video;revision.scenes[0].assetID=asset.id
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[asset],evidence:[])
        XCTAssertNil(revision.dependencies?.productID);XCTAssertEqual(revision.dependencies?.contentContextID,revision.contentContext?.id)
        XCTAssertTrue(DependencyRules.diff(revision:revision,assets:[asset],evidence:[]).isEmpty)
        asset.hash=String(repeating:"b",count:64)
        XCTAssertTrue(DependencyRules.diff(revision:revision,assets:[asset],evidence:[]).contains{$0.reason == .changed})
        asset.workspaceID="foreign"
        XCTAssertThrowsError(try DependencyRules.freeze(revision:revision,assets:[asset],evidence:[]))
    }
    func testIndependentCourseMappingUsesRealWorkspaceWithoutProduct()throws {
        let(_,w,p)=try fixture()
        let asset=Asset(workspaceID:w.id,name:"演示.mov",hash:String(repeating:"a",count:64),ext:"mov",bytes:10,mediaType:"video",durationFrames:120)
        let mapping=CourseMapping(title:"真实演示",knowledge:"观察变化",audience:"学习者",task:"记录",outcome:"得到记录",prerequisite:"无",assetID:asset.id,rangeKind:.time,start:30,end:90,confirmed:true)
        var revision=p.current;revision.contentContext?.courseMappings=[mapping]
        revision.scenes[0]=try mapping.applying(to:revision.scenes[0],workspaceID:w.id,assets:[asset],evidence:[])
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[asset],evidence:[])
        XCTAssertEqual(revision.scenes[0].sourceStartFrame,30);XCTAssertTrue(DependencyRules.diff(revision:revision,assets:[asset],evidence:[]).isEmpty)
        XCTAssertThrowsError(try mapping.applying(to:revision.scenes[0],workspaceID:"foreign",assets:[asset],evidence:[]))
    }
    func testNoProductDoesNotPermitUnprovenCommercialClaimsOrPriceOverlay()throws {
        let(db,_,p)=try fixture();var revision=p.current;revision.purpose = .course
        revision.scenes[0].body="保证收益提升100倍";revision.scenes[0].showPrice=true
        let issues=try Quality.inspect(revision,database:db,requireReview:false)
        XCTAssertTrue(issues.contains{$0.id=="price_without_product"});XCTAssertTrue(issues.contains{$0.id.contains("claims-")})
    }
    func testNoProductDoesNotPermitUnlicensedCommercialMedia()throws {
        var(db,w,p)=try fixture();let asset=Asset(workspaceID:w.id,name:"source.png",hash:String(repeating:"a",count:64),ext:"png",bytes:10,mediaType:"image")
        var revision=p.current;revision.purpose = .course;revision.scenes[0].kind = .image;revision.scenes[0].assetID=asset.id;revision.dependencies=nil;db.assets=[asset]
        XCTAssertTrue(try Quality.inspect(revision,database:db,requireReview:false).contains{$0.id==asset.id+"rights"})
    }
    func testReviewStillBindsCurrentRevisionAndEditInvalidatesIt()throws {
        let(db,_,p)=try fixture();var revision=p.current
        revision.review.text=true;revision.review.rights=true;revision.review.fullPreview=true;revision.review.sound=true;revision.review.captions=true;revision.review.digest=try revision.contentDigest()
        XCTAssertTrue(try Quality.inspect(revision,database:db,requireReview:true).isEmpty)
        var approved=p;approved.revisions=[revision]
        let changed=try Editor.apply([.cta("")],to:approved,baseRevision:revision.id,assets:[],message:"保留无行动提示的视频")
        XCTAssertFalse(changed.current.review.complete);XCTAssertTrue(try Quality.inspect(changed.current,database:db,requireReview:true).contains{$0.id=="review"})
    }
    func testExplicitProductFactsStillRequireVerificationAndInvalidateChanges()throws {
        var(db,w,p)=try fixture();var fact=product(w.id);fact.prices[0].verified=false
        var revision=Revision(product:fact,purpose:.course,aspect:.landscape,scenes:p.current.scenes,cta:"")
        XCTAssertTrue(try Quality.inspect(revision,database:db,requireReview:false).contains{$0.id=="price"})
        fact.prices[0].verified=true;revision.product=fact;db.products=[fact]
        var bound=Project(workspaceID:w.id,name:"实际产品说明",revision:revision)
        let original=bound.current.id;fact.name="已修改的真实名称";bound=Editor.updateFacts(fact,project:bound)
        XCTAssertNotEqual(bound.current.id,original);XCTAssertFalse(bound.current.review.complete)
        XCTAssertEqual(Editor.updateFacts(fact,project:p).current.id,p.current.id)
    }
    func testJobSubmissionUsesRealContextWorkspaceAndRejectsForeignQuoteScope()throws {
        let(_,w,p)=try fixture();let r=p.current
        let quote=Quote(projectID:p.id,revisionID:r.id,digest:try r.contentDigest(),upper:Money(0),unit:"CNY",provider:"native",expiresAt:Date().addingTimeInterval(300),confirmed:true)
        XCTAssertEqual(try JobRules.submit(workspaceID:w.id,project:p,quote:quote,requestKey:"normal",existing:[],budget:BudgetPolicy()).workspaceID,w.id)
        XCTAssertThrowsError(try JobRules.submit(workspaceID:"foreign",project:p,quote:quote,requestKey:"normal",existing:[],budget:BudgetPolicy()))
    }
    func testNewCLICommandHasDiscoverableSceneSchemaAndOwnerAuthorization()throws {
        let descriptor=try AgentContract.describe("projects create")
        XCTAssertEqual(descriptor.required,["workspace_id","name"]);XCTAssertTrue(descriptor.optional.contains("scenes"));XCTAssertTrue(AgentMutationExecutor.commands.contains(descriptor.name))
        let schema=try AgentContract.inputSchema(descriptor.name)
        XCTAssertEqual(schema.object?["properties"]?.object?["scenes"]?.object?["items"]?.object?["$ref"],.string("#/$defs/Scene"))
        let(db,w,_)=try fixture(),input=try Codec.data(AgentValue.object(["workspace_id":.string(w.id),"name":.string("普通剪辑"),"scenes":.array([])]))
        XCTAssertNoThrow(try AgentPreview.evaluate(command:descriptor.name,data:input,database:db,principal:"owner"))
        XCTAssertThrowsError(try AgentPreview.evaluate(command:descriptor.name,data:input,database:db,principal:"untrusted"))
    }
    func testAtomicNormalCreationReplaysOneProjectAndRejectsRequestChanges()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("normal-content-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let repo=try Repository(root:root),w=Workspace(name:"实际工作区",owner:"owner");try repo.transaction{$0.workspaces=[w]}
        let input=try Codec.data(AgentValue.object(["workspace_id":.string(w.id),"name":.string("普通剪辑")]))
        let first=try repo.performAgentMutation(command:"projects create",data:input,principal:"owner",requestID:"once")
        let repeated=try repo.performAgentMutation(command:"projects create",data:input,principal:"owner",requestID:"once")
        XCTAssertEqual(first,repeated);XCTAssertEqual(try repo.read().projects.count,1);XCTAssertTrue(try repo.read().products.isEmpty)
        let changed=try Codec.data(AgentValue.object(["workspace_id":.string(w.id),"name":.string("另一内容")]))
        XCTAssertThrowsError(try repo.performAgentMutation(command:"projects create",data:changed,principal:"owner",requestID:"once"))
    }
    func testScriptPlanningWithoutProductUsesActualInputAndNoSalesCTA()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("normal-script-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let repo=try Repository(root:root),w=Workspace(name:"教学空间",owner:"owner");try repo.transaction{$0.workspaces=[w]}
        let fields:[String:AgentValue]=["workspace_id":.string(w.id),"knowledge":.string("状态变化由输入决定。"),"demonstration":.string("执行操作后，对照前后结果。"),"hook":.string("怎样观察状态变化？")]
        let input=try Codec.data(AgentValue.object(fields))
        let output=try repo.performAgentMutation(command:"script create",data:input,principal:"owner",requestID:"normal-script")
        XCTAssertEqual(output.object?["state"],.string("needs_review"))
        let database=try repo.read(),revision=try XCTUnwrap(database.projects.first).current
        XCTAssertNil(revision.product);XCTAssertEqual(revision.purpose,.education);XCTAssertEqual(revision.cta,"")
        XCTAssertEqual(revision.scenes.map(\.body),["状态变化由输入决定。","执行操作后，对照前后结果。"])
        XCTAssertFalse(revision.scenes.contains{$0.showPrice});XCTAssertTrue(database.products.isEmpty)
        XCTAssertTrue(try Quality.inspect(revision,database:database,requireReview:false).isEmpty)
        var foreign=fields;foreign["product_id"] = .string("missing")
        XCTAssertThrowsError(try repo.performAgentMutation(command:"script create",data:Codec.data(AgentValue.object(foreign)),principal:"owner",requestID:"wrong-product"))
        var commercial=fields;commercial["purpose"] = .string(Purpose.course.rawValue);commercial["knowledge"] = .string("保证收益提升100倍")
        _=try repo.performAgentMutation(command:"script create",data:Codec.data(AgentValue.object(commercial)),principal:"owner",requestID:"commercial")
        let stored=try repo.read(),commercialRevision=try XCTUnwrap(stored.projects.last).current
        XCTAssertEqual(commercialRevision.purpose,.course)
        XCTAssertTrue(try Quality.inspect(commercialRevision,database:stored,requireReview:false).contains{$0.id.contains("claims-")})
    }
    func testScopedReadIncludesOnlyReferencedContentSourcesAndNoOtherCustomer()throws {
        var(db,w,p)=try fixture();let a=Asset(workspaceID:w.id,name:"引用.txt",hash:String(repeating:"a",count:64),ext:"txt",bytes:10,mediaType:"text")
        let other=Asset(workspaceID:w.id,name:"其他客户.txt",hash:String(repeating:"b",count:64),ext:"txt",bytes:10,mediaType:"text")
        var revision=p.current;revision.scenes[0].narrativeSources=[NarrativeSource(assetID:a.id,excerpt:"实际原句",confirmed:true)];revision.contentContext?.assetIDs=[a.id,other.id];revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[a,other],evidence:[])
        db.assets=[a,other];db.projects[0].revisions=[revision]
        let read=try WorkspaceAccessRules.readModel(projectID:p.id,revisionID:revision.id,access:WorkspaceAccessContext(workspaceID:w.id,principal:"owner"),in:db)
        XCTAssertEqual(read.assets.map(\.id),[a.id]);XCTAssertEqual(read.revision.contentContext?.assetIDs,[a.id]);XCTAssertNil(read.revision.product)
        var tampered=revision;tampered.dependencies?.contentContextID="foreign"
        XCTAssertTrue(DependencyRules.diff(revision:tampered,assets:[a,other],evidence:[]).contains{$0.reason == .permission})
    }
}

final class ProductFactsTests:XCTestCase {
    private func fixture()throws->(Database,Workspace,Product,Project) {
        let workspace=Workspace(name:"事实更新规则空间",owner:"owner")
        let product=Product(workspaceID:workspace.id,sku:"source-course",name:"规则用已有资料",checkout:"https://example.org/course",audience:"学习者",task:"核对标价",outcome:"记录原始来源",prerequisite:"无",scope:"公开资料",prices:[Price(money:Money(99),from:.distantPast,source:"规则用价格来源",verified:true)])
        var scene=Scene(title:"核对原页面",body:"原资料标价99元",durationFrames:60)
        scene.showPrice=true;scene.captions=[Caption(text:"原资料标价99元",startFrame:0,endFrame:60,confirmed:true)]
        var revision=Revision(product:product,purpose:.education,aspect:.landscape,scenes:[scene],cta:"查看原页面",change:"规则用已核版本")
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:[],evidence:[])
        revision.review.text=true;revision.review.rights=true;revision.review.fullPreview=true;revision.review.sound=true;revision.review.captions=true;revision.review.digest=try revision.contentDigest()
        let project=Project(workspaceID:workspace.id,name:"已有事实工程",revision:revision)
        let publication=Publication(workspaceID:workspace.id,projectID:project.id,revisionID:revision.id,platform:"规则用导出包",accountReference:"",aiLabel:false,commercialLabel:false,rightsChecked:false,ctaPermitted:false,channelAuthorized:false,trackingCode:"",title:"旧版本材料",description:"仅为规则夹具，不代表真实远端发布")
        var database=Database();database.workspaces=[workspace];database.products=[product];database.projects=[project];database.publications=[publication]
        return(database,workspace,product,project)
    }

    func testUnchangedSaveDoesNotRevokeReviewOrAppendRevision()throws {
        var(database,workspace,product,_)=try fixture()
        let before=try Codec.data(database),digest=try Codec.digest(product)
        try database.saveProductFacts(product,workspaceID:workspace.id)
        XCTAssertEqual(try Codec.data(database),before)
        try database.saveProductFacts(product,workspaceID:workspace.id,previousDigest:digest)
        XCTAssertEqual(try Codec.data(database),before)
    }

    func testTagsOnlySavePersistsTagsWithoutInvalidatingContentOrDelivery()throws {
        var(database,workspace,product,_)=try fixture()
        let projects=try Codec.data(database.projects),publications=try Codec.data(database.publications),digest=try Codec.digest(product)
        product.tags=["待整理","作者标签"]
        try database.saveProductFacts(product,workspaceID:workspace.id,previousDigest:digest)
        XCTAssertEqual(database.products[0].tags,product.tags)
        XCTAssertEqual(try Codec.data(database.projects),projects)
        XCTAssertEqual(try Codec.data(database.publications),publications)
        XCTAssertTrue(database.projects[0].current.review.complete)
    }

    func testPriceChangeInvalidatesOnlyBoundWorkspaceProjectsAndOldDelivery()throws {
        var(database,workspace,product,project)=try fixture()
        let otherWorkspace=Workspace(name:"另一工作区",owner:"other")
        let ordinary=Project(workspaceID:workspace.id,name:"普通素材工程",revision:try Planner.create(workspaceID:workspace.id,name:"普通素材工程"))
        var otherProduct=product;otherProduct.id=Codec.id();otherProduct.workspaceID=otherWorkspace.id
        let unrelated=Project(workspaceID:otherWorkspace.id,name:"另一资料工程",revision:Revision(product:otherProduct,purpose:.education,aspect:.landscape,scenes:[Scene(title:"其它",body:"其它资料")],cta:""))
        let unrelatedPublication=Publication(workspaceID:otherWorkspace.id,projectID:unrelated.id,revisionID:unrelated.current.id,platform:"规则用导出包",accountReference:"",aiLabel:false,commercialLabel:false,rightsChecked:false,ctaPermitted:false,channelAuthorized:false,trackingCode:"",title:"另一旧版",description:"")
        database.workspaces.append(otherWorkspace);database.products.append(otherProduct);database.projects += [ordinary,unrelated];database.publications.append(unrelatedPublication)
        let originalRevision=try Codec.data(project.current),ordinaryBytes=try Codec.data(ordinary),unrelatedBytes=try Codec.data(unrelated),unrelatedDelivery=try Codec.data(unrelatedPublication)
        product.prices[0].money=Money(200);product.prices[0].verified=false
        try database.saveProductFacts(product,workspaceID:workspace.id,previousDigest:Codec.digest(database.products[0]))
        let updated=database.projects[0]
        XCTAssertEqual(updated.revisions.count,2);XCTAssertEqual(updated.current.parentID,project.current.id)
        XCTAssertEqual(updated.current.number,project.current.number+1)
        XCTAssertEqual(updated.current.product,product);XCTAssertFalse(updated.current.review.complete)
        XCTAssertFalse(updated.current.review.text);XCTAssertFalse(updated.current.review.captions)
        XCTAssertFalse(updated.current.scenes[0].captions[0].confirmed)
        XCTAssertEqual(try Codec.data(updated.revisions[0]),originalRevision)
        XCTAssertTrue(database.publications[0].stale)
        XCTAssertEqual(database.publications[0].revisionID,project.current.id)
        XCTAssertEqual(try Codec.data(database.projects[1]),ordinaryBytes)
        XCTAssertEqual(try Codec.data(database.projects[2]),unrelatedBytes)
        XCTAssertEqual(try Codec.data(database.publications[1]),unrelatedDelivery)
        let once=try Codec.data(database)
        try database.saveProductFacts(product,workspaceID:workspace.id)
        XCTAssertEqual(try Codec.data(database),once)
    }

    func testSourceAndAudienceChangesAlsoInvalidatePreviouslyConfirmedFacts()throws {
        let(base,workspace,product,_)=try fixture()
        var changed=product;changed.audience="另一实际受众";changed.checkout="https://example.org/new-source"
        var database=base
        try database.saveProductFacts(changed,workspaceID:workspace.id)
        XCTAssertEqual(database.projects[0].current.product?.audience,changed.audience)
        XCTAssertEqual(database.projects[0].current.product?.checkout,changed.checkout)
        XCTAssertFalse(database.projects[0].current.review.complete)
        XCTAssertTrue(database.publications[0].stale)
    }

    func testEditorDigestDetectsChangedRemovedOrUnexpectedExistingRecord()throws {
        let(base,workspace,product,_)=try fixture(),digest=try Codec.digest(product)
        var changed=product;changed.prices[0].money=Money(200)
        var database=base
        try database.saveProductFacts(changed,workspaceID:workspace.id)
        let changedBytes=try Codec.data(database)
        XCTAssertThrowsError(try database.saveProductFacts(product,workspaceID:workspace.id,previousDigest:digest))
        XCTAssertEqual(try Codec.data(database),changedBytes)
        XCTAssertThrowsError(try database.saveProductFacts(changed,workspaceID:workspace.id,previousDigest:nil))
        XCTAssertEqual(try Codec.data(database),changedBytes)
        database.products=[];let removed=try Codec.data(database)
        XCTAssertThrowsError(try database.saveProductFacts(product,workspaceID:workspace.id,previousDigest:digest))
        XCTAssertEqual(try Codec.data(database),removed)
        try database.saveProductFacts(product,workspaceID:workspace.id,previousDigest:nil)
        XCTAssertEqual(database.products,[product])
    }

    func testWorkspaceAndForeignIdentityChecksDoNotMutateAnyRecord()throws {
        var(database,workspace,product,_)=try fixture()
        let other=Workspace(name:"另一个真实空间",owner:"other");database.workspaces.append(other)
        let before=try Codec.data(database)
        XCTAssertThrowsError(try database.saveProductFacts(product,workspaceID:other.id))
        XCTAssertEqual(try Codec.data(database),before)
        product.workspaceID=other.id
        XCTAssertThrowsError(try database.saveProductFacts(product,workspaceID:other.id))
        XCTAssertEqual(try Codec.data(database),before)
        product.id=Codec.id();product.workspaceID="missing-workspace"
        XCTAssertThrowsError(try database.saveProductFacts(product,workspaceID:product.workspaceID))
        XCTAssertEqual(try Codec.data(database),before)
        XCTAssertEqual(database.products[0].workspaceID,workspace.id)
    }

    func testDuplicateSKUAndInvalidMappedSourcesFailBeforeMutation()throws {
        var(database,workspace,product,_)=try fixture()
        let before=try Codec.data(database)
        var duplicate=product;duplicate.id=Codec.id()
        XCTAssertThrowsError(try database.saveProductFacts(duplicate,workspaceID:workspace.id))
        XCTAssertEqual(try Codec.data(database),before)
        product.courseMappings=[CourseMapping(title:"缺失素材",knowledge:"核对",audience:"学习者",task:"记录",outcome:"核对记录",prerequisite:"无",assetID:"missing",rangeKind:.whole)]
        XCTAssertThrowsError(try database.saveProductFacts(product,workspaceID:workspace.id))
        XCTAssertEqual(try Codec.data(database),before)
    }

    func testNormalAgentImportUsesSharedInvalidationWithReplayAndOwnerAuthorization()throws {
        let(base,workspace,product,_)=try fixture()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("fact-save-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let repository=try Repository(root:root);try repository.transaction{$0=base}
        var changed=product;changed.prices[0].money=Money(200);changed.prices[0].verified=false
        let value=try Codec.decoder().decode(AgentValue.self,from:Codec.data(changed))
        let data=try Codec.data(AgentValue.object(["workspace_id":.string(workspace.id),"product":value]))
        let before=try Codec.data(repository.read())
        XCTAssertThrowsError(try repository.performAgentMutation(command:"products import",data:data,principal:"other",requestID:"denied"))
        XCTAssertEqual(try Codec.data(repository.read()),before)
        let first=try repository.performAgentMutation(command:"products import",data:data,principal:"owner",requestID:"fact-once")
        let saved=try repository.read()
        XCTAssertEqual(saved.projects[0].revisions.count,2);XCTAssertTrue(saved.publications[0].stale)
        XCTAssertFalse(saved.projects[0].current.review.complete)
        let savedBytes=try Codec.data(saved)
        XCTAssertEqual(try repository.performAgentMutation(command:"products import",data:data,principal:"owner",requestID:"fact-once"),first)
        var replay=try repository.read()
        XCTAssertEqual(replay.generation,saved.generation+1)
        replay.generation=saved.generation
        XCTAssertEqual(try Codec.data(replay),savedBytes)
    }
}
