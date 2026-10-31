import Foundation

/// Host-only provenance. Render plugins receive the existing visual actions, never models or traces.
public struct StoryCausalActor: Codable, Equatable, Sendable {
    public var actorID:String; public var subjectID:String
    public init(actorID:String,subjectID:String) {self.actorID=actorID;self.subjectID=subjectID}
    public init(from decoder:Decoder)throws {try StoryCausalDecoding.keys(decoder,required:["actorID","subjectID"]);let c=try decoder.container(keyedBy:CodingKeys.self);actorID=try c.decode(String.self,forKey:.actorID);subjectID=try c.decode(String.self,forKey:.subjectID)}
}
public struct StoryCausalIntervention: Codable, Equatable, Sendable {
    public var actorID:String; public var plan:KnowledgeRuleActorPlan
    public init(actorID:String,plan:KnowledgeRuleActorPlan) {self.actorID=actorID;self.plan=plan}
    public init(from decoder:Decoder)throws {try StoryCausalDecoding.keys(decoder,required:["actorID","plan"]);let c=try decoder.container(keyedBy:CodingKeys.self);actorID=try c.decode(String.self,forKey:.actorID);plan=try c.decode(KnowledgeRuleActorPlan.self,forKey:.plan)}
}
/// A v2 source may change one existing action's actual cost, never an arbitrary model field.
public struct StoryCausalActionCost: Codable, Equatable, Sendable {
    public var actionID:String; public var newCost:Int
    public init(actionID:String,newCost:Int) {self.actionID=actionID;self.newCost=newCost}
    public init(from decoder:Decoder)throws {
        try StoryCausalDecoding.keys(decoder,required:["actionID","newCost"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        actionID=try c.decode(String.self,forKey:.actionID);newCost=try c.decode(Int.self,forKey:.newCost)
        guard actionID.range(of:"^[A-Za-z0-9_-]{1,40}$",options:.regularExpression) != nil,(0...100_000).contains(newCost) else {throw VideoError.invalid("成本反事实须声明现有动作标识及0—100000的整数成本")}
    }
}
/// A v3 source replaces one existing finite rule, retaining every other input.
public struct StoryCausalRuleChange: Codable, Equatable, Sendable {
    public var ruleID:String; public var rule:KnowledgeRule
    public init(ruleID:String,rule:KnowledgeRule) {self.ruleID=ruleID;self.rule=rule}
    public init(from decoder:Decoder)throws {
        try StoryCausalDecoding.keys(decoder,required:["ruleID","rule"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        ruleID=try c.decode(String.self,forKey:.ruleID);rule=try c.decode(KnowledgeRule.self,forKey:.rule)
        guard ruleID.range(of:"^[A-Za-z0-9_-]{1,40}$",options:.regularExpression) != nil,rule.id==ruleID else {throw VideoError.invalid("规则反事实须明确现有规则标识，并保留替换规则的同一id")}
    }
}
public struct StoryCausalSource: Codable, Equatable, Sendable {
    public var id:String; public var parentID:String?; public var intervention:StoryCausalIntervention?
    public var actionCost:StoryCausalActionCost?
    public var ruleChange:StoryCausalRuleChange?
    public var model:KnowledgeSimulation; public var seed:UInt64; public var trace:KnowledgeTrace
    public var startFrame:Int; public var endFrame:Int
    public init(id:String,parentID:String?=nil,intervention:StoryCausalIntervention?=nil,actionCost:StoryCausalActionCost?=nil,ruleChange:StoryCausalRuleChange?=nil,model:KnowledgeSimulation,seed:UInt64,trace:KnowledgeTrace,startFrame:Int,endFrame:Int) {
        self.id=id;self.parentID=parentID;self.intervention=intervention;self.actionCost=actionCost;self.ruleChange=ruleChange;self.model=model;self.seed=seed;self.trace=trace;self.startFrame=startFrame;self.endFrame=endFrame
    }
    public init(from decoder:Decoder)throws {
        try StoryCausalDecoding.keys(decoder,required:["id","model","seed","trace","startFrame","endFrame"],optional:["parentID","intervention","actionCost","ruleChange"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id);parentID=try c.decodeIfPresent(String.self,forKey:.parentID);intervention=try c.decodeIfPresent(StoryCausalIntervention.self,forKey:.intervention)
        if c.contains(.actionCost) {
            guard !c.contains(.intervention),!(try c.decodeNil(forKey:.actionCost)) else {throw VideoError.invalid("成本声明不可为null，也不可同时声明参与者计划干预")}
            actionCost=try c.decode(StoryCausalActionCost.self,forKey:.actionCost)
        } else {actionCost=nil}
        if c.contains(.ruleChange) {
            guard !c.contains(.intervention),!c.contains(.actionCost),!(try c.decodeNil(forKey:.ruleChange)) else {throw VideoError.invalid("规则声明不可为null，也不可同时声明参与者计划或动作成本干预")}
            ruleChange=try c.decode(StoryCausalRuleChange.self,forKey:.ruleChange)
        } else {ruleChange=nil}
        // Existing knowledge DTOs keep their legacy Codable behavior. This new contract
        // additionally refuses fields that would otherwise disappear before verification.
        try StoryCausalDecoding.knowledge(AgentValue(from:c.superDecoder(forKey:.model)),trace:false)
        try StoryCausalDecoding.knowledge(AgentValue(from:c.superDecoder(forKey:.trace)),trace:true)
        model=try c.decode(KnowledgeSimulation.self,forKey:.model);seed=try c.decode(UInt64.self,forKey:.seed);trace=try c.decode(KnowledgeTrace.self,forKey:.trace)
        startFrame=try c.decode(Int.self,forKey:.startFrame);endFrame=try c.decode(Int.self,forKey:.endFrame)
    }
}
public enum StoryCausalBindingKind:String,Codable,CaseIterable,Sendable {case performedAction,deposit,transfer,stateChange,outcome,delivery,payment}
public struct StoryCausalBinding: Codable, Equatable, Sendable {
    public var actionID:String;public var sourceID:String;public var eventID:String;public var kind:StoryCausalBindingKind;public var requires:[String]
    public var actorID:String?;public var actionKey:String?;public var ruleID:String?;public var fromActorID:String?;public var toActorID:String?;public var amount:Int?
    public var fromStateID:String?;public var toStateID:String?;public var outcome:Bool?
    public init(actionID:String,sourceID:String,eventID:String,kind:StoryCausalBindingKind,requires:[String]=[],actorID:String?=nil,actionKey:String?=nil,ruleID:String?=nil,fromActorID:String?=nil,toActorID:String?=nil,amount:Int?=nil,fromStateID:String?=nil,toStateID:String?=nil,outcome:Bool?=nil) {
        self.actionID=actionID;self.sourceID=sourceID;self.eventID=eventID;self.kind=kind;self.requires=requires;self.actorID=actorID;self.actionKey=actionKey;self.ruleID=ruleID;self.fromActorID=fromActorID;self.toActorID=toActorID;self.amount=amount;self.fromStateID=fromStateID;self.toStateID=toStateID;self.outcome=outcome
    }
    public init(from decoder:Decoder)throws {
        try StoryCausalDecoding.keys(decoder,required:["actionID","sourceID","eventID","kind","requires"],optional:["actorID","actionKey","ruleID","fromActorID","toActorID","amount","fromStateID","toStateID","outcome"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        actionID=try c.decode(String.self,forKey:.actionID);sourceID=try c.decode(String.self,forKey:.sourceID);eventID=try c.decode(String.self,forKey:.eventID);kind=try c.decode(StoryCausalBindingKind.self,forKey:.kind);requires=try c.decode([String].self,forKey:.requires)
        actorID=try c.decodeIfPresent(String.self,forKey:.actorID);actionKey=try c.decodeIfPresent(String.self,forKey:.actionKey);ruleID=try c.decodeIfPresent(String.self,forKey:.ruleID);fromActorID=try c.decodeIfPresent(String.self,forKey:.fromActorID);toActorID=try c.decodeIfPresent(String.self,forKey:.toActorID);amount=try c.decodeIfPresent(Int.self,forKey:.amount);fromStateID=try c.decodeIfPresent(String.self,forKey:.fromStateID);toStateID=try c.decodeIfPresent(String.self,forKey:.toStateID);outcome=try c.decodeIfPresent(Bool.self,forKey:.outcome)
    }
}
public struct StoryCausality: Codable, Equatable, Sendable {
    public var version=1;public var poolSubjectID:String;public var actors:[StoryCausalActor];public var sources:[StoryCausalSource];public var bindings:[StoryCausalBinding]
    public init(version:Int=1,poolSubjectID:String,actors:[StoryCausalActor],sources:[StoryCausalSource],bindings:[StoryCausalBinding]) {self.version=version;self.poolSubjectID=poolSubjectID;self.actors=actors;self.sources=sources;self.bindings=bindings}
    public init(from decoder:Decoder)throws {
        try StoryCausalDecoding.keys(decoder,required:["version","poolSubjectID","actors","sources","bindings"]);let c=try decoder.container(keyedBy:CodingKeys.self)
        version=try c.decode(Int.self,forKey:.version);poolSubjectID=try c.decode(String.self,forKey:.poolSubjectID);actors=try c.decode([StoryCausalActor].self,forKey:.actors);sources=try c.decode([StoryCausalSource].self,forKey:.sources);bindings=try c.decode([StoryCausalBinding].self,forKey:.bindings)
        guard (version==1 && sources.allSatisfy({$0.actionCost==nil && $0.ruleChange==nil})) ||
              (version==2 && sources.contains(where:{$0.actionCost != nil}) && sources.allSatisfy({$0.ruleChange==nil})) ||
              (version==3 && sources.contains(where:{$0.ruleChange != nil})) else {throw VideoError.invalid("故事因果v1不接受成本或规则声明；v2须至少一个成本反事实且无规则声明；v3须至少一个规则反事实")}
    }
}

public enum StoryCausalRules {
    public static func validate(scene:Scene)throws {
        guard let value=scene.storyCausality else {return}
        let actions=scene.storyActions ?? []
        var subjects=Set((scene.layers ?? []).map(\.id));subjects.formUnion(scene.gameWorld?.entities.map(\.id) ?? []);subjects.formUnion(scene.cartoonRig?.actors.map(\.id) ?? []);if let presenter=scene.cartoonPresenter {subjects.insert(presenter.id)}
        let hasActionCost=value.sources.contains{$0.actionCost != nil}
        let hasRuleChange=value.sources.contains{$0.ruleChange != nil}
        guard ((value.version==1 && !hasActionCost && !hasRuleChange) || (value.version==2 && hasActionCost && !hasRuleChange) || (value.version==3 && hasRuleChange)),(1...3).contains(value.sources.count),(1...64).contains(value.actors.count),(1...256).contains(value.bindings.count),subjects.contains(value.poolSubjectID),
              Set(value.sources.map(\.id)).count==value.sources.count,Set(value.actors.map(\.subjectID)).count==value.actors.count,
              Set(value.bindings.map(\.actionID)).count==value.bindings.count,try Codec.data(value).count<=4*1024*1024 else {throw VideoError.invalid("故事因果来源数量、舞台对象、重复标识或数据大小无效")}
        let participants=Set(value.sources[0].model.participants.map(\.id))
        guard value.actors.allSatisfy({participants.contains($0.actorID) && subjects.contains($0.subjectID) && $0.subjectID != value.poolSubjectID}) else {throw VideoError.invalid("故事人物映射须绑定当前模型参与者和唯一实际舞台对象")}
        func owns(_ actor:String?,_ subject:String?)->Bool {guard let actor,let subject else{return false};return value.actors.contains{$0.actorID==actor && $0.subjectID==subject}}
        var sources:[String:StoryCausalSource]=[:]
        for source in value.sources {
            guard StoryActionRules.identifier(source.id),source.model.version==3,source.model.ruleTable != nil,source.startFrame>=0,source.endFrame>source.startFrame,source.endFrame<=scene.durationFrames else {throw VideoError.invalid("故事因果须绑定完整有限规则模型及有效独立帧窗")}
            try source.model.validate()
            try KnowledgeSimulationEngine.verify(source.trace,model:source.model,seed:source.seed)
            guard source.trace.throughTick == (try source.model.lastSettlementTick()),source.trace.rounds.count==source.model.rounds,source.trace.events.count==source.model.rounds*KnowledgePhase.allCases.count else {throw VideoError.review("故事因果必须保留正常规则引擎生成的完整实迹，不能用部分录制或摘要代替")}
            guard sources.values.allSatisfy({source.endFrame<=$0.startFrame || source.startFrame>=$0.endFrame}) else {throw VideoError.invalid("独立因果分支的展示帧窗不能重叠")}
            if let parentID=source.parentID {
                guard let parent=sources[parentID],parent.seed==source.seed,parent.endFrame<=source.startFrame,
                      [source.intervention != nil,source.actionCost != nil,source.ruleChange != nil].filter({$0}).count==1,var table=parent.model.ruleTable else {throw VideoError.invalid("反事实须引用更早的同种子父分支，并且只声明一种干预")}
                var expected=parent.model
                if let intervention=source.intervention {
                    guard intervention.actorID==intervention.plan.actorID,let index=table.plans.firstIndex(where:{$0.actorID==intervention.actorID}),table.plans[index] != intervention.plan else {throw VideoError.invalid("反事实须明确一个实际改变的参与者计划")}
                    table.plans[index]=intervention.plan;expected.ruleTable=table
                    guard expected==source.model else {throw VideoError.invalid("反事实只能改变声明的单一参与者计划；种子、规则和其余模型必须沿用父分支")}
                } else if let cost=source.actionCost {
                    guard value.version>=2,(0...100_000).contains(cost.newCost),table.actions.filter({$0.id==cost.actionID}).count==1,
                          let index=table.actions.firstIndex(where:{$0.id==cost.actionID}),table.actions[index].cost != cost.newCost else {throw VideoError.invalid("成本反事实须改变父模型中唯一现有动作的有效整数成本")}
                    table.actions[index].cost=cost.newCost;expected.ruleTable=table
                    guard expected==source.model else {throw VideoError.invalid("成本反事实只能改变声明动作的cost；规则、计划和其余完整模型必须沿用父分支")}
                    guard source.trace.events != parent.trace.events || source.trace.rounds != parent.trace.rounds || source.trace.finalResources != parent.trace.finalResources else {throw VideoError.review("成本反事实须有真实事件、轮次或最终资源差异，不能仅改变输入摘要")}
                } else if let change=source.ruleChange {
                    guard value.version==3,change.ruleID.range(of:"^[A-Za-z0-9_-]{1,40}$",options:.regularExpression) != nil,
                          change.rule.id==change.ruleID,table.rules.filter({$0.id==change.ruleID}).count==1,
                          let index=table.rules.firstIndex(where:{$0.id==change.ruleID}),table.rules[index] != change.rule else {throw VideoError.invalid("规则反事实须替换父模型中唯一现有规则，保留同一id并实际改变规则")}
                    table.rules[index]=change.rule;expected.ruleTable=table
                    guard expected==source.model else {throw VideoError.invalid("规则反事实只能替换声明的单一规则；计划、成本和其余完整模型必须沿用父分支")}
                }
                if value.version==3 {
                    guard try KnowledgeCounterfactualExplanation.build(baseline:parent.model,alternative:source.model,seed:source.seed).hasBehaviorDifference else {throw VideoError.review("规则反事实须有实际行动、状态或资金流变化；摘要、标签或规则诊断差异不足以表现新后果")}
                }
            } else {guard sources.isEmpty,source.intervention==nil,source.actionCost==nil,source.ruleChange==nil else {throw VideoError.invalid("故事因果只能有一个无干预根来源")}}
            sources[source.id]=source
        }
        guard Set(actions.map(\.id)).count==actions.count else {throw VideoError.invalid("故事动作标识不能重复")}
        let byAction=Dictionary(uniqueKeysWithValues:actions.map{($0.id,$0)})
        let bindings=Dictionary(uniqueKeysWithValues:value.bindings.map{($0.actionID,$0)})
        var appliedTransfers=Set<String>(),appliedDeliveries=Set<[String]>()
        for binding in value.bindings {
            guard let source=sources[binding.sourceID],let action=byAction[binding.actionID],let event=source.trace.events.first(where:{$0.id==binding.eventID}),
                  action.startFrame>=source.startFrame,action.endFrame<=source.endFrame,binding.requires.count<=32,Set(binding.requires).count==binding.requires.count,
                  binding.actorID.map({participants.contains($0)}) ?? true,binding.fromActorID.map({participants.contains($0)}) ?? true,binding.toActorID.map({participants.contains($0)}) ?? true else {throw VideoError.invalid("因果绑定须引用当前动作、真实来源事件、参与者和分支内时窗")}
            var allowed=Set<String>()
            switch binding.kind {
            case .performedAction:
                allowed=["actorID","actionKey"]
                guard let actor=binding.actorID,let key=binding.actionKey,event.phase == .contribution,
                      event.actors.contains(where:{$0.id==actor && $0.executedActionID==key}),owns(actor,action.subjectID) else {throw VideoError.review("过程动作必须对应实际已执行行动，不能使用请求或资源不足的拒绝行动")}
            case .deposit:
                allowed=["fromActorID","amount"]
                guard let payer=binding.fromActorID,let amount=binding.amount,amount>0,event.phase == .contribution,event.actors.contains(where:{$0.id==payer && $0.cost==amount}),
                      action.kind == .transfer,action.quantity==amount,action.targetID==value.poolSubjectID else {throw VideoError.review("入池动画须精确对应本事件真实扣费金额和公共池接收对象")}
                let key="\(source.id)|\(event.id)|deposit|\(payer)";guard appliedTransfers.insert(key).inserted else {throw VideoError.invalid("同一实际扣费不能重复认领为多次交付")}
            case .transfer,.payment:
                allowed=["ruleID","fromActorID","toActorID","amount"]
                guard let rule=binding.ruleID,let amount=binding.amount,amount>0,binding.fromActorID != binding.toActorID,event.phase == .settlement,
                      event.ruleExecution?.transfers.filter({$0.ruleID==rule && $0.sourceActorID==binding.fromActorID && $0.destinationActorID==binding.toActorID && $0.amount==amount}).count==1,
                      action.kind == .transfer,action.quantity==amount,(binding.toActorID == nil ? action.targetID==value.poolSubjectID:owns(binding.toActorID,action.targetID)) else {throw VideoError.review("付款动画须精确对应实际结算的规则、付方、收方和金额，不能使用匹配但未应用的规则")}
                let key="\(source.id)|\(event.id)|\(rule)|\(binding.fromActorID ?? "pool")|\(binding.toActorID ?? "pool")|\(amount)"
                guard appliedTransfers.insert(key).inserted else {throw VideoError.invalid("同一实际转账不能重复认领为多次付款")}
                if binding.kind == .payment {
                    guard binding.requires.contains(where:{required in
                        guard let delivery=bindings[required],delivery.kind == .delivery,delivery.sourceID==binding.sourceID,delivery.actorID==binding.toActorID,delivery.toActorID==binding.fromActorID,
                              let prior=source.trace.events.first(where:{$0.id==delivery.eventID}),prior.tick<event.tick,let delivered=byAction[required] else{return false}
                        return delivered.endFrame<=action.startFrame
                    }) else {throw VideoError.review("售货付款必须依赖同户交给本买家的真实交货，先完成交货后在更晚事件结算")}
                }
            case .stateChange,.delivery:
                allowed=["actorID","ruleID","fromStateID","toStateID"]
                if binding.kind == .delivery {allowed.insert("toActorID")}
                guard let actor=binding.actorID,let rule=binding.ruleID,let before=binding.fromStateID,let after=binding.toStateID,before != after,event.phase == .settlement,
                      event.ruleExecution?.stateChanges.contains(where:{$0.ruleID==rule && $0.actorID==actor && $0.beforeStateID==before && $0.afterStateID==after})==true,owns(actor,action.subjectID) else {throw VideoError.review("状态或交货过程须对应已应用的真实状态转换和所属舞台对象")}
                if binding.kind == .delivery {
                    guard binding.toActorID != actor,action.kind == .transfer,action.quantity==1,owns(binding.toActorID,action.targetID) else {throw VideoError.invalid("每件货物交付须明确货主、另一实际收货人和一件货物的完整过程")}
                    let key=[source.id,event.id,rule,actor,before,after]
                    guard appliedDeliveries.insert(key).inserted else {throw VideoError.invalid("同一次真实交货状态转换不能重复认领为多件货物或不同收货人的交付")}
                }
            case .outcome:
                allowed=["outcome"]
                guard let outcome=binding.outcome,[KnowledgePhase.resolution,.passage,.settlement].contains(event.phase),outcome==event.obstacleCleared else {throw VideoError.review("结果动画须与当前实迹已公布的实际结果一致")}
            }
            let fields:[String:Bool]=["actorID":binding.actorID != nil,"actionKey":binding.actionKey != nil,"ruleID":binding.ruleID != nil,"fromActorID":binding.fromActorID != nil,"toActorID":binding.toActorID != nil,"amount":binding.amount != nil,"fromStateID":binding.fromStateID != nil,"toStateID":binding.toStateID != nil,"outcome":binding.outcome != nil]
            guard fields.allSatisfy({!$0.value || allowed.contains($0.key)}) else {throw VideoError.invalid("因果绑定类型不接受隐藏或不适用的字段")}
            for required in binding.requires {
                guard required != binding.actionID,let dependency=bindings[required],dependency.sourceID==binding.sourceID,let prior=byAction[required],prior.endFrame<=action.startFrame,
                      let priorEvent=source.trace.events.first(where:{$0.id==dependency.eventID}),priorEvent.tick<=event.tick else {throw VideoError.invalid("动作前置必须属于同分支真实事件并已完成，不能循环或引用未来")}
            }
        }
        guard value.sources.allSatisfy({source in value.bindings.contains{$0.sourceID==source.id}}) else {throw VideoError.invalid("每个因果来源都须绑定本镜头的实际表现动作")}
    }
}

private enum StoryCausalDecoding {
    private struct Key:CodingKey {var stringValue:String;var intValue:Int?{nil};init?(stringValue:String){self.stringValue=stringValue};init?(intValue:Int){return nil}}
    static func keys(_ decoder:Decoder,required:Set<String>,optional:Set<String>=[])throws {
        let c=try decoder.container(keyedBy:Key.self),actual=Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of:actual),actual.isSubset(of:required.union(optional)) else {throw VideoError.invalid("故事因果字段缺失或不受支持；不会静默忽略旧别名与扩展字段")}
    }
    static func object(_ value:AgentValue,_ required:Set<String>,_ optional:Set<String>=[])throws->[String:AgentValue] {
        guard let object=value.object,required.isSubset(of:Set(object.keys)),Set(object.keys).isSubset(of:required.union(optional)) else {throw VideoError.invalid("故事来源内的模型或实迹包含未知/缺失字段")};return object
    }
    static func list(_ value:AgentValue?)throws->[AgentValue] {guard case .array(let rows)?=value else {throw VideoError.invalid("故事来源数组字段无效")};return rows}
    static func knowledge(_ value:AgentValue,trace:Bool)throws {
        if !trace {
            let model=try object(value,["version","knowledgeLabel","resourceLabel","participants","rounds","roundTicks","startTick","contributionCost","contributionUnits","threshold","benefit"],["payoffMatrix","ruleTable"])
            for row in try list(model["participants"]) {_ = try object(row,["id","name","strategy","initialResources"],["matrixStrategy"])}
            return // Finite rule-table's own strict decoder validates every nested condition/effect.
        }
        let t=try object(value,["version","inputDigest","seed","throughTick","events","rounds","finalResources"])
        for row in try list(t["finalResources"]) {_ = try object(row,["id","resources"])}
        for (name,required) in [("events",Set(["tick","round","phase","actors","totalContribution","threshold","obstacleCleared"])),("rounds",Set(["round","settledTick","actors","totalContribution","obstacleCleared"]))] {
            for row in try list(t[name]) {
                let event=try object(row,required,["matrixPool","ruleExecution"])
                for actor in try list(event["actors"]) {_ = try object(actor,["id","resources","contribution","cost","benefit","passed"],["choice","ruleStateID","requestedActionID","executedActionID"])}
                if let raw=event["ruleExecution"],raw != .null {
                    let execution=try object(raw,["poolBefore","poolAfter","externalFunding","deposits","matches","transfers","stateChanges"])
                    for transfer in try list(execution["transfers"]) {_ = try object(transfer,["ruleID","amount"],["sourceActorID","destinationActorID"])}
                    for change in try list(execution["stateChanges"]) {_ = try object(change,["ruleID","actorID","beforeStateID","afterStateID"])}
                    for match in try list(execution["matches"]) {let m=try object(match,["ruleID","facts"]);for fact in try list(m["facts"]) {_ = try object(fact,["conditionIndex"],["actualNumber","actualID"])}}
                }
            }
        }
    }
}

public enum StoryCausalSchema {
    public static let records:[String:String]=[
        "StoryCausality":"version:i poolSubjectID:s actors:[StoryCausalActor] sources:[StoryCausalSource] bindings:[StoryCausalBinding]",
        "StoryCausalActor":"actorID:s subjectID:s",
        "StoryCausalIntervention":"actorID:s plan:KnowledgeRuleActorPlan",
        "StoryCausalActionCost":"actionID:s newCost:i",
        "StoryCausalRuleChange":"ruleID:s rule:KnowledgeRule",
        "StoryCausalSource":"id:s parentID?:s intervention?:StoryCausalIntervention actionCost?:StoryCausalActionCost ruleChange?:StoryCausalRuleChange model:KnowledgeSimulation seed:i trace:KnowledgeTrace startFrame:i endFrame:i",
        "StoryCausalBinding":"actionID:s sourceID:s eventID:s kind:StoryCausalBindingKind requires:[s] actorID?:s actionKey?:s ruleID?:s fromActorID?:s toActorID?:s amount?:i fromStateID?:s toStateID?:s outcome?:b"
    ]
    public static let enums:[String:[String]]=["StoryCausalBindingKind":StoryCausalBindingKind.allCases.map(\.rawValue)]
}
