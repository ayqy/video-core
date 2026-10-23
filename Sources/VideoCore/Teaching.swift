import Foundation

/// A topic for teaching content. Optional existing product facts are sources, never an admission ticket.
public struct TeachingTopic: Codable, Identifiable, Sendable {
    public var id = Codec.id()
    public var workspaceID: String
    public var name: String
    public var audience: String
    public var task: String
    public var knowledge: String
    public var hook: String
    public var outcome: String
    public var prerequisite: String
    public var proof: String
    public var boundary: String
    public var cta: String
    public var feedbackSummary: String
    public var evidenceIDs: [String]
    public var mappingIDs: [String]
    public var productID: String?
    public var tags: [String] = []
    public init(workspaceID: String, name: String, audience: String, task: String, knowledge: String, hook: String, outcome: String, prerequisite: String, proof: String, boundary: String, cta: String = "", feedbackSummary: String = "", evidenceIDs: [String] = [], mappingIDs: [String] = [], productID: String? = nil) {
        self.workspaceID=workspaceID; self.name=name; self.audience=audience; self.task=task; self.knowledge=knowledge; self.hook=hook; self.outcome=outcome; self.prerequisite=prerequisite; self.proof=proof; self.boundary=boundary; self.cta=cta; self.feedbackSummary=feedbackSummary; self.evidenceIDs=evidenceIDs; self.mappingIDs=mappingIDs; self.productID=productID
    }
    public func validate() throws {
        let required=[workspaceID,name,audience,task,knowledge,hook,outcome,prerequisite,proof,boundary]
        guard required.allSatisfy({ !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.count<=6000 }),
              Set(evidenceIDs).count==evidenceIDs.count, Set(mappingIDs).count==mappingIDs.count else {
            throw VideoError.invalid("选题须明确受众、任务、完整知识、小成果、前置条件、真实演示与边界；证据和映射不能重复")
        }
        let urls=cta.components(separatedBy:.whitespacesAndNewlines).filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
        guard urls.count<=1, !cta.contains("；"), !cta.contains(";"), !cta.contains("\n") else { throw VideoError.invalid("可选CTA最多一个动作及一个链接；普通教学可以留空") }
    }
}

/// A configurable, workspace-owned factual checklist, with no brand deal or financial object.
public struct WorkspaceVerticalChecklist: Codable, Identifiable, Sendable {
    public var id = Codec.id()
    public var workspaceID: String
    public var template: VerticalChecklistTemplate
    public var checked: [String: Bool]
    public var evidence: [String: [String]]
    public init(workspaceID: String, template: VerticalChecklistTemplate, checked: [String:Bool] = [:], evidence: [String:[String]] = [:]) {
        self.workspaceID=workspaceID; self.template=template; self.checked=checked; self.evidence=evidence
    }
    public func reviewIssues(evidence records:[Evidence],commercial:Bool,now:Date=Date()) -> [String] {
        var result:[String]=[]
        do { try template.validate() } catch { return ["垂类清单结构无效"] }
        for item in template.requirements {
            if checked[item.id] != true { result.append("尚未人工核验："+item.label) }
            if item.evidenceRequired {
                let selected=evidence[item.id] ?? []
                if selected.isEmpty || !selected.allSatisfy({ id in records.contains { record in
                    record.id==id && record.workspaceID==workspaceID && record.usable(commercial:commercial,now:now) &&
                    (item.maximumAgeDays == nil || record.checkedAt.addingTimeInterval(Double(item.maximumAgeDays!)*86400)>now)
                } }) { result.append("缺少当前适用证据："+item.label) }
            }
        }
        return result
    }
}

public struct TeachingInput: Codable, Sendable {
    public var topic: TeachingTopic
    public var contentContext: ContentContext
    public var grammar: NarrativeGrammar
    public var sources: [NarrativeSource]
    public var purpose: Purpose
    public var aspect: Aspect
    public var steps: [String] = []
    public var startingPoint = ""
    public var result = ""
    public var analogy = ""
    public var counterargument = ""
    public var response = ""
    public var humour = ""
    public var comparedSubject = ""
    public var comparisonBasis = ""
    public var costItems: [NarrativeCostItem] = []
    public var simulation: Simulation?
    public var knowledgeStoryboard: KnowledgeStoryboardPlan?
    public var cartoonStoryboard: CartoonTeachingPlan?
    public init(topic:TeachingTopic,contentContext:ContentContext,grammar:NarrativeGrammar,sources:[NarrativeSource],purpose:Purpose = .education,aspect:Aspect) {
        self.topic=topic; self.contentContext=contentContext; self.grammar=grammar; self.sources=sources; self.purpose=purpose; self.aspect=aspect
    }
}

public struct TeachingDocument: Codable, Identifiable, Sendable {
    public var id = Codec.id()
    public var workspaceID: String
    public var input: TeachingInput
    public var revision: Revision
    public var beats: [NarrativeBeat]
    public var template: NarrativeTemplate
    public var style: StyleKit
    public var series: SeriesProfile?
    public var vertical: WorkspaceVerticalChecklist?
    public var projectID: String?
    public var rewrites: [ScriptRewrite] = []
    public var confirmedDigest: String?
    public var confirmedBy: String?
    public var confirmedAt: Date?
    public var confirmed: Bool { confirmedDigest != nil && confirmedDigest == (try? revision.contentDigest()) }

    public mutating func confirm(reviewer:String,assets:[Asset],evidence:[Evidence],currentProduct:Product?=nil,now:Date=Date()) throws {
        guard !reviewer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw VideoError.invalid("请填写实际审核者") }
        let issues=TeachingPlanner.confirmationIssues(document:self,assets:assets,evidence:evidence,currentProduct:currentProduct,now:now)
        guard issues.isEmpty else { throw VideoError.review(issues.joined(separator:"；")) }
        confirmedDigest=try revision.contentDigest(); confirmedBy=reviewer; confirmedAt=now
    }
    public mutating func rewrite(sceneID:String,text:String,author:String,reason:String,assets:[Asset],now:Date=Date()) throws {
        guard !author.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, !reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.count<=180,
              let index=revision.scenes.firstIndex(where:{$0.id==sceneID}), let beat=beats.firstIndex(where:{$0.sceneID==sceneID}) else {
            throw VideoError.invalid("改写须有场景、1至180字文案、真实作者和理由")
        }
        let structured=revision.scenes[index].simulationPresentation != nil || revision.scenes[index].cartoonPerformance != nil
        let old=structured ? revision.scenes[index].narration:revision.scenes[index].body
        var scene=revision.scenes[index];if !structured{scene.body=text};scene.narration=text
        let project=Project(workspaceID:workspaceID,name:input.topic.name,revision:revision)
        revision=try Editor.apply([.replaceScene(sceneID,scene)],to:project,baseRevision:revision.id,assets:assets,message:"人工改写："+reason).current
        beats[beat].text=text;rewrites.append(ScriptRewrite(sceneID:sceneID,before:old,after:text,author:author,reason:reason,at:now))
        confirmedDigest=nil;confirmedBy=nil;confirmedAt=nil
    }
}

/// Deterministic teaching composition, using only user supplied content and real selected sources.
public enum TeachingPlanner {
    private static func nonblank(_ text:String)->Bool { !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    public static func compose(input:TeachingInput,product:Product?=nil,assets:[Asset],evidence:[Evidence],template:NarrativeTemplate,style:StyleKit,series:SeriesProfile?=nil,vertical:WorkspaceVerticalChecklist?=nil,now:Date=Date()) throws -> TeachingDocument {
        try input.topic.validate();try input.contentContext.validate()
        let topic=input.topic,workspace=topic.workspaceID,t=try template.migrated()
        guard workspace==input.contentContext.workspaceID,workspace==style.workspaceID,workspace==t.workspaceID,
              t.grammars.contains(input.grammar),vertical==nil || vertical?.workspaceID==workspace else {throw VideoError.permission("选题、内容、风格、模板与垂类必须属于同一工作区")}
        if let product { try product.validate();guard product.id==topic.productID,product.workspaceID==workspace else{throw VideoError.permission("所选既有事实与选题不匹配")} }
        else {guard topic.productID==nil else{throw VideoError.notFound("选题关联的既有产品事实已缺失")}}
        guard !input.sources.isEmpty else{throw VideoError.review("请明确选择真实来源，不会生成无依据的空课")}
        for source in input.sources{try source.validate(workspaceID:workspace,assets:assets)}
        for mapping in input.contentContext.courseMappings ?? [] { try mapping.validate(workspaceID:workspace,assets:assets,evidence:evidence) }
        guard Set(topic.mappingIDs).isSubset(of:Set((input.contentContext.courseMappings ?? []).map(\.id))) else {throw VideoError.notFound("选题课程片段映射缺失")}
        try style.validate(assets:assets,evidence:evidence,commercial:input.purpose != .education,now:now)
        if let s=series {guard s.workspaceID==workspace,s.styleID==style.id,s.styleVersion==style.version,s.templateID==t.id,s.templateVersion==t.version,s.episodeNumber>0,nonblank(s.name),nonblank(s.recurringQuestion) else{throw VideoError.conflict("栏目绑定的模板或风格版本已变，请明确迁移后重用")}}
        if let plan=input.knowledgeStoryboard {
            guard input.grammar == .simulation,input.simulation==nil,input.cartoonStoryboard==nil else { throw VideoError.invalid("知识分镜须明确选择规则模拟，不能同时提交旧数值规则或角色争论") }
            return try composeKnowledge(input:input,plan:plan,product:product,assets:assets,evidence:evidence,template:t,style:style,series:series,vertical:vertical,now:now)
        }
        guard input.cartoonStoryboard==nil || input.grammar == .debate else { throw VideoError.invalid("角色表演计划只可用于明确的角色争论语法") }
        var content:[(NarrativeBeatRole,String,String)]=[(.hook,"本次要解决的问题",topic.hook),(.knowledge,"完整知识点",topic.knowledge)]
        func require(_ texts:String...)throws{guard texts.allSatisfy(nonblank) else{throw VideoError.invalid("请补齐"+input.grammar.rawValue+"所需真实输入")}}
        switch input.grammar{
        case .misconception:try require(input.startingPoint,input.response);content += [(.example,"常见误解（待纠正）",input.startingPoint),(.claim,"依据材料纠正",input.response)]
        case .analogy:try require(input.analogy);content.append((.example,"帮助理解的类比（非现实定律）",input.analogy))
        case .practice:guard !input.steps.isEmpty,input.steps.count<=12,input.steps.allSatisfy(nonblank) else{throw VideoError.invalid("请填写1至12条真实可复现步骤")};for (n,step) in input.steps.enumerated(){content.append((.demonstration,"操作 "+String(n+1),step))}
        case .simulation:guard let simulation=input.simulation else{throw VideoError.invalid("规则模拟须有实际参数")};_ = try SimulationReplay.record(simulation:simulation,throughTick:0);content.append((.example,"规则假设，不代表现实定律","单位："+simulation.unit+"；初值："+String(simulation.initial)+"；容量："+String(simulation.capacity)))
        case .debate:try require(input.counterargument,input.response);content += [(.example,"观点一提出的问题",input.counterargument),(.claim,"观点二依据材料回应",input.response)]
        case .beforeAfter:try require(input.startingPoint,input.result);content += [(.example,"同条件起点",input.startingPoint),(.claim,"真实观察结果",input.result)]
        case .productComparison:try require(input.comparedSubject,input.comparisonBasis,input.startingPoint,input.result);content += [(.example,"同条件比较："+input.comparisonBasis,input.startingPoint),(.claim,input.comparedSubject,input.result)]
        case .costs:
            guard let first=input.costItems.first,input.costItems.count<=20 else{throw VideoError.invalid("成本拆解须填写1至20条已核实的同币种费用，不生成利润估计")}
            var total=Money(0,first.money.currency)
            for item in input.costItems{
                try require(item.label,item.evidenceID)
                guard topic.evidenceIDs.contains(item.evidenceID),item.money.amount>=0 else{throw VideoError.review("每项费用必须有已选事实证据")}
                total=try total.adding(item.money);content.append((.claim,item.label,item.money.display))
            }
            content.append((.example,"同币种明细合计",total.display))
        case .series:guard let series else{throw VideoError.invalid("请先保存栏目、固定问题及模板风格版本")};content[0]=(.hook,series.episodePrefix+" "+String(series.episodeNumber),topic.hook)
        }
        if nonblank(input.humour){content.append((.entertainment,"娱乐桥段，不作为事实证明",input.humour))}
        content += [(.demonstration,"真实演示与观察",topic.proof),(.boundary,"适用范围与前置条件",topic.prerequisite+"\n"+topic.boundary)]
        if nonblank(topic.cta){content.append((.action,"可选的下一步",topic.cta))}
        var scenes:[Scene]=[],beats:[NarrativeBeat]=[]
        let selectedEvidence=Set(topic.evidenceIDs+(vertical?.evidence.values.flatMap{$0} ?? []))
        // Split long inputs at Unicode character boundaries; do not drop source text or silently truncate it.
        for (role,title,text) in content{
            let chunks=stride(from:0,to:text.count,by:160).map{start->String in
                let a=text.index(text.startIndex,offsetBy:start),b=text.index(a,offsetBy:min(160,text.count-start));return String(text[a..<b])
            }
            for (chunkIndex,chunk) in chunks.enumerated(){
                let parameter=t.beats.first{$0.role==role}
                let isDialogue=input.grammar == .debate && input.cartoonStoryboard != nil && (role == .example || role == .claim)
                let kind:SceneKind=isDialogue ? .cartoon:(input.grammar == .simulation && role == .example) ? .simulation:(parameter?.kind ?? .explanation)
                guard kind != .cartoon || isDialogue || !style.characters.isEmpty else{throw VideoError.review("卡通模板必须选择明确角色及来源；普通教学使用讲解镜头")}
                var scene=Scene(kind:kind,title:String((chunks.count>1 ? title+"（"+String(chunkIndex+1)+"）":title).prefix(80)),body:chunk,narration:chunk,durationFrames:parameter?.frames ?? (role == .hook ? 120:240))
                scene.color=style.palette[scenes.count % style.palette.count];scene.fontName=style.fontName
                scene.evidenceIDs=Array(selectedEvidence.union(style.evidenceIDs)).sorted();scene.narrativeSources=input.sources;scene.courseMappingIDs=topic.mappingIDs
                if isDialogue,let plan=input.cartoonStoryboard {
                    let speaker=role == .example ? 0:1
                    scene.classicArtwork=plan.artwork
                    scene.cartoonPerformance=try plan.performance(speakerIndex:speaker,durationFrames:scene.durationFrames)
                    scene.character=plan.actors[speaker].name
                    scene.body=scene.character+"："+(role == .example ? "提出问题":"依据材料回应")
                    scene.evidenceIDs=Array(Set(scene.evidenceIDs).union(plan.artwork.evidenceIDs)).sorted()
                } else if kind == .cartoon,let character=style.characters.first{guard !character.original else{throw VideoError.review("经典卡通制作须使用下载并Q版化的熟悉角色，不以陌生原创几何角色代替")};scene.character=character.name;scene.characterProfile=character}
                if let simulation=input.simulation,kind == .simulation{scene.simulation=simulation}
                if parameter?.motion==true{scene.keyframes=[Keyframe(frame:0,x:0.46,y:0.5,scale:0.95),Keyframe(frame:scene.durationFrames-1,x:0.54,y:0.5,scale:1.05)]}
                // A real demonstration uses the explicitly selected recording, with exact source range.
                if role == .demonstration,let source=input.sources.first(where:{$0.startFrame != nil}),
                   let asset=assets.first(where:{$0.id==source.assetID && $0.workspaceID==workspace && $0.mediaType=="video"}),let start=source.startFrame,let end=source.endFrame{
                    scene.kind = .video;scene.assetID=asset.id;scene.sourceStartFrame=start;scene.sourceEndFrame=end;scene.durationFrames=min(scene.durationFrames,end-start)
                }
                try scene.validate(assets:assets.filter{$0.workspaceID==workspace})
                scenes.append(scene);beats.append(NarrativeBeat(role:role,sceneID:scene.id,text:chunk,sourceIDs:input.sources.map(\.id),evidenceIDs:scene.evidenceIDs,characterID:scene.characterProfile?.id))
            }
        }
        var context=input.contentContext;context.assetIDs=Array(Set(context.assetIDs+input.sources.map(\.assetID))).sorted()
        var revision:Revision
        if let product{revision=Revision(product:product,purpose:input.purpose,aspect:input.aspect,scenes:scenes,cta:topic.cta,change:"教学叙事："+input.grammar.rawValue+"（待人工核验）")}
        else{revision=Revision(contentContext:context,purpose:input.purpose,aspect:input.aspect,scenes:scenes,cta:topic.cta,change:"教学叙事："+input.grammar.rawValue+"（待人工核验）")}
        revision.musicAssetID=style.musicAssetID
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:assets,evidence:evidence,now:now)
        return TeachingDocument(workspaceID:workspace,input:input,revision:revision,beats:beats,template:t,style:style,series:series,vertical:vertical)
    }
    private static func composeKnowledge(input:TeachingInput,plan:KnowledgeStoryboardPlan,product:Product?,assets:[Asset],evidence:[Evidence],template:NarrativeTemplate,style:StyleKit,series:SeriesProfile?,vertical:WorkspaceVerticalChecklist?,now:Date)throws->TeachingDocument {
        try plan.validate()
        let topic=input.topic,workspace=topic.workspaceID
        let selected=Set(topic.evidenceIDs+style.evidenceIDs+(vertical?.evidence.values.flatMap{$0} ?? []))
        var scenes:[Scene]=[],beats:[NarrativeBeat]=[]
        func append(_ sceneValue:Scene,role:NarrativeBeatRole)throws {
            var scene=sceneValue
            scene.fontName=style.fontName;scene.color=style.palette[scenes.count % style.palette.count]
            scene.evidenceIDs=Array(Set(scene.evidenceIDs).union(selected)).sorted()
            scene.narrativeSources=input.sources;scene.courseMappingIDs=topic.mappingIDs
            try scene.validate(assets:assets.filter{$0.workspaceID==workspace})
            scenes.append(scene);beats.append(NarrativeBeat(role:role,sceneID:scene.id,text:scene.narration,sourceIDs:input.sources.map(\.id),evidenceIDs:scene.evidenceIDs,characterID:nil))
        }
        func explain(_ title:String,_ text:String,role:NarrativeBeatRole)throws {
            for start in stride(from:0,to:text.count,by:160) {
                let a=text.index(text.startIndex,offsetBy:start),b=text.index(a,offsetBy:min(160,text.count-start)),chunk=String(text[a..<b])
                try append(Scene(title:title,body:chunk,narration:chunk,durationFrames:template.beats.first{$0.role==role}?.frames ?? 240),role:role)
            }
        }
        func demonstrate(_ model:KnowledgeSimulation,_ shots:[KnowledgeStoryboardShot])throws {
            for shot in shots {
                var scene=Scene(kind:.simulation,title:shot.title,body:shot.visualSummary ?? shot.title,narration:shot.narration,durationFrames:shot.durationFrames)
                scene.simulation.knowledge=model;scene.simulation.seed=plan.seed;scene.simulation.unit=model.resourceLabel
                scene.classicArtwork=plan.artwork;scene.evidenceIDs=Array(plan.artwork.evidenceIDs).sorted()
                scene.simulationPresentation=SimulationPresentation(sourceStartFrame:shot.startTick*30,sourceEndFrame:shot.endTickExclusive*30,presentationFrames:shot.durationFrames)
                try append(scene,role:.demonstration)
            }
        }
        try explain("本次要解决的问题",topic.hook,role:.hook)
        try explain("知识与前置条件",topic.knowledge,role:.knowledge)
        try explain("模型规则与适用假设",plan.ruleExplanation,role:.example)
        try explain("观察什么、怎样核对",topic.proof,role:.demonstration)
        try demonstrate(plan.baseline,plan.baselineShots)
        try explain("同种子反事实：改变什么",plan.alternativeExplanation,role:.example)
        try demonstrate(plan.alternative,plan.alternativeShots)
        if nonblank(input.humour){try explain("娱乐桥段，不作为事实证明",input.humour,role:.entertainment)}
        try explain("根据这两次实际演示得出的结论",plan.conclusion,role:.claim)
        try explain("适用范围与前置条件",topic.prerequisite+"\n"+topic.boundary,role:.boundary)
        if nonblank(topic.cta){try explain("可选的下一步",topic.cta,role:.action)}
        var context=input.contentContext;context.assetIDs=Array(Set(context.assetIDs+input.sources.map(\.assetID))).sorted()
        var revision:Revision
        if let product {revision=Revision(product:product,purpose:input.purpose,aspect:input.aspect,scenes:scenes,cta:topic.cta,change:"知识因果分镜与同种子反事实（待录制、配音及核验）")}
        else {revision=Revision(contentContext:context,purpose:input.purpose,aspect:input.aspect,scenes:scenes,cta:topic.cta,change:"知识因果分镜与同种子反事实（待录制、配音及核验）")}
        revision.musicAssetID=style.musicAssetID
        revision.dependencies=try DependencyRules.freeze(revision:revision,assets:assets,evidence:evidence,now:now)
        return TeachingDocument(workspaceID:workspace,input:input,revision:revision,beats:beats,template:template,style:style,series:series,vertical:vertical)
    }
    public static func confirmationIssues(document:TeachingDocument,assets:[Asset],evidence:[Evidence],currentProduct:Product?=nil,now:Date=Date())->[String]{
        var issues=DependencyRules.reviewIssues(revision:document.revision,assets:assets,evidence:evidence,currentProduct:currentProduct,now:now)
        if let frozen=document.revision.product{
            guard let currentProduct,currentProduct.id==frozen.id,currentProduct.hasSameFacts(as:frozen) else{return issues+["既有课程或价格事实已变化，须按最新事实重新生成并核对"]}
            do{let price=try currentProduct.price(at:now);if !price.verified{issues.append("当前价格未核实")}}catch{issues.append("当前价格缺失、过期或重叠")}
        }
        if let vertical=document.vertical{issues += vertical.reviewIssues(evidence:evidence,commercial:document.revision.purpose != .education,now:now)}
        let words=document.revision.scenes.filter{!$0.body.isEmpty}.map(\.body).joined(separator:"\n")
        let guarantees=["保证收益","稳赚","保过","百分百有效","100%有效","无风险收益","包治","保证治愈"]
        if guarantees.contains(where:words.contains){issues.append("文案含无法确认的绝对效果或收益保证，请改写为有边界的事实")}
        let proofRoles:Set<NarrativeBeatRole>=[.claim,.knowledge,.demonstration]
        if document.beats.contains(where:{proofRoles.contains($0.role)}) && document.input.sources.isEmpty{issues.append("完整知识与真实演示必须有明确材料来源")}
        let quantitative=words.range(of:"[0-9０-９]+([.%％万千元]|倍|人购买|人成交|人提升)",options:.regularExpression) != nil
        let factualClaims=document.beats.contains{$0.role == .claim}
        if quantitative || factualClaims{
            let selected=Set(document.input.topic.evidenceIDs)
            if selected.isEmpty || !selected.allSatisfy({id in evidence.contains{$0.id==id && $0.workspaceID==document.workspaceID && $0.usable(commercial:document.revision.purpose != .education,now:now)}}){
                issues.append("效果、数值或对比主张须关联当前有效事实证据；材料摘录不自动证明营销结果")
            }
        }
        return Array(Set(issues)).sorted()
    }
}

public enum TeachingStoreRules {
    public static func validate(database:Database)throws{
        let workspaces=Set(database.workspaces.map(\.id))
        let topics=database.teachingTopics ?? [],documents=database.teachingDocuments ?? [],checklists=database.verticalChecklists ?? []
        guard Set(topics.map(\.id)).count==topics.count,Set(documents.map(\.id)).count==documents.count,Set(checklists.map(\.id)).count==checklists.count else{throw VideoError.invalid("教学选题、叙事或清单ID重复")}
        for topic in topics{guard workspaces.contains(topic.workspaceID) else{throw VideoError.permission("选题工作区缺失")};try topic.validate()}
        for document in documents{guard workspaces.contains(document.workspaceID),document.input.topic.workspaceID==document.workspaceID,document.revision.workspaceID==document.workspaceID else{throw VideoError.permission("教学叙事越过工作区边界")};try document.revision.validateContext()}
        for item in checklists{guard workspaces.contains(item.workspaceID) else{throw VideoError.permission("垂类清单工作区缺失")};try item.template.validate()}
    }
}
