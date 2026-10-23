import Foundation

/// Discovery describes the actual Codable wire names, including synthesized enum
/// payloads and stored defaults (which JSONDecoder still requires). Domain rules
/// and current permissions are evaluated separately; a schema never grants access.
public enum AgentSchemas {
    public static let fieldTypes:[String:String] = ["baidu_input":"BaiduVideoInput","product":"Product","evidence":"Evidence","review":"Review","quote":"Quote","budget":"BudgetPolicy","publication":"Publication","sale":"ToolSale","deal":"BrandDeal","expense":"Expense","cash":"CashEntry","baseline":"Baseline","estimate":"EstimateBreakdown","billing_record":"BillingRecord","orders":"[Order]","metrics":"[Metric]","edits":"[Edit]","scenes":"[Scene]","evidence_ids":"[s]","job_ids":"[s]"]
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
            "Scene":"id:s kind:SceneKind title:s body:s narration:s durationFrames:i assetID?:s evidenceIDs:[s] sourceStartFrame:i sourceEndFrame?:i speed:n preservePitch:b locked:b x:n y:n scale:n voiceGain:n sourceGain:n musicGain:n muted:b pauseFrames:i captions:[Caption] voice?:VoiceTake simulation:Simulation character:s emotion:s color:s showPrice:b keyframes:[Keyframe] courseMappingIDs?:[s] speechPlan?:SpeechPlan layers?:[SceneLayer] characterProfile?:CharacterProfile narrativeSources?:[NarrativeSource] fontName?:s classicArtwork?:ClassicArtwork classicArtworkRequired?:b simulationRecording?:RuleTrace simulationRecordingConfirmed?:b",
            "ClassicArtwork":"gameplay:ClassicGameplay sprites:[ClassicSprite] sources:[ClassicSource] derivation:ClassicDerivation transformation:s originalAssetIDs:[s] audioCues:[ClassicAudioCue]",
            "ClassicSprite":"role:s assetID:s x:n y:n width:n height:n",
            "ClassicSource":"assetID:s hash:s source:s owner:s license:s evidenceID:s",
            "ClassicAudioCue":"id:s assetID:s startFrame:i durationFrames:i gain:n use:ClassicAudioUse listened:b",
            "Caption":"id:s text:s startFrame:i endFrame:i alignment:s confirmed:b",
            "VoiceTake":"assetID:s textDigest:s durationFrames:i method:s listened:b",
            "Simulation":"seed:i initial:i capacity:i unit:s events:[RuleEvent]",
            "RuleEvent":"id:s tick:i delta:i label:s",
            "RuleTrace":"ruleVersion:i inputDigest:s seed:i unit:s initial:i capacity:i throughTick:i frameStep:i transitions:[RuleTransition] finalState:i recordedFPS?:i recordedDurationFrames?:i recordedSpeed?:n recordedPauseFrames?:i recordedLastSourceFrame?:i",
            "RuleTransition":"tick:i eventID:s label:s requestedDelta:i before:i after:i appliedDelta:i clippedDelta:i",
            "Keyframe":"id:s frame:i x:n y:n scale:n",
            "SceneLayer":"id:s kind:LayerKind text:s assetID?:s x:n y:n width:n height:n color:s opacity:n startFrame:i endFrame:i locked:b keyframes:[Keyframe]",
            "SpeechPlan":"source:s normalized:s dictionary:[SpeechTerm] mappings:[SpeechMapping] voiceIdentifier?:s rate:n confirmed:b notes:[s]",
            "SpeechTerm":"term:s pronunciation:s",
            "SpeechMapping":"sourceStart:i sourceLength:i normalizedStart:i normalizedLength:i kind:s",
            "CharacterProfile":"id:s name:s silhouette:CharacterSilhouette color:s expressions:[s] actions:[s] evidenceIDs:[s] voiceAssetID?:s original:b",
            "NarrativeSource":"id:s assetID:s pages:[i] startFrame?:i endFrame?:i excerpt:s confirmed:b"
        ]
        var result=records.mapValues(entity)
        let enums:[String:[String]]=["SceneKind":SceneKind.allCases.map(\.rawValue),"Aspect":Aspect.allCases.map(\.rawValue),"RangeKind":CourseMapping.RangeKind.allCases.map(\.rawValue),"CustomerKind":CustomerKind.allCases.map(\.rawValue),"RevenueKind":RevenueKind.allCases.map(\.rawValue),"Settlement":Settlement.allCases.map(\.rawValue),"AuthorizationScope":AuthorizationScope.allCases.map(\.rawValue),"LayerKind":SceneLayer.Kind.allCases.map(\.rawValue),"CharacterSilhouette":CharacterSilhouette.allCases.map(\.rawValue),"BaiduSegmentKind":["text","image","video"],"BillingKind":["charge","refundRequested","refundReceived"],"ClassicGameplay":ClassicGameplay.allCases.map(\.rawValue),"ClassicDerivation":ClassicArtwork.Derivation.allCases.map(\.rawValue),"ClassicAudioUse":ClassicAudioCue.Use.allCases.map(\.rawValue)]
        for (key,values) in enums{result[key] = .object(["type":.string("string"),"enum":.array(values.map(AgentValue.string))])}
        let edits:[String:String] = ["insertScene":"_0:Scene _1:i","replaceScene":"_0:s _1:Scene","removeScene":"_0:s","moveScene":"_0:s _1:i","splitScene":"_0:s _1:i","lockScene":"_0:s _1:b","aspect":"_0:Aspect","cta":"_0:s","music":"_0?:s","audioQuality":"_0?:AudioQualityPolicy","restore":"_0:s","lockLayer":"_0:s _1:s _2:b","recordSimulation":"_0:s","confirmSimulationRecording":"_0:s"]
        result["Edit"] = .object(["oneOf":.array(edits.keys.sorted().map{key in .object(["type":.string("object"),"required":.array([.string(key)]),"properties":.object([key:entity(edits[key]!)]),"additionalProperties":.boolean(false)])})])
        return result
    }
}
