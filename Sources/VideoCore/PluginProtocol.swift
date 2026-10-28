import Foundation

public enum PluginInputCompatibility {
    public static func supports(pluginID: String, version: Int) -> Bool {
        version == 1 || (pluginID == "video.game" && [2,3,5,6].contains(version)) || (pluginID == "video.cartoon" && version == 4)
    }
    /// Publisher defaults stay compatible with prior manifests. New endpoints must
    /// be selected explicitly, before any signing identity or output transaction.
    public static func publicationSchema(pluginID: String, requested: String? = nil) throws -> Int {
        guard ["video.game", "video.cartoon"].contains(pluginID) else {
            throw VideoError.invalid("发行协议选择需要明确的游戏或卡通模块；未访问发行身份")
        }
        guard let requested else { return pluginID == "video.game" ? 2 : 1 }
        guard requested.range(of: "^[1-9][0-9]{0,2}$", options: .regularExpression) != nil,
              let version = Int(requested), supports(pluginID: pluginID, version: version) else {
            throw VideoError.invalid("发行输入协议版本不受此模块支持；未访问发行身份")
        }
        return version
    }
    public static func requireKnowledgeSupport(_ simulation: Simulation, pluginID: String, inputSchema: Int, appearances: [KnowledgeParticipantAppearance]? = nil) throws {
        guard supports(pluginID: pluginID, version: inputSchema) else {
            throw VideoError.unavailable("此已安装模块的输入版本不受支持")
        }
        guard let knowledge = simulation.knowledge else {
            guard appearances == nil else { throw VideoError.invalid("参与者姿态映射缺少实际知识模型") }
            return
        }
        try knowledge.validate()
        let minimumSchema = appearances != nil ? 6 : knowledge.version == 3 ? 5 : knowledge.version == 2 ? 3 : 2
        guard pluginID == "video.game", inputSchema >= minimumSchema else {
            throw VideoError.unavailable("此已安装模块不支持当前知识模型输入；请安装相容且受信的高级模块，未退回旧计数器画面")
        }
    }
    public static func requireCartoonSupport(_ performance: CartoonPerformance?, pluginID: String, inputSchema: Int) throws {
        guard performance == nil || (pluginID == "video.cartoon" && inputSchema == 4) else {
            throw VideoError.unavailable("此模块不支持多角色表演输入；请安装相容且受信的卡通模块，未退回单角色摆动")
        }
    }
}

/// Public capability protocol. No filesystem grant, credentials, approvals or closed types.
public enum PluginMethod:String,Codable,CaseIterable,Sendable {
    case handshake,describe,validate,estimate,execute,progress,cancel,health
}
public struct PluginRect:Codable,Equatable,Sendable {
    public var x:Double;public var y:Double;public var width:Double;public var height:Double
    public init(x:Double,y:Double,width:Double,height:Double){self.x=x;self.y=y;self.width=width;self.height=height}
}
public struct PluginInvocation:Codable,Equatable,Sendable {
    public var workspaceID:String;public var projectID:String;public var revisionID:String;public var revisionDigest:String;public var jobID:String?
    public var invocationID:String;public var budgetReference:String;public var currency:String;public var budgetLimit:Decimal;public var deadlineUnixTime:Double
    public init(workspaceID:String,projectID:String,revisionID:String,revisionDigest:String,jobID:String?=nil,invocationID:String,budgetReference:String,currency:String,budgetLimit:Decimal=0,deadlineUnixTime:Double){
        self.workspaceID=workspaceID;self.projectID=projectID;self.revisionID=revisionID;self.revisionDigest=revisionDigest;self.jobID=jobID;self.invocationID=invocationID;self.budgetReference=budgetReference;self.currency=currency;self.budgetLimit=budgetLimit;self.deadlineUnixTime=deadlineUnixTime
    }
}
public struct PluginCharacterProps:Codable,Equatable,Sendable {
    public var silhouette:CharacterSilhouette;public var color:String;public var actions:[String]
    public init(silhouette:CharacterSilhouette,color:String,actions:[String]){self.silhouette=silhouette;self.color=color;self.actions=actions}
}
public struct PluginArtworkProps:Codable,Equatable,Sendable {
    public var gameplay:ClassicGameplay;public var sprites:[ClassicSprite];public var derivation:ClassicArtwork.Derivation
    public var knowledgeParticipants:[KnowledgeParticipantAppearance]?
    public init(gameplay:ClassicGameplay,sprites:[ClassicSprite],derivation:ClassicArtwork.Derivation,knowledgeParticipants:[KnowledgeParticipantAppearance]?=nil){self.gameplay=gameplay;self.sprites=sprites;self.derivation=derivation;self.knowledgeParticipants=knowledgeParticipants}
}
/// Deliberately not Scene: narration text, titles, source documents, voices and review cannot cross.
public struct PluginVisualProps:Codable,Equatable,Sendable {
    public var sceneID:String;public var kind:SceneKind;public var durationFrames:Int;public var simulation:Simulation
    public var character:String;public var emotion:String;public var color:String;public var fontName:String
    public var narrationPresent:Bool;public var characterProfile:PluginCharacterProps?;public var artwork:PluginArtworkProps?;public var artworkRequired:Bool
    public var cartoonPerformance:CartoonPerformance?
    public init(scene:Scene){
        sceneID=scene.id;kind=scene.kind;durationFrames=scene.durationFrames;simulation=scene.simulation
        character=scene.character;emotion=scene.emotion;color=scene.color;fontName=scene.fontName ?? "PingFangSC-Medium";narrationPresent = !scene.narration.isEmpty
        characterProfile=scene.characterProfile.map{PluginCharacterProps(silhouette:$0.silhouette,color:$0.color,actions:$0.actions)}
        cartoonPerformance=scene.cartoonPerformance
        artwork=scene.classicArtwork.map{PluginArtworkProps(gameplay:$0.gameplay,sprites:$0.sprites,derivation:$0.derivation,knowledgeParticipants:$0.knowledgeParticipants)};artworkRequired=true
    }
    /// Reconstruct only parameters used by the existing actual drawing implementations.
    /// This is not an authorized/reviewed Scene and must never be saved into a customer project.
    public func drawingScene()->Scene {
        var result=Scene(kind:kind,title:"",body:"",narration:narrationPresent ? "speech":"",durationFrames:durationFrames)
        result.id=sceneID;result.simulation=simulation;result.character=character;result.emotion=emotion;result.color=color;result.fontName=fontName;result.classicArtworkRequired=artworkRequired
        result.cartoonPerformance=cartoonPerformance
        result.characterProfile=characterProfile.map{CharacterProfile(name:character,silhouette:$0.silhouette,color:$0.color,expressions:[],actions:$0.actions,evidenceIDs:[],voiceAssetID:nil,original:false)}
        result.classicArtwork=artwork.map{ClassicArtwork(gameplay:$0.gameplay,sprites:$0.sprites,sources:[],derivation:$0.derivation,knowledgeParticipants:$0.knowledgeParticipants)}
        return result
    }
}
public struct PluginRasterAsset:Codable,Equatable,Sendable {
    public var assetID:String;public var data:Data;public var sha256:String;public var width:Int;public var height:Int
    public init(assetID:String,data:Data,sha256:String,width:Int,height:Int){self.assetID=assetID;self.data=data;self.sha256=sha256;self.width=width;self.height=height}
}
public struct PluginFrameInput:Codable,Equatable,Sendable {
    public var invocation:PluginInvocation;public var props:PluginVisualProps;public var sourceFrame:Int;public var fps:Int
    public var canvasWidth:Int;public var canvasHeight:Int;public var rect:PluginRect;public var assets:[PluginRasterAsset]
    public init(invocation:PluginInvocation,props:PluginVisualProps,sourceFrame:Int,fps:Int,canvasWidth:Int,canvasHeight:Int,rect:PluginRect,assets:[PluginRasterAsset]){self.invocation=invocation;self.props=props;self.sourceFrame=sourceFrame;self.fps=fps;self.canvasWidth=canvasWidth;self.canvasHeight=canvasHeight;self.rect=rect;self.assets=assets}
    public func contentDigest()throws->String {try Codec.digest(self)}
}
public struct PluginPNGFrame:Codable,Equatable,Sendable {
    public var data:Data;public var sha256:String;public var width:Int;public var height:Int;public var sourceFrame:Int;public var inputDigest:String;public var dependencyFingerprints:[String:String]
    public init(data:Data,width:Int,height:Int,sourceFrame:Int,inputDigest:String,dependencyFingerprints:[String:String]){self.data=data;self.sha256=Codec.hash(data);self.width=width;self.height=height;self.sourceFrame=sourceFrame;self.inputDigest=inputDigest;self.dependencyFingerprints=dependencyFingerprints}
}
public enum PluginTaskState:String,Codable,Sendable {case running,succeeded,cancelled,failed,timedOut}
public struct PluginTaskSnapshot:Codable,Equatable,Sendable {
    public var taskID:String;public var inputDigest:String;public var invocation:PluginInvocation;public var state:PluginTaskState;public var progress:Double;public var frame:PluginPNGFrame?;public var error:PluginRPCError?
    public init(taskID:String,inputDigest:String,invocation:PluginInvocation,state:PluginTaskState,progress:Double=0,frame:PluginPNGFrame?=nil,error:PluginRPCError?=nil){self.taskID=taskID;self.inputDigest=inputDigest;self.invocation=invocation;self.state=state;self.progress=progress;self.frame=frame;self.error=error}
}
public struct PluginCost:Codable,Equatable,Sendable {
    public var actual:Money;public var budgetReference:String;public var exclusions:[String]
    public init(currency:String,budgetReference:String){actual=Money(0,currency);self.budgetReference=budgetReference;exclusions=["设备、人工和电力不包含在本地绘制增量现金费用中","不改变原任务供应商费用、占用或退款记录"]}
}
public struct PluginDescription:Codable,Equatable,Sendable {
    public var pluginID:String;public var capabilityID:String;public var version:String;public var methods:[PluginMethod];public var inputSchemaVersion:Int;public var outputSchemaVersion:Int
    public var inputContract:String;public var outputContract:String;public var inputSchema:AgentValue;public var outputSchema:AgentValue;public var filesystemAccess:Bool;public var networkAccess:Bool
    public init(pluginID:String,capabilityID:String,version:String,inputSchemaVersion:Int=1){self.pluginID=pluginID;self.capabilityID=capabilityID;self.version=version;methods=PluginMethod.allCases;self.inputSchemaVersion=inputSchemaVersion;outputSchemaVersion=1;inputContract="PluginFrameInput v\(inputSchemaVersion): visual-only props, already-mapped source frame, byte-bound image bank, frozen invocation and budget reference";outputContract="PluginTaskSnapshot v1: cancellable asynchronous frame task; verified transparent sRGB PNG Data, input digest and dependency fingerprints";inputSchema=PluginRPCSchemas.request(inputSchemaVersion:inputSchemaVersion);outputSchema=PluginRPCSchemas.response(inputSchemaVersion:inputSchemaVersion);filesystemAccess=false;networkAccess=false}
}
public struct PluginRPCError:Codable,Equatable,Sendable {
    public var code:String;public var message:String;public var retryable:Bool;public var nextAction:String
    public init(code:String,message:String,retryable:Bool=false,nextAction:String="核对当前协议、冻结输入与原任务；不要重建付费请求"){self.code=code;self.message=message;self.retryable=retryable;self.nextAction=nextAction}
}
public struct PluginRPCRequest:Codable,Sendable {
    public var protocolMajor:Int;public var requestID:String;public var method:PluginMethod;public var input:PluginFrameInput?;public var invocation:PluginInvocation?;public var taskID:String?
    public init(requestID:String,method:PluginMethod,input:PluginFrameInput?=nil,invocation:PluginInvocation?=nil,taskID:String?=nil,protocolMajor:Int=1){self.protocolMajor=protocolMajor;self.requestID=requestID;self.method=method;self.input=input;self.invocation=invocation;self.taskID=taskID}
}
public struct PluginRPCResponse:Codable,Sendable {
    public var protocolMajor=1;public var requestID:String;public var ok:Bool;public var state:String;public var descriptor:PluginDescription?;public var inputDigest:String?;public var task:PluginTaskSnapshot?;public var cost:PluginCost?;public var error:PluginRPCError?
    public init(requestID:String,ok:Bool,state:String,descriptor:PluginDescription?=nil,inputDigest:String?=nil,task:PluginTaskSnapshot?=nil,cost:PluginCost?=nil,error:PluginRPCError?=nil){self.requestID=requestID;self.ok=ok;self.state=state;self.descriptor=descriptor;self.inputDigest=inputDigest;self.task=task;self.cost=cost;self.error=error}
}
public enum PluginProtocolRules {
    public static let maximumRequestBytes=16*1024*1024
    public static let maximumResponseBytes=16*1024*1024
    public static let maximumAssetBytes=8*1024*1024
    public static let maximumTotalAssetBytes=10*1024*1024
    public static let maximumPNGBytes=8*1024*1024
    public static let maximumImagePixels=24_000_000
    public static let maximumTotalImagePixels=48_000_000
    public static let maximumCanvasPixels=2_073_600
    public static let maximumTaskSeconds:Double=120
    public static let maximumInvocationSeconds:Double=4*60*60
    public static func text(_ value:String,maximum:Int=256)->Bool{!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.utf8.count<=maximum && !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)}
    public static func hash(_ value:String)->Bool{value.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}
    public static func validate(_ invocation:PluginInvocation,now:Date=Date())throws {
        guard [invocation.workspaceID,invocation.projectID,invocation.revisionID,invocation.invocationID,invocation.budgetReference].allSatisfy({text($0)}),invocation.jobID.map({text($0)}) ?? true,hash(invocation.revisionDigest),invocation.currency.range(of:"^[A-Z]{3}$",options:.regularExpression) != nil,!invocation.budgetLimit.isNaN,invocation.budgetLimit>=0,invocation.deadlineUnixTime.isFinite,invocation.deadlineUnixTime>now.timeIntervalSince1970,invocation.deadlineUnixTime<=now.timeIntervalSince1970+maximumInvocationSeconds else{throw VideoError.permission("插件调用缺少有效冻结身份、预算引用或有界截止")}
    }
    public static func validate(_ input:PluginFrameInput,capabilityID:String,now:Date=Date())throws {
        try validate(input.invocation,now:now)
        let p=input.props,r=input.rect
        guard text(p.sceneID),(1...54000).contains(p.durationFrames),(0...216000).contains(input.sourceFrame),(1...120).contains(input.fps),(1...4096).contains(input.canvasWidth),(1...4096).contains(input.canvasHeight),input.canvasWidth*input.canvasHeight<=maximumCanvasPixels,[r.x,r.y,r.width,r.height].allSatisfy(\.isFinite),r.width>0,r.height>0,r.width<=Double(input.canvasWidth)*4,r.height<=Double(input.canvasHeight)*4,abs(r.x)<=Double(input.canvasWidth)*4,abs(r.y)<=Double(input.canvasHeight)*4 else{throw VideoError.invalid("插件帧、画布或裁切范围无效")}
        guard (capabilityID=="game.simulate" && p.kind == .simulation) || (capabilityID=="cartoon.animate" && p.kind == .cartoon) else{throw VideoError.invalid("插件能力与视觉输入类型不符")}
        guard [p.character,p.emotion,p.fontName].allSatisfy({text($0,maximum:512)}),p.color.range(of:"^[a-fA-F0-9]{6}$",options:.regularExpression) != nil,p.simulation.events.count<=4096,p.simulation.unit.utf8.count<=512,p.simulation.events.allSatisfy({text($0.label,maximum:512)}) else{throw VideoError.invalid("插件视觉参数或事件数量超界")}
        if let profile=p.characterProfile {guard profile.actions.count<=64,profile.actions.allSatisfy({text($0,maximum:512)}),profile.color.range(of:"^[a-fA-F0-9]{6}$",options:.regularExpression) != nil else{throw VideoError.invalid("插件角色动作或颜色无效")}}
        _ = try SimulationReplay.frameState(simulation:p.simulation,frame:input.sourceFrame,fps:input.fps)
        guard input.assets.count<=32,Set(input.assets.map(\.assetID)).count==input.assets.count else{throw VideoError.invalid("插件图片数量或标识重复")}
        var bytes=0,pixels=0
        for asset in input.assets {
            guard text(asset.assetID),!asset.data.isEmpty,asset.data.count<=maximumAssetBytes,hash(asset.sha256),Codec.hash(asset.data)==asset.sha256,(1...8192).contains(asset.width),(1...8192).contains(asset.height),asset.width*asset.height<=maximumImagePixels else{throw VideoError.invalid("插件图片字节、摘要或尺寸无效")}
            bytes+=asset.data.count;pixels+=asset.width*asset.height
            guard bytes<=maximumTotalAssetBytes,pixels<=maximumTotalImagePixels else{throw VideoError.invalid("插件图片总量超出有界预算")}
        }
        guard p.artworkRequired,let artwork=p.artwork else{throw VideoError.review("高级插件只接受实际图集输入，不启用旧几何默认")}
        do {
            let roles=Set(artwork.sprites.map(\.role)),required = ClassicArtworkRules.requiredRoles(knowledge: p.kind == .simulation && p.simulation.knowledge != nil, cartoon: p.kind == .cartoon)
            guard !artwork.sprites.isEmpty,artwork.sprites.count<=32,roles.count==artwork.sprites.count,required.isSubset(of:roles),Set(artwork.sprites.map(\.assetID))==Set(input.assets.map(\.assetID)) else{throw VideoError.invalid("插件图块与实际图片集合不符")}
            for s in artwork.sprites {guard text(s.role,maximum:512),[s.x,s.y,s.width,s.height].allSatisfy(\.isFinite),s.x>=0,s.y>=0,s.width>0,s.height>0,s.x+s.width<=1.000001,s.y+s.height<=1.000001 else{throw VideoError.invalid("插件图块坐标无效")}}
            if let performance=p.cartoonPerformance {
                guard p.kind == .cartoon else { throw VideoError.invalid("多角色表演仅用于实际图集的卡通输入") }
                try performance.validate(durationFrames:p.durationFrames,sprites:artwork.sprites,
                    imageHashes:Dictionary(uniqueKeysWithValues:input.assets.map{($0.assetID,$0.sha256)}))
            }
            let visual=ClassicArtwork(gameplay:artwork.gameplay,sprites:artwork.sprites,sources:[],derivation:artwork.derivation,knowledgeParticipants:artwork.knowledgeParticipants)
            try KnowledgeParticipantAppearanceRules.validate(artwork:visual,knowledge:p.kind == .simulation ? p.simulation.knowledge:nil,
                imageHashes:Dictionary(uniqueKeysWithValues:input.assets.map{($0.assetID,$0.sha256)}))
        }
    }
    public static func validate(_ frame:PluginPNGFrame,input:PluginFrameInput)throws {
        guard input.assets.count<=32,Set(input.assets.map(\.assetID)).count==input.assets.count else{throw VideoError.invalid("帧校验的依赖图片标识重复或数量超界")}
        guard !frame.data.isEmpty,frame.data.count<=maximumPNGBytes,frame.sha256==Codec.hash(frame.data),frame.width==input.canvasWidth,frame.height==input.canvasHeight,frame.sourceFrame==input.sourceFrame,frame.inputDigest == (try input.contentDigest()),frame.dependencyFingerprints==Dictionary(uniqueKeysWithValues:input.assets.map{($0.assetID,$0.sha256)}) else{throw VideoError.permission("插件图层不属于冻结输入、帧或已核图片，拒绝采用")}
    }
}

/// Discovery is the actual Codable wire shape, not an unrelated sample payload.
public enum PluginRPCSchemas {
    private static func shape(_ type:String)->AgentValue {
        if type.hasPrefix("["){return .object(["type":.string("array"),"items":shape(String(type.dropFirst().dropLast()))])}
        if type.hasPrefix("{"){return .object(["type":.string("object"),"additionalProperties":shape(String(type.dropFirst().dropLast()))])}
        switch type {case "s":return .object(["type":.string("string")]);case "i":return .object(["type":.string("integer")]);case "n":return .object(["type":.string("number")]);case "b":return .object(["type":.string("boolean")]);case "data":return .object(["type":.string("string"),"contentEncoding":.string("base64")]);case "hashes":return .object(["type":.string("object"),"additionalProperties":shape("s")]);default:return .object(["$ref":.string("#/$defs/"+type)])}
    }
    private static func record(_ declaration:String)->AgentValue {
        var properties:[String:AgentValue]=[:],required:[AgentValue]=[]
        for entry in declaration.split(separator:" ") {let parts=entry.split(separator:":",maxSplits:1);let optional=parts[0].hasSuffix("?"),key=String(optional ? parts[0].dropLast():parts[0]);properties[key]=shape(String(parts[1]));if !optional{required.append(.string(key))}}
        return .object(["type":.string("object"),"properties":.object(properties),"required":.array(required),"additionalProperties":.boolean(false)])
    }
    public static func definitions(inputSchemaVersion: Int = 2)->[String:AgentValue] {
        let declarations:[String:String]=[
            "PluginInvocation":"workspaceID:s projectID:s revisionID:s revisionDigest:s jobID?:s invocationID:s budgetReference:s currency:s budgetLimit:n deadlineUnixTime:n",
            "PluginRect":"x:n y:n width:n height:n",
            "PluginFrameInput":"invocation:PluginInvocation props:PluginVisualProps sourceFrame:i fps:i canvasWidth:i canvasHeight:i rect:PluginRect assets:[PluginRasterAsset]",
            "PluginVisualProps":"sceneID:s kind:SceneKind durationFrames:i simulation:Simulation character:s emotion:s color:s fontName:s narrationPresent:b characterProfile?:PluginCharacterProps artwork?:PluginArtworkProps artworkRequired:b" + (inputSchemaVersion >= 4 ? " cartoonPerformance?:CartoonPerformance" : ""),
            "PluginCharacterProps":"silhouette:CharacterSilhouette color:s actions:[s]",
            "PluginArtworkProps":"gameplay:ClassicGameplay sprites:[ClassicSprite] derivation:Derivation" + (inputSchemaVersion >= 6 ? " knowledgeParticipants?:[KnowledgeParticipantAppearance]" : ""),
            "ClassicSprite":"role:s assetID:s x:n y:n width:n height:n",
            "Simulation":"seed:n initial:i capacity:i unit:s events:[RuleEvent]" + (inputSchemaVersion >= 2 ? " knowledge?:KnowledgeSimulation" : ""),
            "RuleEvent":"id:s tick:i delta:i label:s",
            "PluginRasterAsset":"assetID:s data:data sha256:s width:i height:i",
            "PluginPNGFrame":"data:data sha256:s width:i height:i sourceFrame:i inputDigest:s dependencyFingerprints:hashes",
            "PluginTaskSnapshot":"taskID:s inputDigest:s invocation:PluginInvocation state:PluginTaskState progress:n frame?:PluginPNGFrame error?:PluginRPCError",
            "PluginRPCError":"code:s message:s retryable:b nextAction:s",
            "Money":"amount:n currency:s",
            "PluginCost":"actual:Money budgetReference:s exclusions:[s]",
            "PluginDescription":"pluginID:s capabilityID:s version:s methods:[PluginMethod] inputSchemaVersion:i outputSchemaVersion:i inputContract:s outputContract:s inputSchema:Schema outputSchema:Schema filesystemAccess:b networkAccess:b"
        ]
        var result=declarations.mapValues(record)
        if inputSchemaVersion >= 6 {
            result["KnowledgeParticipantAppearance"]=record("participantID:s poseRoles:{s}")
        }
        if inputSchemaVersion >= 4 {
            for (key,declaration) in CartoonPerformanceSchema.records { result[key]=record(declaration) }
            for (key,values) in CartoonPerformanceSchema.enums { result[key] = .object(["type":.string("string"),"enum":.array(values.map(AgentValue.string))]) }
        }
        if inputSchemaVersion >= 2 {
            for (key, declaration) in KnowledgeSimulationSchema.records(forInputSchemaVersion: inputSchemaVersion) { result[key] = record(declaration) }
            for (key, values) in KnowledgeSimulationSchema.enums(forInputSchemaVersion: inputSchemaVersion) { result[key] = .object(["type": .string("string"), "enum": .array(values.map(AgentValue.string))]) }
        }
        let enums:[String:[String]]=["SceneKind":[SceneKind.simulation.rawValue,SceneKind.cartoon.rawValue],"CharacterSilhouette":["圆形","方形","菱形"],"ClassicGameplay":ClassicGameplay.allCases.map(\.rawValue),"Derivation":[ClassicArtwork.Derivation.original.rawValue,ClassicArtwork.Derivation.qStyle.rawValue],"PluginTaskState":["running","succeeded","cancelled","failed","timedOut"],"PluginMethod":PluginMethod.allCases.map(\.rawValue)]
        for(key,values)in enums{result[key] = .object(["type":.string("string"),"enum":.array(values.map(AgentValue.string))])}
        result["Schema"] = .object(["type":.string("object")]);return result
    }
    public static func request(inputSchemaVersion: Int = 2)->AgentValue {
        var schema=record("protocolMajor:i requestID:s method:PluginMethod input?:PluginFrameInput invocation?:PluginInvocation taskID?:s").object!
        schema["$defs"] = .object(definitions(inputSchemaVersion: inputSchemaVersion));schema["$schema"] = .string("https://json-schema.org/draft/2020-12/schema")
        schema["description"] = .string("protocolMajor=1. validate/estimate/execute require input. progress/cancel require the complete matching invocation; progress also requires taskID. cancel without taskID closes the whole invocation and exits the service.")
        return .object(schema)
    }
    public static func response(inputSchemaVersion: Int = 2)->AgentValue {
        var schema=record("protocolMajor:i requestID:s ok:b state:s descriptor?:PluginDescription inputDigest?:s task?:PluginTaskSnapshot cost?:PluginCost error?:PluginRPCError").object!
        schema["$defs"] = .object(definitions(inputSchemaVersion: inputSchemaVersion));schema["$schema"] = .string("https://json-schema.org/draft/2020-12/schema");return .object(schema)
    }
}
