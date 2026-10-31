import Foundation

/// Discovery describes the actual Codable wire names, including synthesized enum
/// payloads and stored defaults (which JSONDecoder still requires). Domain rules
/// and current permissions are evaluated separately; a schema never grants access.
public enum AgentSchemas {
    public static let fieldTypes:[String:String] = ["speech_plan":"SpeechPlan","dictionary":"[SpeechTerm]","baidu_input":"BaiduVideoInput","product":"Product","evidence":"Evidence","review":"Review","quote":"Quote","budget":"BudgetPolicy","publication":"Publication","sale":"ToolSale","deal":"BrandDeal","expense":"Expense","cash":"CashEntry","baseline":"Baseline","estimate":"EstimateBreakdown","billing_record":"BillingRecord","orders":"[Order]","metrics":"[Metric]","edits":"[Edit]","scenes":"[Scene]","evidence_ids":"[s]","job_ids":"[s]"]
    public static func shape(_ type:String)->AgentValue {
        if type.hasPrefix("["),type.hasSuffix("]") {return .object(["type":.string("array"),"items":shape(String(type.dropFirst().dropLast()))])}
        if type.hasPrefix("{"),type.hasSuffix("}") {return .object(["type":.string("object"),"additionalProperties":shape(String(type.dropFirst().dropLast()))])}
        switch type {
        case "s":return .object(["type":.string("string")])
        case "d":return .object(["type":.string("string"),"format":.string("date-time"),"description":.string("ISO8601 UTC/offset datetime")])
        case "b":return .object(["type":.string("boolean")])
        case "i":return .object(["type":.string("integer")])
        case "n":return .object(["type":.string("number"),"description":.string("JSON decimal, never a formatted currency string")])
        default:return .object(["$ref":.string("#/$defs/"+type)])
        }
    }
    private static func entity(_ declaration:String)->AgentValue {
        var properties:[String:AgentValue]=[:],required:[AgentValue]=[]
        for entry in declaration.split(separator:" ") {let parts=entry.split(separator:":",maxSplits:1);guard parts.count==2 else{continue};let optional=parts[0].hasSuffix("?"),key=String(optional ? parts[0].dropLast():parts[0]);let value=shape(String(parts[1]));properties[key]=optional ? .object(["anyOf":.array([value,.object(["type":.string("null")])])]):value;if !optional{required.append(.string(key))}}
        return .object(["type":.string("object"),"properties":.object(properties),"required":.array(required),"additionalProperties":.boolean(true)])
    }
    public static func definitions()->[String:AgentValue] {
        let records:[String:String]=[
            "Money":"amount:n currency:s",
            "ProductionBrief":"objective:s intendedUse:s modifications:s aiDisclosure:s commercialDisclosure:s restrictions:s evidenceIDs:[s] permittedUntil?:d approvalRequired:b",
            "AudioQualityPolicy":"targetLUFS?:n toleranceLU:n maximumTruePeakDBTP?:n silenceThresholdDBFS:n longSilenceSeconds:n rejectLongSilence:b",
            "BaiduVideoInput":"source:BaiduSource config:BaiduConfig",
            "BaiduSource":"structs:[BaiduSegment]",
            "BaiduSegment":"type:BaiduSegmentKind text?:s mediaSource?:BaiduMedia",
            "BaiduMedia":"type:i url:s",
            "BaiduMediaSetting":"mediaSource:BaiduMedia",
            "BaiduCaption":"marginBottom?:i fontColor?:s fontAlpha?:i bgColor?:s bgAlpha?:i",
            "BaiduLogo":"mediaSource:BaiduMedia location?:s margin?:i",
            "BaiduConfig":"productType:s resolution:[i] ttsPer?:i templateId?:s bgMusic?:BaiduMediaSetting videoBegin?:BaiduMediaSetting videoEnd?:BaiduMediaSetting caption?:BaiduCaption videoLogo?:BaiduLogo withVoiceBroadcast?:b withCaptions?:b",
            "Price":"id:s money:Money from:d until?:d source:s verified:b",
            "Product":"isExample?:b id:s workspaceID:s sku:s name:s checkout:s audience:s task:s outcome:s prerequisite:s scope:s prices:[Price] assetIDs:[s] tags:[s] archived:b courseMappings?:[CourseMapping]",
            "CourseMapping":"id:s title:s knowledge:s audience:s task:s outcome:s prerequisite:s assetID:s rangeKind:RangeKind start:i end:i evidenceIDs:[s] confirmed:b",
            "Evidence":"tags?:[s] id:s workspaceID:s title:s source:s claim:s owner:s commercialAllowed:b uploadConsent:b verified:b checkedAt:d expiresAt?:d assetID?:s",
            "Review":"text:b rights:b fullPreview:b sound:b captions:b digest?:s reviewer?:s at?:d",
            "Quote":"id:s projectID:s revisionID:s digest:s upper:Money unit:s provider:s expiresAt:d attempts:i confirmed:b createdAt:d breakdown?:EstimateBreakdown",
            "BudgetPolicy":"project:Money month:Money",
            "EstimateBreakdown":"version:s specification:s source:s validFrom:d expiresAt:d lines:[RateLine] excluded:[s]",
            "RateLine":"id:s label:s quantity:n quantityUnit:s price:Money per:n count:i attempts:i",
            "BillingRecord":"id:s kind:BillingKind money:Money source:s at:d",
            "Refund":"id:s amount:n at:d",
            "Order":"tags?:[s] id:s workspaceID:s platform:s buyer:s sku:s paidAt:d paid:Money fee?:n refunds:[Refund] sourceCode?:s kind:CustomerKind maturityDays:i importID:s",
            "Metric":"workspaceID:s platform:s contentID:s asOf:d window:s cumulative:b views:i arrivals?:i definition:s importID:s",
            "Baseline":"contribution:Money days:i comparable:b description:s from:d version:i",
            "Expense":"id:s workspaceID:s label:s money?:Money hours:n development:b allocation:{n} at:d",
            "CashEntry":"id:s workspaceID:s kind:RevenueKind label:s received:Money refunded:n at:d receipt:s assumption:b noncash:b",
            "Publication":"id:s workspaceID:s projectID:s revisionID:s platform:s accountReference:s remoteContentID?:s scheduledAt?:d publishedAt?:d aiLabel:b commercialLabel:b rightsChecked:b ctaPermitted:b channelAuthorized:b trackingCode:s stale:b eligibility:s title:s description:s targetDigest?:s deliveryJobID?:s preparedAt?:d checkedBy?:s validationWarnings?:[s]",
            "ToolSale":"id:s workspaceID:s buyerReference:s plan:s paid?:Money refunded:n paidAt?:d expiresAt?:d supportUntil?:d supportScope:s license:s receipt:s subscription:b cancelled:b bringOwnAccount:b orderReference?:s renewalOf?:s trialScope?:s hostedAllowance?:s thirdPartyCosts?:s autoRenew?:b cancellationReason?:s",
            "BrandDeal":"id:s workspaceID:s client:s brief:s vertical:s checklist:{b} projectID?:s approvedRevisionID?:s revisionsAllowed:i revisionsUsed:i usage:s expiresAt:d exclusivity:s settlements:[Settlement] quote:Money received?:Money receipt:s noncash:s rate:n validGMV:n actualAdSpend:n shareCap?:n settlementRecords?:[BrandSettlement] authorizations?:[CommercialAuthorization] approvals?:[BrandApproval] checklistTemplate?:VerticalChecklistTemplate checklistEvidence?:{[s]} revisionNotes?:[s] legacyCash?:CashEntry",
            "BrandSettlement":"id:s kind:Settlement received:Money refunded:n at:d receipt:s note:s",
            "CommercialAuthorization":"id:s scope:AuthorizationScope evidenceID:s usage:s from:d until:d",
            "BrandApproval":"revisionID:s digest:s reviewer:s at:d note:s termsDigest?:s revisionsUsed?:i",
            "VerticalChecklistTemplate":"id:s name:s version:i requirements:[ChecklistRequirement]",
            "ChecklistRequirement":"id:s label:s evidenceRequired:b maximumAgeDays?:i",
            "Scene":"id:s kind:SceneKind title:s body:s narration:s durationFrames:i assetID?:s evidenceIDs:[s] sourceStartFrame:i sourceEndFrame?:i speed:n preservePitch:b locked:b x:n y:n scale:n voiceGain:n sourceGain:n musicGain:n muted:b pauseFrames:i captions:[Caption] voice?:VoiceTake simulation:Simulation character:s emotion:s color:s showPrice:b keyframes:[Keyframe] courseMappingIDs?:[s] speechPlan?:SpeechPlan layers?:[SceneLayer] characterProfile?:CharacterProfile cartoonPerformance?:CartoonPerformance storyActions?:[StoryAction] storyCausality?:StoryCausality gameWorld?:GameWorld cartoonRig?:CartoonRig cartoonPresenter?:CartoonPresenter narrativeSources?:[NarrativeSource] fontName?:s classicArtwork?:ClassicArtwork classicArtworkRequired?:b simulationRecording?:RuleTrace simulationRecordingConfirmed?:b simulationPresentation?:SimulationPresentation mediaFraming?:MediaFraming paperPresentation?:PaperPresentation",
            "MediaFraming":"x:n y:n width:n height:n",
            "ClassicArtwork":"gameplay:ClassicGameplay sprites:[ClassicSprite] sources:[ClassicSource] derivation:ClassicDerivation transformation:s originalAssetIDs:[s] audioCues:[ClassicAudioCue] knowledgeParticipants?:[KnowledgeParticipantAppearance]",
            "KnowledgeParticipantAppearance":"participantID:s poseRoles:{s}",
            "ClassicSprite":"role:s assetID:s x:n y:n width:n height:n",
            "ClassicSource":"assetID:s hash:s source:s owner:s license:s evidenceID:s",
            "ClassicAudioCue":"id:s assetID:s startFrame:i durationFrames:i gain:n use:ClassicAudioUse listened:b",
            "Caption":"id:s text:s startFrame:i endFrame:i alignment:s confirmed:b",
            "VoiceTake":"assetID:s textDigest:s durationFrames:i method:s listened:b",
            "Simulation":"seed:i initial:i capacity:i unit:s events:[RuleEvent] knowledge?:KnowledgeSimulation",
            "RuleEvent":"id:s tick:i delta:i label:s",
            "RuleTrace":"ruleVersion:i inputDigest:s seed:i unit:s initial:i capacity:i throughTick:i frameStep:i transitions:[RuleTransition] finalState:i recordedFPS?:i recordedDurationFrames?:i recordedSpeed?:n recordedPauseFrames?:i recordedLastSourceFrame?:i recordedPresentation?:SimulationPresentation knowledgeTrace?:KnowledgeTrace",
            "SimulationPresentation":"version:i sourceStartFrame:i sourceEndFrame:i presentationFrames:i presentationOffsetFrames:i",
            "RuleTransition":"tick:i eventID:s label:s requestedDelta:i before:i after:i appliedDelta:i clippedDelta:i",
            "Keyframe":"id:s frame:i x:n y:n scale:n",
            "SceneLayer":"id:s kind:LayerKind text:s assetID?:s x:n y:n width:n height:n color:s opacity:n startFrame:i endFrame:i locked:b keyframes:[Keyframe] dataPresentation?:DataPresentation entrance?:LayerEntrance imageSequence?:LayerImageSequence sourceRect?:MediaFraming imageFlipHorizontal?:b texturedPath?:LayerTexturedPath",
            "LayerTexturedPath":"version:i paths:[LayerTextureStroke]",
            "LayerTextureStroke":"points:[StoryPoint] width:n",
            "SpeechPlan":"source:s normalized:s dictionary:[SpeechTerm] mappings:[SpeechMapping] voiceIdentifier?:s rate:n confirmed:b notes:[s]",
            "SpeechTerm":"term:s pronunciation:s",
            "SpeechMapping":"sourceStart:i sourceLength:i normalizedStart:i normalizedLength:i kind:s",
            "CharacterProfile":"id:s name:s silhouette:CharacterSilhouette color:s expressions:[s] actions:[s] evidenceIDs:[s] voiceAssetID?:s original:b",
            "NarrativeSource":"id:s assetID:s pages:[i] startFrame?:i endFrame?:i excerpt:s confirmed:b"
        ]
        var result=records.mapValues(entity)
        let dataRecords:[String:String] = [
            "PaperPresentation":"version:i layout:PaperLayout paperColor:s inkColor:s",
            "LayerEntrance":"version:i kind:LayerEntranceKind startFrame:i endFrame:i sourceOffsetFrames?:i",
            "LayerImageSequence":"version:i frames:[LayerImageSequenceFrame] sourceOffsetFrames?:i",
            "LayerImageSequenceFrame":"startFrame:i endFrame:i sourceRect:MediaFraming",
            "DataPresentation":"version:i sourceOffsetFrames?:i chart?:DataChart code?:CodePresentation",
            "DataChart":"title:s axisLabel:s minimum:n maximum:n series:[DataSeries]",
            "DataSeries":"id:s label:s color:s keyframes:[DataValueKeyframe]",
            "DataValueKeyframe":"frame:i value:n",
            "CodePresentation":"title:s lines:[s] highlights:[CodeHighlight]",
            "CodeHighlight":"startFrame:i endFrame:i line:i"
        ]
        for (name,declaration) in dataRecords {
            var schema=entity(declaration).object!;schema["additionalProperties"] = .boolean(false)
            result[name] = .object(schema)
        }
        var framing=result["MediaFraming"]!.object!;framing["additionalProperties"] = .boolean(false);result["MediaFraming"] = .object(framing)
        func constraint(_ name:String,_ field:String,_ values:[String:AgentValue]) {
            var record=result[name]!.object!,properties=record["properties"]!.object!
            var shape=properties[field]!.object!
            if case .array(let options)?=shape["anyOf"] {
                shape["anyOf"] = .array(options.map { option in
                    guard var value=option.object,value["type"]?.string != "null" else{return option}
                    value.merge(values,uniquingKeysWith:{$1});return .object(value)
                })
            } else {shape.merge(values,uniquingKeysWith:{$1})}
            properties[field] = .object(shape);record["properties"] = .object(properties);result[name] = .object(record)
        }
        constraint("DataPresentation","version",["const":.number(1)])
        constraint("PaperPresentation","version",["const":.number(1)])
        for color in ["paperColor","inkColor"] {constraint("PaperPresentation",color,["pattern":.string("^[A-Fa-f0-9]{6}$"),"minLength":.number(6),"maxLength":.number(6)])}
        constraint("LayerImageSequence","version",["const":.number(1)])
        constraint("LayerImageSequence","frames",["minItems":.number(2),"maxItems":.number(512)])
        constraint("LayerImageSequence","sourceOffsetFrames",["minimum":.number(0),"maximum":.number(54000)])
        constraint("LayerImageSequenceFrame","startFrame",["minimum":.number(0),"maximum":.number(53999)])
        constraint("LayerImageSequenceFrame","endFrame",["minimum":.number(1),"maximum":.number(54000)])
        constraint("LayerEntrance","version",["const":.number(1)])
        constraint("LayerEntrance","startFrame",["minimum":.number(0),"maximum":.number(53999)])
        constraint("LayerEntrance","endFrame",["minimum":.number(1),"maximum":.number(54000)])
        constraint("LayerEntrance","sourceOffsetFrames",["minimum":.number(0),"maximum":.number(54000)])
        constraint("DataPresentation","sourceOffsetFrames",["minimum":.number(0),"maximum":.number(54000)])
        for (name,field,count) in [("DataChart","series",8),("DataSeries","keyframes",128),("CodePresentation","lines",16)] {
            constraint(name,field,["minItems":.number(1),"maxItems":.number(Decimal(count))])
        }
        constraint("CodePresentation","highlights",["maxItems":.number(64)])
        constraint("CodePresentation","lines",["items":.object(["type":.string("string"),"maxLength":.number(120)])])
        for field in ["minimum","maximum"] {constraint("DataChart",field,["minimum":.number(-1_000_000_000),"maximum":.number(1_000_000_000)])}
        constraint("DataValueKeyframe","value",["minimum":.number(-1_000_000_000),"maximum":.number(1_000_000_000)])
        for (name,field) in [("DataValueKeyframe","frame"),("CodeHighlight","startFrame"),("CodeHighlight","endFrame")] {
            constraint(name,field,["minimum":.number(0),"maximum":.number(54000)])
        }
        constraint("CodeHighlight","line",["minimum":.number(0),"maximum":.number(15)])
        for (name,field,limit) in [("DataChart","title",64),("DataChart","axisLabel",20),("DataSeries","id",64),("DataSeries","label",20),("CodePresentation","title",64)] {
            constraint(name,field,["minLength":.number(1),"maxLength":.number(Decimal(limit))])
        }
        constraint("DataSeries","color",["pattern":.string("^[A-Fa-f0-9]{6}$")])
        for field in ["x","y"] {constraint("MediaFraming",field,["minimum":.number(0),"maximum":.number(1)])}
        for field in ["width","height"] {constraint("MediaFraming",field,["minimum":.number(Decimal(string:"0.01")!),"maximum":.number(1)])}
        var presentation=result["DataPresentation"]!.object!
        presentation["description"] = .string("作者给定数据/展示代码，不执行任意代码；chart与code只可选一个，且须匹配层kind。采样使用镜头源帧+sourceOffsetFrames，拆分后保原曲线。")
        presentation["oneOf"] = .array([
            .object(["required":.array([.string("chart")]),"properties":.object(["chart":shape("DataChart"),"code":.object(["type":.string("null")])])]),
            .object(["required":.array([.string("code")]),"properties":.object(["code":shape("CodePresentation"),"chart":.object(["type":.string("null")])])])
        ])
        result["DataPresentation"] = .object(presentation)
        for (key,declaration) in StoryActionSchema.records { var record=entity(declaration).object!;record["additionalProperties"] = .boolean(false);result[key] = .object(record) }
        for (key,declaration) in StoryCausalSchema.records {var record=entity(declaration).object!;record["additionalProperties"] = .boolean(false);result[key] = .object(record)}
        for (key,values) in StoryCausalSchema.enums {result[key] = .object(["type":.string("string"),"enum":.array(values.map(AgentValue.string))])}
        constraint("StoryCausality","version",["enum":.array([.number(1),.number(2),.number(3)])])
        constraint("StoryCausality","sources",["minItems":.number(1),"maxItems":.number(3)])
        constraint("StoryCausality","actors",["minItems":.number(1),"maxItems":.number(64)])
        constraint("StoryCausality","bindings",["minItems":.number(1),"maxItems":.number(256)])
        constraint("StoryCausalBinding","requires",["maxItems":.number(32)])
        constraint("StoryCausalActionCost","actionID",["pattern":.string("^[A-Za-z0-9_-]{1,40}$"),"minLength":.number(1),"maxLength":.number(40)])
        constraint("StoryCausalActionCost","newCost",["minimum":.number(0),"maximum":.number(100_000)])
        constraint("StoryCausalRuleChange","ruleID",["pattern":.string("^[A-Za-z0-9_-]{1,40}$"),"minLength":.number(1),"maxLength":.number(40)])
        // New optional fields are absent in old versions, never explicit nulls. Old
        // actor-plan DTOs and their nullable legacy fields keep their wire form.
        var causalSource=result["StoryCausalSource"]!.object!,sourceProperties=causalSource["properties"]!.object!
        sourceProperties["actionCost"]=shape("StoryCausalActionCost");sourceProperties["ruleChange"]=shape("StoryCausalRuleChange")
        causalSource["properties"] = .object(sourceProperties)
        causalSource["not"] = .object(["anyOf":.array([
            .object(["required":.array([.string("intervention"),.string("actionCost")])]),
            .object(["required":.array([.string("intervention"),.string("ruleChange")])]),
            .object(["required":.array([.string("actionCost"),.string("ruleChange")])])
        ])])
        causalSource["allOf"] = .array(["actionCost","ruleChange"].map { field in .object([
            "if":.object(["required":.array([.string(field)])]),
            "then":.object(["required":.array([.string("parentID")]),"properties":.object(["parentID":shape("s")])])
        ]) })
        result["StoryCausalSource"] = .object(causalSource)
        var causality=result["StoryCausality"]!.object!
        func versionedSources(_ version:Int,_ requirements:[String:AgentValue])->AgentValue {
            .object(["if":.object(["properties":.object(["version":.object(["const":.number(Decimal(version))])])]),
                "then":.object(["properties":.object(["sources":.object(requirements)])])])
        }
        let withoutRuleChange:AgentValue = .object(["not":.object(["required":.array([.string("ruleChange")])])])
        causality["allOf"] = .array([
            versionedSources(1,["items":.object(["not":.object(["anyOf":.array([
                .object(["required":.array([.string("actionCost")])]),.object(["required":.array([.string("ruleChange")])])])])])]),
            versionedSources(2,["items":withoutRuleChange,"contains":.object(["required":.array([.string("actionCost")])])]),
            versionedSources(3,["contains":.object(["required":.array([.string("ruleChange")])])])
        ])
        result["StoryCausality"] = .object(causality)
        for (key,values) in StoryActionSchema.enums { result[key] = .object(["type":.string("string"),"enum":.array(values.map(AgentValue.string))]) }
        for (key,declaration) in CartoonPresenterSchema.records {var record=entity(declaration).object!;record["additionalProperties"] = .boolean(false);result[key] = .object(record)}
        for (key,declaration) in CartoonPerformanceSchema.records { result[key]=entity(declaration) }
        for (key,values) in CartoonPerformanceSchema.enums { result[key] = .object(["type":.string("string"),"enum":.array(values.map(AgentValue.string))]) }
        for (key, declaration) in KnowledgeSimulationSchema.records { result[key] = entity(declaration) }
        for (key, values) in KnowledgeSimulationSchema.enums { result[key] = .object(["type": .string("string"), "enum": .array(values.map(AgentValue.string))]) }
        // These existing DTO decoders already reject unknown nested fields;
        // discovery must expose that same rule-replacement contract.
        for key in ["KnowledgeRule","KnowledgeRuleCondition","KnowledgeRuleEffect"] {
            var record=result[key]!.object!;record["additionalProperties"] = .boolean(false);result[key] = .object(record)
        }
        let enums:[String:[String]]=["Purpose":Purpose.allCases.map(\.rawValue),"SceneKind":SceneKind.allCases.map(\.rawValue),"Aspect":Aspect.allCases.map(\.rawValue),"RangeKind":CourseMapping.RangeKind.allCases.map(\.rawValue),"CustomerKind":CustomerKind.allCases.map(\.rawValue),"RevenueKind":RevenueKind.allCases.map(\.rawValue),"Settlement":Settlement.allCases.map(\.rawValue),"AuthorizationScope":AuthorizationScope.allCases.map(\.rawValue),"LayerKind":SceneLayer.Kind.allCases.map(\.rawValue),"PaperLayout":PaperPresentation.Layout.allCases.map(\.rawValue),"LayerEntranceKind":LayerEntrance.Kind.allCases.map(\.rawValue),"CharacterSilhouette":CharacterSilhouette.allCases.map(\.rawValue),"BaiduSegmentKind":["text","image","video"],"BillingKind":["charge","refundRequested","refundReceived"],"ClassicGameplay":ClassicGameplay.allCases.map(\.rawValue),"ClassicDerivation":ClassicArtwork.Derivation.allCases.map(\.rawValue),"ClassicAudioUse":ClassicAudioCue.Use.allCases.map(\.rawValue)]
        for (key,values) in enums{result[key] = .object(["type":.string("string"),"enum":.array(values.map(AgentValue.string))])}
        let edits:[String:String] = ["insertScene":"_0:Scene _1:i","replaceScene":"_0:s _1:Scene","removeScene":"_0:s","moveScene":"_0:s _1:i","splitScene":"_0:s _1:i","lockScene":"_0:s _1:b","aspect":"_0:Aspect","cta":"_0:s","music":"_0?:s","audioQuality":"_0?:AudioQualityPolicy","productionBrief":"_0?:ProductionBrief","purpose":"_0:Purpose","restore":"_0:s","lockLayer":"_0:s _1:s _2:b","recordSimulation":"_0:s","confirmSimulationRecording":"_0:s"]
        result["Edit"] = .object(["oneOf":.array(edits.keys.sorted().map{key in .object(["type":.string("object"),"required":.array([.string(key)]),"properties":.object([key:entity(edits[key]!)]),"additionalProperties":.boolean(false)])})])
        return result
    }
}
