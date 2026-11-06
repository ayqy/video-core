import Foundation

public enum PluginInputCompatibility {
    public static func supports(pluginID: String, version: Int) -> Bool {
        version == 1 || (pluginID == "video.game" && [2,3,5,6,7,8,9,10,11,12,13,14].contains(version)) || (pluginID == "video.cartoon" && [4,5,6,7,8].contains(version))
    }
    /// Publisher defaults match the current endpoints. Prior schemas remain
    /// explicitly selectable, before any signing identity or output transaction.
    public static func publicationSchema(pluginID: String, requested: String? = nil) throws -> Int {
        guard ["video.game", "video.cartoon"].contains(pluginID) else {
            throw VideoError.invalid("发行协议选择需要明确的游戏或卡通模块；未访问发行身份")
        }
        guard let requested else { return pluginID == "video.game" ? 14:8 }
        guard requested.range(of: "^[1-9][0-9]{0,2}$", options: .regularExpression) != nil,
              let version = Int(requested), supports(pluginID: pluginID, version: version) else {
            throw VideoError.invalid("发行输入协议版本不受此模块支持；未访问发行身份")
        }
        return version
    }
    public static func supportsModelBank(pluginID:String,inputSchema:Int)->Bool {
        pluginID == "video.game" && [9,10,11,12,13,14].contains(inputSchema)
    }
    /// A new endpoint may read the unchanged v1 model, but v2 actions must never
    /// be sent to game9 or silently reduced to its transform-only contract.
    public static func requireModelSupport(_ model:ModelScene3D?,pluginID:String,inputSchema:Int)throws {
        guard let model else{return}
        let compatible = supportsModelBank(pluginID:pluginID,inputSchema:inputSchema) &&
            (!model.instances.contains(where:{$0.nodeVariants != nil}) || [11,12,13,14].contains(inputSchema)) &&
            (!model.instances.contains(where:{$0.materialInterpretation?.alphaCutoutMaterialIDs != nil}) || [12,13,14].contains(inputSchema)) &&
            (model.camera.keyframes==nil || [13,14].contains(inputSchema)) &&
            (model.dialogueObstacleInstanceIDs==nil || inputSchema==14) &&
            ((model.version==1 && model.actions==nil) ||
             ([10,11,12,13,14].contains(inputSchema) && model.version==2 && !(model.actions?.isEmpty ?? true)))
        guard compatible else {
            throw VideoError.unavailable("三维模型v1需要schema9至14；原生动作v2需要schema10至14；显式节点互斥切换需要schema11至14；透明裁切需要schema12至14；源帧镜头关键帧需要schema13/14；显式对白避让名单需要schema14受信游戏模块，旧模块不能忽略新解释、状态、动作、镜头或角色名单")
        }
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
        guard performance == nil || (pluginID == "video.cartoon" && [4,5,6,7,8].contains(inputSchema)) else {
            throw VideoError.unavailable("此模块不支持多角色表演输入；请安装相容且受信的卡通模块，未退回单角色摆动")
        }
    }
    public static func requirePresenterSupport(_ presenter:CartoonPresenter?,pluginID:String,inputSchema:Int) throws {
        guard presenter==nil || (pluginID=="video.cartoon" && [7,8].contains(inputSchema)) else {throw VideoError.unavailable("图片序列解说员需要显式cartoon7模块；旧包不回退或忽略新帧")}
        guard presenter?.anchor == nil || inputSchema>=8 else {throw VideoError.unavailable("显式解说员锚定需要cartoon8；旧模块不能忽略锚定字段")}
    }
    public static func requireLayoutSupport(layers:[SceneLayer]?,actions:[StoryAction]?,presenter:CartoonPresenter?,pluginID:String,inputSchema:Int) throws {
        guard layers?.contains(where:{$0.texturedPath != nil}) == true || actions?.contains(where:{$0.waypoints != nil}) == true || presenter?.anchor != nil else {return}
        guard ["video.game","video.cartoon"].contains(pluginID),inputSchema>=8 else {throw VideoError.unavailable("纹理路网、路线中间点或解说员锚定需要schema8；旧模块不能忽略新布局字段")}
    }
    public static func requireStorySupport(storyActions:[StoryAction]?,gameWorld:GameWorld?,cartoonRig:CartoonRig?,pluginID:String,inputSchema:Int) throws {
        guard storyActions != nil || gameWorld != nil || cartoonRig != nil else {return}
        try requireLayoutSupport(layers:nil,actions:storyActions,presenter:nil,pluginID:pluginID,inputSchema:inputSchema)
        if gameWorld?.usesRenderPlanes == true {
            guard pluginID == "video.game",inputSchema>=8 else {throw VideoError.unavailable("显式游戏地面层需要game8相容受信模块；旧模块不能忽略分层字段")}
        }
        if let rig=cartoonRig {
            guard [1,2].contains(rig.version),rig.version != 2 || (pluginID=="video.cartoon" && [6,7,8].contains(inputSchema)) else {throw VideoError.unavailable("显式卡通rig v2须使用cartoon6或7；未知rig版本不回退旧画法")}
        }
        guard supports(pluginID:pluginID,version:inputSchema),
              (pluginID == "video.game" && inputSchema>=7 && cartoonRig==nil) ||
              (pluginID == "video.cartoon" && inputSchema>=5 && gameWorld==nil) else {throw VideoError.unavailable("动态游戏世界、故事动作或能量卡通rig需要game7/cartoon5相容受信模块；显式rig v2需要cartoon6，未退回旧画面")}
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
    public var storyActions:[StoryAction]?;public var gameWorld:GameWorld?;public var cartoonRig:CartoonRig?
    public var layers:[SceneLayer]?;public var voiceBinding:CartoonSpeechBinding?
    public var cartoonPresenter:CartoonPresenter?
    public var modelScene3D:ModelScene3D?
    public init(scene:Scene,voiceBinding:CartoonSpeechBinding?=nil){
        sceneID=scene.id;kind=scene.kind;durationFrames=scene.durationFrames;simulation=scene.simulation
        character=scene.character;emotion=scene.emotion;color=scene.color;fontName=scene.fontName ?? "PingFangSC-Medium";narrationPresent = !scene.narration.isEmpty
        characterProfile=scene.characterProfile.map{PluginCharacterProps(silhouette:$0.silhouette,color:$0.color,actions:$0.actions)}
        cartoonPerformance=scene.cartoonPerformance
        storyActions=scene.storyActions;gameWorld=scene.gameWorld;cartoonRig=scene.cartoonRig;cartoonPresenter=scene.cartoonPresenter;modelScene3D=scene.modelScene3D
        // Native v2 consumes only actual visual tracks/actions. Its complete
        // rule model, multi-source traces and causal proof remain in the Host.
        // Preserve the original simulation wire exactly for every v1 caller.
        if modelScene3D?.version==2 {simulation.knowledge=nil}
        // Ordinary image pixels are drawn by the Host. Keep this Host-only
        // field out of the frozen RPC snapshot so older plugins encode the same
        // input digest without changing the original Scene or its layer pixels.
        layers=(scene.storyActions != nil || scene.cartoonRig != nil || scene.gameWorld != nil || scene.cartoonPresenter != nil) ? scene.layers?.map {
            var visual=$0;visual.imageFlipHorizontal=nil;return visual
        }:nil
        self.voiceBinding=voiceBinding
        artwork=scene.classicArtwork.map{PluginArtworkProps(gameplay:$0.gameplay,sprites:$0.sprites,derivation:$0.derivation,knowledgeParticipants:$0.knowledgeParticipants)};artworkRequired=scene.cartoonRig == nil && scene.modelScene3D == nil
    }
    /// Reconstruct only parameters used by the existing actual drawing implementations.
    /// This is not an authorized/reviewed Scene and must never be saved into a customer project.
    public func drawingScene()->Scene {
        var result=Scene(kind:kind,title:"",body:"",narration:narrationPresent ? "speech":"",durationFrames:durationFrames)
        result.id=sceneID;result.simulation=simulation;result.character=character;result.emotion=emotion;result.color=color;result.fontName=fontName;result.classicArtworkRequired=artworkRequired
        result.cartoonPerformance=cartoonPerformance
        result.storyActions=storyActions;result.gameWorld=gameWorld;result.cartoonRig=cartoonRig;result.cartoonPresenter=cartoonPresenter;result.layers=layers;result.modelScene3D=modelScene3D
        if cartoonRig != nil || modelScene3D != nil {result.classicArtworkRequired=false}
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
    public var modelBankReference:PluginModelBankReference?
    public init(invocation:PluginInvocation,props:PluginVisualProps,sourceFrame:Int,fps:Int,canvasWidth:Int,canvasHeight:Int,rect:PluginRect,assets:[PluginRasterAsset],modelBankReference:PluginModelBankReference?=nil){self.invocation=invocation;self.props=props;self.sourceFrame=sourceFrame;self.fps=fps;self.canvasWidth=canvasWidth;self.canvasHeight=canvasHeight;self.rect=rect;self.assets=assets;self.modelBankReference=modelBankReference}
    public func contentDigest()throws->String {try Codec.digest(self)}
    public func dependencyFingerprints() throws -> [String:String] {
        if let model=props.modelScene3D {
            guard assets.isEmpty,let reference=modelBankReference else {throw VideoError.invalid("三维帧须仅引用完整模型银行")}
            let manifest=try PluginModelBankManifest(scene:model,durationFrames:props.durationFrames)
            try reference.validate(invocation:invocation,manifest:manifest);return manifest.dependencyFingerprints
        }
        guard modelBankReference==nil,assets.count<=32,Set(assets.map(\.assetID)).count==assets.count else {throw VideoError.invalid("图片帧依赖重复、超界或混入模型银行")}
        return Dictionary(uniqueKeysWithValues:assets.map{($0.assetID,$0.sha256)})
    }
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
    public init(pluginID:String,capabilityID:String,version:String,inputSchemaVersion:Int=1){self.pluginID=pluginID;self.capabilityID=capabilityID;self.version=version;methods=PluginMethod.allCases;self.inputSchemaVersion=inputSchemaVersion;outputSchemaVersion=1;inputContract="PluginFrameInput v\(inputSchemaVersion): visual-only props, already-mapped source frame, byte-bound image bank, frozen invocation and budget reference";outputContract="PluginTaskSnapshot v1: cancellable asynchronous frame task; verified transparent sRGB PNG Data, input digest and dependency fingerprints";inputSchema=PluginRPCSchemas.request(inputSchemaVersion:inputSchemaVersion,pluginID:pluginID);outputSchema=PluginRPCSchemas.response(inputSchemaVersion:inputSchemaVersion,pluginID:pluginID);filesystemAccess=false;networkAccess=false}
}
public struct PluginRPCError:Codable,Equatable,Sendable {
    public var code:String;public var message:String;public var retryable:Bool;public var nextAction:String
    public init(code:String,message:String,retryable:Bool=false,nextAction:String="核对当前协议、冻结输入与原任务；不要重建付费请求"){self.code=code;self.message=message;self.retryable=retryable;self.nextAction=nextAction}
}
public struct PluginRPCRequest:Codable,Sendable {
    public var protocolMajor:Int;public var requestID:String;public var method:PluginMethod;public var input:PluginFrameInput?;public var invocation:PluginInvocation?;public var taskID:String?
    public var modelBankOperation:PluginModelBankOperation?
    public init(requestID:String,method:PluginMethod,input:PluginFrameInput?=nil,invocation:PluginInvocation?=nil,taskID:String?=nil,protocolMajor:Int=1,modelBankOperation:PluginModelBankOperation?=nil){self.protocolMajor=protocolMajor;self.requestID=requestID;self.method=method;self.input=input;self.invocation=invocation;self.taskID=taskID;self.modelBankOperation=modelBankOperation}
}
public struct PluginRPCResponse:Codable,Sendable {
    public var protocolMajor=1;public var requestID:String;public var ok:Bool;public var state:String;public var descriptor:PluginDescription?;public var inputDigest:String?;public var task:PluginTaskSnapshot?;public var cost:PluginCost?;public var error:PluginRPCError?
    public var modelBankReceipt:PluginModelBankReceipt?
    public init(requestID:String,ok:Bool,state:String,descriptor:PluginDescription?=nil,inputDigest:String?=nil,task:PluginTaskSnapshot?=nil,cost:PluginCost?=nil,error:PluginRPCError?=nil,modelBankReceipt:PluginModelBankReceipt?=nil){self.requestID=requestID;self.ok=ok;self.state=state;self.descriptor=descriptor;self.inputDigest=inputDigest;self.task=task;self.cost=cost;self.error=error;self.modelBankReceipt=modelBankReceipt}
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
    /// Codable model decoding rejects unknown model/action fields. Check the
    /// enclosing model frame too, before Codable can discard Host-only sources
    /// or unsupported visual extensions. Legacy non-model requests are unchanged.
    public static func validateModelWire(_ data:Data)throws {
        guard !data.isEmpty,data.count<=maximumRequestBytes else {throw VideoError.invalid("插件RPC消息为空或超过既有字节上限")}
        guard let request=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let input=request["input"] as? [String:Any],let props=input["props"] as? [String:Any],
              props["modelScene3D"] != nil else {return}
        let requestKeys:Set<String>=["protocolMajor","requestID","method","input","invocation","taskID","modelBankOperation"]
        let inputKeys:Set<String>=["invocation","props","sourceFrame","fps","canvasWidth","canvasHeight","rect","assets","modelBankReference"]
        let propsKeys:Set<String>=["sceneID","kind","durationFrames","simulation","character","emotion","color","fontName","narrationPresent","characterProfile","artwork","artworkRequired","cartoonPerformance","storyActions","gameWorld","cartoonRig","layers","voiceBinding","cartoonPresenter","modelScene3D"]
        let legacyFields:Set<String>=["artwork","gameWorld","cartoonRig","storyActions","cartoonPerformance","cartoonPresenter","voiceBinding","layers"]
        guard props["modelScene3D"] is [String:Any],Set(request.keys).isSubset(of:requestKeys),Set(input.keys).isSubset(of:inputKeys),Set(props.keys).isSubset(of:propsKeys),Set(props.keys).isDisjoint(with:legacyFields) else {
            throw VideoError.invalid("三维插件帧含未知字段或Host专用来源/因果数据，未静默忽略扩展")
        }
    }
    public static func validate(_ invocation:PluginInvocation,now:Date=Date())throws {
        guard [invocation.workspaceID,invocation.projectID,invocation.revisionID,invocation.invocationID,invocation.budgetReference].allSatisfy({text($0)}),invocation.jobID.map({text($0)}) ?? true,hash(invocation.revisionDigest),invocation.currency.range(of:"^[A-Z]{3}$",options:.regularExpression) != nil,!invocation.budgetLimit.isNaN,invocation.budgetLimit>=0,invocation.deadlineUnixTime.isFinite,invocation.deadlineUnixTime>now.timeIntervalSince1970,invocation.deadlineUnixTime<=now.timeIntervalSince1970+maximumInvocationSeconds else{throw VideoError.permission("插件调用缺少有效冻结身份、预算引用或有界截止")}
    }
    public static func validate(_ request:PluginRPCRequest,pluginID:String,inputSchemaVersion:Int,now:Date=Date())throws {
        guard request.protocolMajor==1,text(request.requestID) else {throw VideoError.invalid("插件请求协议或标识无效")}
        if let operation=request.modelBankOperation {
            guard PluginInputCompatibility.supportsModelBank(pluginID:pluginID,inputSchema:inputSchemaVersion),request.method == .validate,request.input==nil,request.invocation==nil,request.taskID==nil else {throw VideoError.invalid("模型银行仅用于game9至14 validate且不能混普通帧或调用字段")}
            try operation.validate(now:now)
        }
    }
    public static func validate(_ input:PluginFrameInput,capabilityID:String,inputSchemaVersion:Int=8,now:Date=Date())throws {
        try validate(input.invocation,now:now)
        let p=input.props,r=input.rect
        guard !(p.layers ?? []).contains(where:{$0.imageFlipHorizontal != nil}) else {
            throw VideoError.invalid("插件RPC不接受Host专用图片翻转字段；图片像素由Host绘制")
        }
        guard text(p.sceneID),(1...54000).contains(p.durationFrames),(0...216000).contains(input.sourceFrame),(1...120).contains(input.fps),(1...4096).contains(input.canvasWidth),(1...4096).contains(input.canvasHeight),input.canvasWidth*input.canvasHeight<=maximumCanvasPixels,[r.x,r.y,r.width,r.height].allSatisfy(\.isFinite),r.width>0,r.height>0,r.width<=Double(input.canvasWidth)*4,r.height<=Double(input.canvasHeight)*4,abs(r.x)<=Double(input.canvasWidth)*4,abs(r.y)<=Double(input.canvasHeight)*4 else{throw VideoError.invalid("插件帧、画布或裁切范围无效")}
        guard (capabilityID=="game.simulate" && p.kind == .simulation) || (capabilityID=="cartoon.animate" && p.kind == .cartoon) else{throw VideoError.invalid("插件能力与视觉输入类型不符")}
        guard [p.character,p.emotion,p.fontName].allSatisfy({text($0,maximum:512)}),p.color.range(of:"^[a-fA-F0-9]{6}$",options:.regularExpression) != nil,p.simulation.events.count<=4096,p.simulation.unit.utf8.count<=512,p.simulation.events.allSatisfy({text($0.label,maximum:512)}) else{throw VideoError.invalid("插件视觉参数或事件数量超界")}
        if let profile=p.characterProfile {guard profile.actions.count<=64,profile.actions.allSatisfy({text($0,maximum:512)}),profile.color.range(of:"^[a-fA-F0-9]{6}$",options:.regularExpression) != nil else{throw VideoError.invalid("插件角色动作或颜色无效")}}
        _ = try SimulationReplay.frameState(simulation:p.simulation,frame:input.sourceFrame,fps:input.fps)
        if let model=p.modelScene3D {
            try PluginInputCompatibility.requireModelSupport(model,pluginID:capabilityID=="game.simulate" ? "video.game":"video.cartoon",inputSchema:inputSchemaVersion)
            guard model.version != 2 || p.simulation.knowledge==nil else {throw VideoError.invalid("三维v2只接受原生视觉动作，知识规则本体保留在Host")}
            guard capabilityID=="game.simulate",p.kind == .simulation,p.artwork==nil,!p.artworkRequired,p.gameWorld==nil,p.cartoonRig==nil,p.storyActions==nil,p.cartoonPerformance==nil,p.cartoonPresenter==nil,p.voiceBinding==nil,p.layers==nil,input.assets.isEmpty,input.sourceFrame<p.durationFrames else {throw VideoError.invalid("真实三维输入只用于game9至14，不能混旧图集、地图、表演或图片银行")}
            try model.validate(durationFrames:p.durationFrames);_=try input.dependencyFingerprints();return
        }
        guard input.modelBankReference==nil else {throw VideoError.invalid("非三维帧不能携带模型银行引用")}
        guard input.assets.count<=32,Set(input.assets.map(\.assetID)).count==input.assets.count else{throw VideoError.invalid("插件图片数量或标识重复")}
        var bytes=0,pixels=0
        for asset in input.assets {
            guard text(asset.assetID),!asset.data.isEmpty,asset.data.count<=maximumAssetBytes,hash(asset.sha256),Codec.hash(asset.data)==asset.sha256,(1...8192).contains(asset.width),(1...8192).contains(asset.height),asset.width*asset.height<=maximumImagePixels else{throw VideoError.invalid("插件图片字节、摘要或尺寸无效")}
            bytes+=asset.data.count;pixels+=asset.width*asset.height
            guard bytes<=maximumTotalAssetBytes,pixels<=maximumTotalImagePixels else{throw VideoError.invalid("插件图片总量超出有界预算")}
        }
        var subjects=Set((p.layers ?? []).map(\.id))
        guard (p.layers ?? []).count<=32,subjects.count==(p.layers ?? []).count else {throw VideoError.invalid("故事舞台元素标识重复或数量超界")}
        if let rig=p.cartoonRig {
            guard p.kind == .cartoon,p.artwork==nil,!p.artworkRequired,input.assets.isEmpty,p.gameWorld==nil,p.cartoonPerformance==nil,p.cartoonPresenter==nil else {throw VideoError.invalid("原创代码卡通rig不能冒图集或游戏输入")}
            try rig.validate(durationFrames:p.durationFrames,voiceBinding:p.voiceBinding)
            guard subjects.isDisjoint(with:Set(rig.actors.map(\.id))) else {throw VideoError.invalid("角色与舞台对象标识不能冲突")}
            subjects.formUnion(rig.actors.map(\.id))
            try StoryActionRules.validate(p.storyActions ?? [],durationFrames:p.durationFrames,subjectIDs:subjects)
            return
        }
        guard p.voiceBinding==nil || p.cartoonPresenter != nil else {throw VideoError.invalid("只有已绑定原音的卡通表演可传口型身份")}
        guard p.artworkRequired,let artwork=p.artwork else{throw VideoError.review("高级插件只接受实际图集输入，不启用旧几何默认")}
        do {
            let roles=Set(artwork.sprites.map(\.role)),required = p.gameWorld.map { Set($0.tiles+$0.entities.map(\.role)+$0.updates.compactMap(\.role)) } ?? p.cartoonPresenter?.roles ?? ClassicArtworkRules.requiredRoles(knowledge: p.kind == .simulation && p.simulation.knowledge != nil, cartoon: p.kind == .cartoon)
            guard !artwork.sprites.isEmpty,artwork.sprites.count<=(p.gameWorld == nil ? 32:128),roles.count==artwork.sprites.count,required.isSubset(of:roles),Set(artwork.sprites.map(\.assetID))==Set(input.assets.map(\.assetID)) else{throw VideoError.invalid("插件图块与实际图片集合不符")}
            for s in artwork.sprites {guard text(s.role,maximum:512),[s.x,s.y,s.width,s.height].allSatisfy(\.isFinite),s.x>=0,s.y>=0,s.width>0,s.height>0,s.x+s.width<=1.000001,s.y+s.height<=1.000001 else{throw VideoError.invalid("插件图块坐标无效")}}
            if let performance=p.cartoonPerformance {
                guard p.kind == .cartoon else { throw VideoError.invalid("多角色表演仅用于实际图集的卡通输入") }
                try performance.validate(durationFrames:p.durationFrames,sprites:artwork.sprites,
                    imageHashes:Dictionary(uniqueKeysWithValues:input.assets.map{($0.assetID,$0.sha256)}))
            }
            let visual=ClassicArtwork(gameplay:artwork.gameplay,sprites:artwork.sprites,sources:[],derivation:artwork.derivation,knowledgeParticipants:artwork.knowledgeParticipants)
            try KnowledgeParticipantAppearanceRules.validate(artwork:visual,knowledge:p.kind == .simulation ? p.simulation.knowledge:nil,
                imageHashes:Dictionary(uniqueKeysWithValues:input.assets.map{($0.assetID,$0.sha256)}))
            if let world=p.gameWorld {
                guard p.kind == .simulation else {throw VideoError.invalid("动态世界只用于实际游戏模块")}
                try world.validate(durationFrames:p.durationFrames,availableRoles:roles)
                guard subjects.isDisjoint(with:Set(world.entities.map(\.id))) else {throw VideoError.invalid("游戏实体与舞台对象标识不能冲突")}
                subjects.formUnion(world.entities.map(\.id))
            }
            if let presenter=p.cartoonPresenter {
                guard p.kind == .cartoon,p.gameWorld==nil,p.cartoonRig==nil,p.cartoonPerformance==nil,!subjects.contains(presenter.id) else {throw VideoError.invalid("图片解说员不能混入游戏、旧rig或其它同名舞台对象")}
                try presenter.validate(durationFrames:p.durationFrames,sprites:artwork.sprites,imageHashes:Dictionary(uniqueKeysWithValues:input.assets.map{($0.assetID,$0.sha256)}),voiceBinding:p.voiceBinding)
                try presenter.validateActions(p.storyActions ?? [])
                subjects.insert(presenter.id)
            }
            if let performance=p.cartoonPerformance {subjects.formUnion(performance.actors.map(\.id))}
            try StoryActionRules.validate(p.storyActions ?? [],durationFrames:p.durationFrames,subjectIDs:subjects)
        }
    }
    public static func validate(_ frame:PluginPNGFrame,input:PluginFrameInput)throws {
        let dependencies=try input.dependencyFingerprints()
        guard !frame.data.isEmpty,frame.data.count<=maximumPNGBytes,frame.sha256==Codec.hash(frame.data),frame.width==input.canvasWidth,frame.height==input.canvasHeight,frame.sourceFrame==input.sourceFrame,frame.inputDigest == (try input.contentDigest()),frame.dependencyFingerprints==dependencies else{throw VideoError.permission("插件图层不属于冻结输入、帧或已核资源，拒绝采用")}
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
    /// Shared only by the current Host IR and explicit game10. Game9 continues
    /// to use ModelScene3DSchema.records byte for byte, without these definitions.
    public static func modelStoryDefinitions()->[String:AgentValue] {
        var result=ModelStoryAction3DSchema.records.mapValues(record)
        for (name,values) in ModelStoryAction3DSchema.enums {
            result[name] = .object(["type":.string("string"),"enum":.array(values.map(AgentValue.string))])
        }
        var action=result["ModelStoryAction3D"]!.object!,properties=action["properties"]!.object!
        properties["startFrame"] = .object(["type":.string("integer"),"minimum":.number(0),"maximum":.number(53999)])
        properties["endFrame"] = .object(["type":.string("integer"),"minimum":.number(1),"maximum":.number(54000)])
        properties["requires"] = .object(["type":.string("array"),"items":shape("s"),"maxItems":.number(32),"uniqueItems":.boolean(true)])
        properties["jointNames"] = .object(["type":.string("array"),"items":shape("s"),"minItems":.number(1),"maxItems":.number(64),"uniqueItems":.boolean(true)])
        properties["text"] = .object(["type":.string("string"),"minLength":.number(1),"maxLength":.number(48)])
        action["properties"] = .object(properties)
        func conditional(_ kind:String,required:[String],forbidden:[String])->AgentValue {
            var then:[String:AgentValue]=[:]
            if !required.isEmpty {then["required"] = .array(required.map(AgentValue.string))}
            if !forbidden.isEmpty {then["not"] = .object(["anyOf":.array(forbidden.map{.object(["required":.array([.string($0)])])})])}
            return .object(["if":.object(["properties":.object(["kind":.object(["const":.string(kind)])])]),"then":.object(then)])
        }
        action["allOf"] = .array([
            conditional("pose",required:["jointNames"],forbidden:["anchor","text"]),
            conditional("speak",required:["anchor","text"],forbidden:["jointNames"])
        ] + ["move","show","hide"].map{conditional($0,required:[],forbidden:["jointNames","anchor","text"])})
        result["ModelStoryAction3D"] = .object(action)
        var model=result["ModelScene3D"]!.object!,modelProperties=model["properties"]!.object!
        modelProperties["version"] = .object(["type":.string("integer"),"enum":.array([.number(1),.number(2)])])
        modelProperties["actions"] = .object(["type":.string("array"),"items":shape("ModelStoryAction3D"),"minItems":.number(1),"maxItems":.number(256)])
        model["properties"] = .object(modelProperties)
        model["if"] = .object(["properties":.object(["version":.object(["const":.number(2)])])])
        model["then"] = .object(["required":.array([.string("actions")])])
        model["else"] = .object(["not":.object(["required":.array([.string("actions")])])])
        result["ModelScene3D"] = .object(model)
        return result
    }
    /// Host/game14 only. Older discovery records remain byte-for-byte unchanged.
    public static func modelDialogueObstacleDefinitions()->[String:AgentValue] {
        var model=modelStoryDefinitions()["ModelScene3D"]!.object!,properties=model["properties"]!.object!
        properties["dialogueObstacleInstanceIDs"] = .object(["type":.string("array"),"items":.object(["type":.string("string"),"minLength":.number(1),"maxLength":.number(160)]),"minItems":.number(1),"maxItems":.number(128),"uniqueItems":.boolean(true)])
        model["properties"] = .object(properties)
        return ["ModelScene3D":.object(model)]
    }
    /// Explicit Host/game11 visibility selections. Legacy game9/game10 schemas
    /// intentionally do not know these fields and cannot silently discard them.
    public static func modelNodeVariantDefinitions()->[String:AgentValue] {
        var result=ModelNodeVariantSchema.records.mapValues(record)
        func set(_ name:String,_ field:String,_ shape:AgentValue) {
            var value=result[name]!.object!,properties=value["properties"]!.object!
            properties[field]=shape;value["properties"] = .object(properties);result[name] = .object(value)
        }
        let identifier=AgentValue.object(["type":.string("string"),"minLength":.number(1),"maxLength":.number(160)])
        set("ModelNodeVariantGroup","id",identifier);set("ModelNodeVariantGroup","defaultNodeID",identifier)
        set("ModelNodeVariantKeyframe","nodeID",identifier)
        set("ModelNodeVariantKeyframe","frame",.object(["type":.string("integer"),"minimum":.number(1),"maximum":.number(53999)]))
        set("ModelNodeVariantGroup","nodeIDs",.object(["type":.string("array"),"minItems":.number(2),"maxItems":.number(128),"uniqueItems":.boolean(true),"items":identifier]))
        set("ModelNodeVariantGroup","keyframes",.object(["type":.string("array"),"minItems":.number(1),"maxItems":.number(4096),"items":shape("ModelNodeVariantKeyframe")]))
        set("ModelInstance3D","nodeVariants",.object(["type":.string("array"),"minItems":.number(1),"maxItems":.number(32),"items":shape("ModelNodeVariantGroup")]))
        return result
    }
    public static func modelAlphaCutoutDefinitions()->[String:AgentValue] {
        var result=ModelAlphaCutoutSchema.records.mapValues(record)
        var value=result["ModelMaterialInterpretation"]!.object!,properties=value["properties"]!.object!
        properties["alphaCutoutMaterialIDs"] = .object(["type":.string("array"),"minItems":.number(1),"maxItems":.number(128),"uniqueItems":.boolean(true),"items":.object(["type":.string("string"),"minLength":.number(1),"maxLength":.number(160)]),"description":.string("Explicit original material IDs: discard original alphaOne transparent alpha below fixed 0.5; may overlap opaqueDiffuseMaterialIDs; no source bytes are changed.")])
        value["properties"] = .object(properties);result["ModelMaterialInterpretation"] = .object(value)
        return result
    }
    public static func modelCameraMotionDefinitions()->[String:AgentValue] {
        var result=ModelCameraMotionSchema.records.mapValues(record)
        var camera=result["ModelCamera3D"]!.object!,properties=camera["properties"]!.object!
        properties["keyframes"] = .object(["type":.string("array"),"minItems":.number(1),"maxItems":.number(54000),"items":shape("ModelCameraKeyframe3D"),"description":.string("Strictly increasing source-frame poses. Linear position/target/FOV interpolation; hold first and last poses outside their keys. Parent up/near/far stay fixed. No wall-clock or implicit target following.")])
        camera["properties"] = .object(properties);result["ModelCamera3D"] = .object(camera)
        var key=result["ModelCameraKeyframe3D"]!.object!,keyProperties=key["properties"]!.object!
        keyProperties["frame"] = .object(["type":.string("integer"),"minimum":.number(0),"maximum":.number(53999)])
        keyProperties["verticalFieldOfViewDegrees"] = .object(["type":.string("number"),"minimum":.number(1),"maximum":.number(175)])
        key["properties"] = .object(keyProperties);result["ModelCameraKeyframe3D"] = .object(key)
        return result
    }
    public static func definitions(inputSchemaVersion: Int = 2,pluginID:String?=nil)->[String:AgentValue] {
        let story=inputSchemaVersion>=7 || (pluginID=="video.cartoon" && inputSchemaVersion>=5)
        let model=pluginID=="video.game" && [9,10,11,12,13,14].contains(inputSchemaVersion)
        let declarations:[String:String]=[
            "PluginInvocation":"workspaceID:s projectID:s revisionID:s revisionDigest:s jobID?:s invocationID:s budgetReference:s currency:s budgetLimit:n deadlineUnixTime:n",
            "PluginRect":"x:n y:n width:n height:n",
            "PluginFrameInput":"invocation:PluginInvocation props:PluginVisualProps sourceFrame:i fps:i canvasWidth:i canvasHeight:i rect:PluginRect assets:[PluginRasterAsset]" + (model ? " modelBankReference?:PluginModelBankReference":""),
            "PluginVisualProps":"sceneID:s kind:SceneKind durationFrames:i simulation:Simulation character:s emotion:s color:s fontName:s narrationPresent:b characterProfile?:PluginCharacterProps artwork?:PluginArtworkProps artworkRequired:b" + (inputSchemaVersion >= 4 ? " cartoonPerformance?:CartoonPerformance" : "") + (story ? " storyActions?:[StoryAction] gameWorld?:GameWorld cartoonRig?:CartoonRig layers?:[SceneLayer] voiceBinding?:CartoonSpeechBinding":"") + (pluginID=="video.cartoon" && inputSchemaVersion>=7 ? " cartoonPresenter?:CartoonPresenter":"") + (model ? " modelScene3D?:ModelScene3D":""),
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
        if model {
            for (key,declaration) in ModelScene3DSchema.records {result[key]=record(declaration)}
            if [10,11,12,13,14].contains(inputSchemaVersion) {result.merge(modelStoryDefinitions(),uniquingKeysWith:{$1})}
            if [11,12,13,14].contains(inputSchemaVersion) {result.merge(modelNodeVariantDefinitions(),uniquingKeysWith:{$1})}
            if [12,13,14].contains(inputSchemaVersion) {result.merge(modelAlphaCutoutDefinitions(),uniquingKeysWith:{$1})}
            if [13,14].contains(inputSchemaVersion) {result.merge(modelCameraMotionDefinitions(),uniquingKeysWith:{$1})}
            if inputSchemaVersion==14 {result.merge(modelDialogueObstacleDefinitions(),uniquingKeysWith:{$1})}
            result["ModelLightKind"] = .object(["type":.string("string"),"enum":.array(["ambient","directional","omni"].map(AgentValue.string))])
            result["ModelVertexColorUsage"] = .object(["type":.string("string"),"enum":.array(ModelVertexColorUsage.allCases.map{.string($0.rawValue)})])
            result["ModelNormalTextureEncoding"] = .object(["type":.string("string"),"enum":.array(ModelNormalTextureEncoding.allCases.map{.string($0.rawValue)})])
            result["PluginModelBankReference"]=record("bankID:s manifestDigest:s invocationDigest:s")
            result["PluginModelBankManifest"]=record("assets:[ModelAssetReference]")
            result["PluginModelBankReceipt"]=record("reference:PluginModelBankReference state:PluginModelBankState receivedBytes:i totalBytes:i")
            result["PluginModelBankOperationKind"] = .object(["type":.string("string"),"enum":.array(PluginModelBankOperationKind.allCases.map{.string($0.rawValue)})])
            result["PluginModelBankState"] = .object(["type":.string("string"),"enum":.array(["receiving","ready","released"].map(AgentValue.string))])
            var variants:[AgentValue]=[]
            for kind in PluginModelBankOperationKind.allCases {
                let extra=kind == .begin ? " manifest:PluginModelBankManifest":kind == .append ? " assetID:s offset:i data:data sha256:s":""
                var variant=record("kind:PluginModelBankOperationKind invocation:PluginInvocation bankID:s"+extra).object!,properties=variant["properties"]!.object!
                properties["kind"] = .object(["const":.string(kind.rawValue)])
                if kind == .append {
                    properties["offset"] = .object(["type":.string("integer"),"minimum":.number(0),"maximum":.number(Decimal(PluginModelBankRules.maximumTotalBytes))])
                    properties["data"] = .object(["type":.string("string"),"contentEncoding":.string("base64"),"minLength":.number(4),"maxLength":.number(Decimal((PluginModelBankRules.maximumChunkBytes+2)/3*4))])
                }
                variant["properties"] = .object(properties);variants.append(.object(variant))
            }
            result["PluginModelBankOperation"] = .object(["oneOf":.array(variants)])
            var manifest=result["PluginModelBankManifest"]!.object!,properties=manifest["properties"]!.object!,assets=properties["assets"]!.object!
            assets["minItems"] = .number(1);assets["maxItems"] = .number(Decimal(PluginModelBankRules.maximumAssets));properties["assets"] = .object(assets);manifest["properties"] = .object(properties);result["PluginModelBankManifest"] = .object(manifest)
            var frame=result["PluginFrameInput"]!.object!
            let mixed=AgentValue.object(["anyOf":.array(["artwork","gameWorld","cartoonRig","storyActions","cartoonPerformance","cartoonPresenter","voiceBinding","layers"].map { .object(["required":.array([.string($0)])]) })])
            var modelPropsRecord:[String:AgentValue]=["required":.array([.string("modelScene3D")]),"properties":.object(["kind":.object(["const":.string(SceneKind.simulation.rawValue)]),"artworkRequired":.object(["const":.boolean(false)])]),"not":mixed]
            if [10,11,12,13,14].contains(inputSchemaVersion) {
                modelPropsRecord["if"] = .object(["properties":.object(["modelScene3D":.object(["properties":.object(["version":.object(["const":.number(2)])])])])])
                modelPropsRecord["then"] = .object(["properties":.object(["simulation":.object(["not":.object(["required":.array([.string("knowledge")])])])])])
            }
            let modelProps=AgentValue.object(modelPropsRecord)
            frame["oneOf"] = .array([
                .object(["required":.array([.string("modelBankReference")]),"properties":.object(["props":modelProps,"assets":.object(["maxItems":.number(0)])])]),
                .object(["not":.object(["required":.array([.string("modelBankReference")])]),"properties":.object(["props":.object(["not":.object(["required":.array([.string("modelScene3D")])])])])])
            ])
            result["PluginFrameInput"] = .object(frame)
        }
        if story {
            let renderPlanes=pluginID == "video.game" && inputSchemaVersion>=8
            for (key,declaration) in StoryActionSchema.records {
                // Keep prior endpoint descriptions exact: only game8 may
                // receive the new optional plane, even though Host IR knows it.
                var current=renderPlanes ? declaration:declaration.replacingOccurrences(of:" renderPlane?:GameWorldRenderPlane",with:"")
                if inputSchemaVersion<8 {current=current.replacingOccurrences(of:" waypoints?:[StoryPoint]",with:"")}
                result[key]=record(current)
            }
            for (key,values) in StoryActionSchema.enums where renderPlanes || key != "GameWorldRenderPlane" {result[key] = .object(["type":.string("string"),"enum":.array(values.map(AgentValue.string))])}
            result["SceneLayer"]=record("id:s kind:LayerKind text:s assetID?:s x:n y:n width:n height:n color:s opacity:n startFrame:i endFrame:i locked:b keyframes:[Keyframe] dataPresentation?:DataPresentation entrance?:LayerEntrance")
            result["Keyframe"]=record("id:s frame:i x:n y:n scale:n")
            // The layer pixels are Host-rendered; only IDs and visual metadata cross.
            // Full source-layer schemas are reused from the normal agent contract.
            let host=AgentSchemas.definitions()
            for name in ["SceneLayer","Keyframe","LayerKind","DataPresentation","DataChart","DataSeries","DataValueKeyframe","CodePresentation","CodeHighlight","LayerEntrance","LayerEntranceKind"] {if let value=host[name] {result[name]=value}}
            if model {
                // game9 retains the legacy 2D input alternative. Its complete
                // layer graph must resolve too; earlier published schemas keep
                // their exact bytes rather than acquiring new definitions.
                for name in ["LayerImageSequence","LayerImageSequenceFrame","MediaFraming"] {if let value=host[name] {result[name]=value}}
            }
            // Preserve every published RPC schema: horizontal image reflection
            // belongs to Host painting, not to the plugin's visual metadata.
            if var layer=result["SceneLayer"]?.object,var properties=layer["properties"]?.object {
                properties.removeValue(forKey:"imageFlipHorizontal");layer["properties"] = .object(properties);result["SceneLayer"] = .object(layer)
            }
            if inputSchemaVersion>=8 {
                for name in ["LayerTexturedPath","LayerTextureStroke"] {if let value=host[name] {result[name]=value}}
            } else if var layer=result["SceneLayer"]?.object,var properties=layer["properties"]?.object {
                properties.removeValue(forKey:"texturedPath");layer["properties"] = .object(properties);result["SceneLayer"] = .object(layer)
            }
            if pluginID=="video.cartoon" && inputSchemaVersion>=6 {
                var rig=result["CartoonRig"]!.object!,properties=rig["properties"]!.object!
                properties["version"] = .object(["type":.string("integer"),"enum":.array([.number(1),.number(2)])])
                var actors=properties["actors"]!.object!;actors["minItems"] = .number(1);actors["maxItems"] = .number(8);properties["actors"] = .object(actors)
                rig["properties"] = .object(properties)
                rig["if"] = .object(["properties":.object(["version":.object(["const":.number(1)])])])
                rig["then"] = .object(["properties":.object(["actors":.object(["maxItems":.number(4)])])])
                result["CartoonRig"] = .object(rig)
            }
        }
        if pluginID=="video.cartoon" && inputSchemaVersion>=7 {for (key,declaration) in CartoonPresenterSchema.records {result[key]=record(inputSchemaVersion>=8 ? declaration:declaration.replacingOccurrences(of:" anchor?:s",with:""))}}
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
    public static func request(inputSchemaVersion: Int = 2,pluginID:String?=nil)->AgentValue {
        let model=pluginID=="video.game" && [9,10,11,12,13,14].contains(inputSchemaVersion)
        var schema=record("protocolMajor:i requestID:s method:PluginMethod input?:PluginFrameInput invocation?:PluginInvocation taskID?:s"+(model ? " modelBankOperation?:PluginModelBankOperation":"")).object!
        if model {
            let forbidden=AgentValue.object(["anyOf":.array(["input","invocation","taskID"].map { .object(["required":.array([.string($0)])]) })])
            schema["oneOf"] = .array([
                .object(["required":.array([.string("modelBankOperation")]),"properties":.object(["method":.object(["const":.string("validate")])]),"not":forbidden]),
                .object(["not":.object(["required":.array([.string("modelBankOperation")])])])
            ])
        }
        schema["$defs"] = .object(definitions(inputSchemaVersion: inputSchemaVersion,pluginID:pluginID));schema["$schema"] = .string("https://json-schema.org/draft/2020-12/schema")
        let modelDescription=inputSchemaVersion==14 ? " game14 adds an explicit bounded dialogueObstacleInstanceIDs list covering every speaker; omitted lists preserve legacy action-based avoidance. Rendering keeps every model visible according to its original source-frame presentation and preserves body, tail and subtitle safety checks. All prior model features and the bounded model bank remain supported.":inputSchemaVersion==13 ? " game13 adds explicit source-frame camera keyframes with deterministic linear sampling and endpoint holds. Prior model v1/v2, node selections, alpha cutouts and the bounded model bank remain supported without filesystem/network access.":inputSchemaVersion==12 ? " game12 adds explicit original-material alphaOne transparent cutout at fixed 0.5; model v1/v2, node selections and the bounded model bank remain supported without filesystem/network access.":inputSchemaVersion==11 ? " game11 adds explicit mutually exclusive original-node selections and source-frame step changes; model v1/v2 and the bounded model bank remain supported without filesystem/network access.":inputSchemaVersion==10 ? " game10 validate alternatively accepts a mutually exclusive bounded in-memory modelBankOperation; model v2 actions are visual-only, while complete causal sources remain in the Host. It never grants filesystem/network access.":" game9 validate alternatively accepts a mutually exclusive bounded in-memory modelBankOperation; it never grants filesystem/network access."
        schema["description"] = .string("protocolMajor=1. validate/estimate/execute require input. progress/cancel require the complete matching invocation; progress also requires taskID. cancel without taskID closes the whole invocation and exits the service."+(model ? modelDescription:""))
        return .object(schema)
    }
    public static func response(inputSchemaVersion: Int = 2,pluginID:String?=nil)->AgentValue {
        var schema=record("protocolMajor:i requestID:s ok:b state:s descriptor?:PluginDescription inputDigest?:s task?:PluginTaskSnapshot cost?:PluginCost error?:PluginRPCError"+(pluginID=="video.game" && [9,10,11,12,13,14].contains(inputSchemaVersion) ? " modelBankReceipt?:PluginModelBankReceipt":"")).object!
        schema["$defs"] = .object(definitions(inputSchemaVersion: inputSchemaVersion,pluginID:pluginID));schema["$schema"] = .string("https://json-schema.org/draft/2020-12/schema");return .object(schema)
    }
}
