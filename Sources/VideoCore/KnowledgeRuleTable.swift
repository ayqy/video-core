import Foundation

/// A small, data-only mechanism table. It neither executes user code nor makes
/// claims about the truth of the subject being taught. All amounts are integers
/// in the parent knowledge model's one resource unit.
public enum KnowledgeRulePose: String, Codable, CaseIterable, Sendable {
    case idle, act, walk, object, celebrate
    public var title: String {
        switch self {
        case .idle: return "倾听 / Idle"
        case .act: return "执行 / Act"
        case .walk: return "走动 / Walk"
        case .object: return "质疑 / Object"
        case .celebrate: return "回应 / Celebrate"
        }
    }
    public var spriteRole: String {
        switch self {
        case .idle: return "hero_idle"
        case .act: return "hero_contribute"
        case .walk: return "hero_walk"
        case .object: return "hero_blocked"
        case .celebrate: return "hero_success"
        }
    }
}

public struct KnowledgeRuleAction: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var cost: Int
    public var pose: KnowledgeRulePose
    public init(id: String, label: String, cost: Int = 0, pose: KnowledgeRulePose = .act) {
        self.id = id; self.label = label; self.cost = cost; self.pose = pose
    }
    private enum CodingKeys: String, CodingKey { case id, label, cost, pose }
    public init(from decoder: Decoder) throws {
        try KnowledgeTableDecoding.keys(decoder, required: ["id", "label", "cost", "pose"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); label = try c.decode(String.self, forKey: .label)
        cost = try c.decode(Int.self, forKey: .cost); pose = try c.decode(KnowledgeRulePose.self, forKey: .pose)
    }
}

public struct KnowledgeRuleState: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var pose: KnowledgeRulePose
    public init(id: String, label: String, pose: KnowledgeRulePose = .idle) {
        self.id = id; self.label = label; self.pose = pose
    }
    private enum CodingKeys: String, CodingKey { case id, label, pose }
    public init(from decoder: Decoder) throws {
        try KnowledgeTableDecoding.keys(decoder, required: ["id", "label", "pose"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); label = try c.decode(String.self, forKey: .label)
        pose = try c.decode(KnowledgeRulePose.self, forKey: .pose)
    }
}

public enum KnowledgeRuleConditionKind: String, Codable, CaseIterable, Sendable {
    case action, state, resources, actionCount, round
    public var title: String {
        switch self {
        case .action: return "实体已执行动作 / Action"
        case .state: return "实体状态 / State"
        case .resources: return "实体资源范围 / Resources"
        case .actionCount: return "已执行动作人数 / Action count"
        case .round: return "轮次范围 / Round"
        }
    }
}

/// Each kind has one exact field shape, checked before it can be evaluated.
/// Numeric bounds are inclusive. Decision conditions read the last completed
/// round (initial state in round one); result rules read one post-cost snapshot.
public struct KnowledgeRuleCondition: Codable, Equatable, Sendable {
    public var kind: KnowledgeRuleConditionKind
    public var actorID: String?
    public var actionID: String?
    public var stateID: String?
    public var minimum: Int?
    public var maximum: Int?
    public init(kind: KnowledgeRuleConditionKind, actorID: String? = nil, actionID: String? = nil,
                stateID: String? = nil, minimum: Int? = nil, maximum: Int? = nil) {
        self.kind = kind; self.actorID = actorID; self.actionID = actionID
        self.stateID = stateID; self.minimum = minimum; self.maximum = maximum
    }
    private enum CodingKeys: String, CodingKey { case kind, actorID, actionID, stateID, minimum, maximum }
    public init(from decoder: Decoder) throws {
        try KnowledgeTableDecoding.keys(decoder, required: ["kind"], optional: ["actorID", "actionID", "stateID", "minimum", "maximum"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(KnowledgeRuleConditionKind.self, forKey: .kind)
        actorID = try c.decodeIfPresent(String.self, forKey: .actorID); actionID = try c.decodeIfPresent(String.self, forKey: .actionID)
        stateID = try c.decodeIfPresent(String.self, forKey: .stateID)
        minimum = try c.decodeIfPresent(Int.self, forKey: .minimum); maximum = try c.decodeIfPresent(Int.self, forKey: .maximum)
    }
}

public struct KnowledgeRuleDecision: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var priority: Int
    public var conditions: [KnowledgeRuleCondition]
    public var actionID: String
    public init(id: String, priority: Int, conditions: [KnowledgeRuleCondition], actionID: String) {
        self.id = id; self.priority = priority; self.conditions = conditions; self.actionID = actionID
    }
    private enum CodingKeys: String, CodingKey { case id, priority, conditions, actionID }
    public init(from decoder: Decoder) throws {
        try KnowledgeTableDecoding.keys(decoder, required: ["id", "priority", "conditions", "actionID"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); priority = try c.decode(Int.self, forKey: .priority)
        conditions = try c.decode([KnowledgeRuleCondition].self, forKey: .conditions)
        actionID = try c.decode(String.self, forKey: .actionID)
    }
}

public struct KnowledgeRuleActorPlan: Codable, Equatable, Sendable {
    public var actorID: String
    public var initialStateID: String
    public var defaultActionID: String
    /// Empty uses the default; otherwise seed, stable actor order and round select
    /// a cycle entry only when no decision row matched. This is not random code.
    public var cycleActionIDs: [String]
    public var decisions: [KnowledgeRuleDecision]
    public init(actorID: String, initialStateID: String, defaultActionID: String,
                cycleActionIDs: [String] = [], decisions: [KnowledgeRuleDecision] = []) {
        self.actorID = actorID; self.initialStateID = initialStateID; self.defaultActionID = defaultActionID
        self.cycleActionIDs = cycleActionIDs; self.decisions = decisions
    }
    private enum CodingKeys: String, CodingKey { case actorID, initialStateID, defaultActionID, cycleActionIDs, decisions }
    public init(from decoder: Decoder) throws {
        try KnowledgeTableDecoding.keys(decoder, required: ["actorID", "initialStateID", "defaultActionID", "cycleActionIDs", "decisions"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actorID = try c.decode(String.self, forKey: .actorID); initialStateID = try c.decode(String.self, forKey: .initialStateID)
        defaultActionID = try c.decode(String.self, forKey: .defaultActionID)
        cycleActionIDs = try c.decode([String].self, forKey: .cycleActionIDs)
        decisions = try c.decode([KnowledgeRuleDecision].self, forKey: .decisions)
    }
}

public enum KnowledgeRuleEffectKind: String, Codable, CaseIterable, Sendable {
    case transfer, setState
    public var title: String { self == .transfer ? "定额资源转移 / Transfer" : "实体状态转换 / State change" }
}

/// A nil transfer endpoint means the explicitly funded common pool, never an
/// implicit source or sink. Both endpoints cannot be nil. State changes do not
/// create resource, passing rights or unrecorded effects.
public struct KnowledgeRuleEffect: Codable, Equatable, Sendable {
    public var kind: KnowledgeRuleEffectKind
    public var sourceActorID: String?
    public var destinationActorID: String?
    public var amount: Int?
    public var actorID: String?
    public var stateID: String?
    public init(kind: KnowledgeRuleEffectKind, sourceActorID: String? = nil,
                destinationActorID: String? = nil, amount: Int? = nil, actorID: String? = nil, stateID: String? = nil) {
        self.kind = kind; self.sourceActorID = sourceActorID; self.destinationActorID = destinationActorID
        self.amount = amount; self.actorID = actorID; self.stateID = stateID
    }
    public static func transfer(from sourceActorID: String?, to destinationActorID: String?, amount: Int) -> Self {
        Self(kind: .transfer, sourceActorID: sourceActorID, destinationActorID: destinationActorID, amount: amount)
    }
    public static func setState(actorID: String, stateID: String) -> Self { Self(kind: .setState, actorID: actorID, stateID: stateID) }
    private enum CodingKeys: String, CodingKey { case kind, sourceActorID, destinationActorID, amount, actorID, stateID }
    public init(from decoder: Decoder) throws {
        try KnowledgeTableDecoding.keys(decoder, required: ["kind"], optional: ["sourceActorID", "destinationActorID", "amount", "actorID", "stateID"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(KnowledgeRuleEffectKind.self, forKey: .kind)
        sourceActorID = try c.decodeIfPresent(String.self, forKey: .sourceActorID)
        destinationActorID = try c.decodeIfPresent(String.self, forKey: .destinationActorID)
        amount = try c.decodeIfPresent(Int.self, forKey: .amount)
        actorID = try c.decodeIfPresent(String.self, forKey: .actorID); stateID = try c.decodeIfPresent(String.self, forKey: .stateID)
    }
}

public struct KnowledgeRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var conditions: [KnowledgeRuleCondition]
    public var effects: [KnowledgeRuleEffect]
    public init(id: String, label: String, conditions: [KnowledgeRuleCondition], effects: [KnowledgeRuleEffect]) {
        self.id = id; self.label = label; self.conditions = conditions; self.effects = effects
    }
    private enum CodingKeys: String, CodingKey { case id, label, conditions, effects }
    public init(from decoder: Decoder) throws {
        try KnowledgeTableDecoding.keys(decoder, required: ["id", "label", "conditions", "effects"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); label = try c.decode(String.self, forKey: .label)
        conditions = try c.decode([KnowledgeRuleCondition].self, forKey: .conditions)
        effects = try c.decode([KnowledgeRuleEffect].self, forKey: .effects)
    }
}

public struct KnowledgeRuleTable: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var actions: [KnowledgeRuleAction]
    public var states: [KnowledgeRuleState]
    public var plans: [KnowledgeRuleActorPlan]
    public var rules: [KnowledgeRule]
    public var initialPool: Int
    public var externalBudgetPerRound: Int
    public init(actions: [KnowledgeRuleAction], states: [KnowledgeRuleState], plans: [KnowledgeRuleActorPlan],
                rules: [KnowledgeRule], initialPool: Int = 0, externalBudgetPerRound: Int = 0) {
        self.actions = actions; self.states = states; self.plans = plans; self.rules = rules
        self.initialPool = initialPool; self.externalBudgetPerRound = externalBudgetPerRound
    }
    private enum CodingKeys: String, CodingKey { case version, actions, states, plans, rules, initialPool, externalBudgetPerRound }
    public init(from decoder: Decoder) throws {
        try KnowledgeTableDecoding.keys(decoder, required: ["version", "actions", "states", "plans", "rules", "initialPool", "externalBudgetPerRound"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        actions = try c.decode([KnowledgeRuleAction].self, forKey: .actions)
        states = try c.decode([KnowledgeRuleState].self, forKey: .states)
        plans = try c.decode([KnowledgeRuleActorPlan].self, forKey: .plans)
        rules = try c.decode([KnowledgeRule].self, forKey: .rules)
        initialPool = try c.decode(Int.self, forKey: .initialPool)
        externalBudgetPerRound = try c.decode(Int.self, forKey: .externalBudgetPerRound)
    }

    public static let maximumResources = 1_000_000
    public static let maximumEncodedBytes = 64 * 1024
    public static let maximumConditions = 128
    public static let maximumEffects = 128
    public static let maximumDecisions = 64

    public func validate(participants: [KnowledgeParticipant], rounds: Int) throws {
        let actorIDs = Set(participants.map(\.id)), actionIDs = Set(actions.map(\.id)), stateIDs = Set(states.map(\.id))
        guard version == 1, (2...8).contains(participants.count), actorIDs.count == participants.count,
              (1...64).contains(rounds), (1...8).contains(actions.count), actionIDs.count == actions.count,
              (1...8).contains(states.count), stateIDs.count == states.count,
              (1...64).contains(rules.count), Set(rules.map(\.id)).count == rules.count,
              plans.count == participants.count, Set(plans.map(\.actorID)) == actorIDs,
              (0...Self.maximumResources).contains(initialPool), (0...Self.maximumResources).contains(externalBudgetPerRound) else {
            throw VideoError.invalid("有限规则表须有完整实体计划、1—8动作/状态、1—64规则及非负有限公共池")
        }
        for action in actions {
            guard Self.validID(action.id), Self.validText(action.label), (0...100_000).contains(action.cost) else {
                throw VideoError.invalid("规则动作的稳定标识、名称或实际自费成本无效")
            }
        }
        for state in states {
            guard Self.validID(state.id), Self.validText(state.label) else { throw VideoError.invalid("规则状态的稳定标识或名称无效") }
        }
        var conditionCount = 0, effectCount = 0, decisionCount = 0
        for plan in plans {
            guard stateIDs.contains(plan.initialStateID), actionIDs.contains(plan.defaultActionID),
                  plan.cycleActionIDs.count <= 8, plan.cycleActionIDs.allSatisfy(actionIDs.contains),
                  plan.decisions.count <= 16, Set(plan.decisions.map(\.id)).count == plan.decisions.count,
                  Set(plan.decisions.map(\.priority)).count == plan.decisions.count else {
                throw VideoError.invalid("实体计划须引用已有初始状态/默认动作，周期及决策优先级必须有界且不重复")
            }
            decisionCount += plan.decisions.count
            for row in plan.decisions {
                guard Self.validID(row.id), (0...1023).contains(row.priority), actionIDs.contains(row.actionID), row.conditions.count <= 8 else {
                    throw VideoError.invalid("决策行标识、动作或条件数量无效")
                }
                conditionCount += row.conditions.count
                try row.conditions.forEach { try validate($0, actors: actorIDs, actions: actionIDs, states: stateIDs) }
            }
        }
        for rule in rules {
            guard Self.validID(rule.id), Self.validText(rule.label), rule.conditions.count <= 8, (1...16).contains(rule.effects.count) else {
                throw VideoError.invalid("规则标识/名称、最多8条件或1—16效果无效")
            }
            conditionCount += rule.conditions.count; effectCount += rule.effects.count
            try rule.conditions.forEach { try validate($0, actors: actorIDs, actions: actionIDs, states: stateIDs) }
            try rule.effects.forEach { try validate($0, actors: actorIDs, states: stateIDs) }
        }
        guard conditionCount <= Self.maximumConditions, effectCount <= Self.maximumEffects, decisionCount <= Self.maximumDecisions,
              try Codec.data(self).count <= Self.maximumEncodedBytes else {
            throw VideoError.invalid("整份规则表超过128条件/128效果/64决策或64KiB字节预算")
        }
        _ = try maximumTotalResources(participants: participants, rounds: rounds)
    }

    /// A conservation-based ceiling includes every externally declared unit;
    /// moving units between actors and pool cannot increase it.
    public func maximumTotalResources(participants: [KnowledgeParticipant], rounds: Int) throws -> Int {
        guard (1...64).contains(rounds), (0...Self.maximumResources).contains(initialPool),
              (0...Self.maximumResources).contains(externalBudgetPerRound), participants.count <= 8,
              participants.allSatisfy({ (0...Self.maximumResources).contains($0.initialResources) }) else {
            throw VideoError.invalid("规则表资源上界输入无效")
        }
        let total = participants.reduce(initialPool) { $0 + $1.initialResources } + rounds * externalBudgetPerRound
        guard total <= Self.maximumResources else { throw VideoError.invalid("实体资源、初始公共池及全部轮次外部预算合计不得超过100万单位") }
        return total
    }

    private static func validID(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil }
    private static func validText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 120 &&
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private func validate(_ condition: KnowledgeRuleCondition, actors: Set<String>, actions: Set<String>, states: Set<String>) throws {
        let actor = condition.actorID.map(actors.contains) ?? false
        let action = condition.actionID.map(actions.contains) ?? false
        let state = condition.stateID.map(states.contains) ?? false
        let noRange = condition.minimum == nil && condition.maximum == nil
        let numericRange: Bool
        if let lo = condition.minimum, let hi = condition.maximum { numericRange = 0 <= lo && lo <= hi && hi <= Self.maximumResources }
        else { numericRange = false }
        let valid: Bool
        switch condition.kind {
        case .action: valid = actor && action && condition.stateID == nil && noRange
        case .state: valid = actor && state && condition.actionID == nil && noRange
        case .resources: valid = actor && condition.actionID == nil && condition.stateID == nil && numericRange
        case .actionCount: valid = condition.actorID == nil && action && condition.stateID == nil && numericRange && (condition.maximum ?? 9) <= 8
        case .round: valid = condition.actorID == nil && condition.actionID == nil && condition.stateID == nil && numericRange && (condition.minimum ?? 0) >= 1 && (condition.maximum ?? 65) <= 64
        }
        guard valid else { throw VideoError.invalid("规则条件字段须与类型严格一致，引用已有实体/动作/状态及有界闭区间") }
    }
    private func validate(_ effect: KnowledgeRuleEffect, actors: Set<String>, states: Set<String>) throws {
        let valid: Bool
        switch effect.kind {
        case .transfer:
            valid = (effect.sourceActorID != nil || effect.destinationActorID != nil) && effect.sourceActorID != effect.destinationActorID &&
                (effect.sourceActorID.map(actors.contains) ?? true) && (effect.destinationActorID.map(actors.contains) ?? true) &&
                effect.actorID == nil && effect.stateID == nil && (1...Self.maximumResources).contains(effect.amount ?? 0)
        case .setState:
            valid = effect.sourceActorID == nil && effect.destinationActorID == nil && effect.amount == nil &&
                (effect.actorID.map(actors.contains) ?? false) && (effect.stateID.map(states.contains) ?? false)
        }
        guard valid else { throw VideoError.invalid("规则效果仅允许已有实体/显式公共池之间正额转移，或已有实体的有限状态转换") }
    }
}

public struct KnowledgeRuleFact: Codable, Equatable, Sendable {
    public var conditionIndex: Int
    public var actualNumber: Int?
    public var actualID: String?
}

public struct KnowledgeRuleMatch: Codable, Equatable, Sendable {
    public var ruleID: String
    public var facts: [KnowledgeRuleFact]
}

public struct KnowledgeRuleTransfer: Codable, Equatable, Sendable {
    public var ruleID: String
    public var sourceActorID: String?
    public var destinationActorID: String?
    public var amount: Int
}

public struct KnowledgeRuleStateChange: Codable, Equatable, Sendable {
    public var ruleID: String
    public var actorID: String
    public var beforeStateID: String
    public var afterStateID: String
}

/// All values describe what is already observable at this event's tick. Matches
/// appear at resolution; applied transfers and new states only at settlement.
public struct KnowledgeRuleExecution: Codable, Equatable, Sendable {
    public var poolBefore: Int
    public var poolAfter: Int
    public var externalFunding: Int
    public var deposits: Int
    public var matches: [KnowledgeRuleMatch]
    public var transfers: [KnowledgeRuleTransfer]
    public var stateChanges: [KnowledgeRuleStateChange]
}

private enum KnowledgeTableDecoding {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func keys(_ decoder: Decoder, required: Set<String>, optional: Set<String> = []) throws {
        let c = try decoder.container(keyedBy: Key.self), keys = Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "有限规则表字段缺失或包含未知条件/效果；不能静默忽略规则"))
        }
    }
}

/// This interpreter has no file, network, reflection, expression-language or
/// dynamic-dispatch entry point. Validation bounds both table size and time.
public enum KnowledgeRuleTableEngine {
    public static func record(model: KnowledgeSimulation, seed: UInt64, throughTick: Int) throws -> KnowledgeTrace {
        try model.validate()
        guard model.version == 3, let table = model.ruleTable, (0...1800).contains(throughTick) else {
            throw VideoError.invalid("有限规则表须使用知识版本3及有效重放刻度")
        }
        let plans = Dictionary(uniqueKeysWithValues: table.plans.map { ($0.actorID, $0) })
        let actions = Dictionary(uniqueKeysWithValues: table.actions.map { ($0.id, $0) })
        let sortedRules = table.rules.sorted { $0.id < $1.id }
        var actors = initialActors(model), pool = table.initialPool
        var events: [KnowledgeEvent] = [], completed: [KnowledgeRoundResult] = []
        for round in 1...model.rounds {
            let start = model.startTick + (round - 1) * model.roundTicks
            guard start <= throughTick else { break }
            let previous = actors
            actors = actors.map { actor in
                var value = actor; value.choice = nil; value.contribution = 0; value.cost = 0; value.benefit = 0; value.passed = false
                value.requestedActionID = nil; value.executedActionID = nil; return value
            }
            var execution = KnowledgeRuleExecution(poolBefore: pool, poolAfter: pool, externalFunding: 0, deposits: 0,
                                                   matches: [], transfers: [], stateChanges: [])
            for (offset, phase) in KnowledgePhase.allCases.enumerated() {
                let tick = start + offset
                guard tick <= throughTick else { break }
                switch phase {
                case .preparation: break
                case .decision:
                    actors = actors.enumerated().map { index, actor in
                        // All plans read the same last completed snapshot.
                        let plan = plans[actor.id]!
                        let selected = plan.decisions.sorted { $0.priority < $1.priority }.first { row in
                            row.conditions.allSatisfy { evaluate($0, actors: previous, round: round).matches }
                        }?.actionID
                        let fallback = plan.cycleActionIDs.isEmpty ? plan.defaultActionID :
                            plan.cycleActionIDs[(Int(seed % UInt64(plan.cycleActionIDs.count)) + index + round - 1) % plan.cycleActionIDs.count]
                        let action = actions[selected ?? fallback]!
                        var value = actor; value.requestedActionID = action.id
                        if actor.resources < action.cost { value.choice = .constrained }
                        return value
                    }
                case .contribution:
                    var deposits = 0
                    actors = actors.map { actor in
                        var value = actor
                        if let id = actor.requestedActionID, actor.choice != .constrained {
                            let cost = actions[id]!.cost
                            value.executedActionID = id; value.resources -= cost; value.cost = cost; deposits += cost
                        }
                        return value
                    }
                    pool += deposits + table.externalBudgetPerRound
                    execution.deposits = deposits; execution.externalFunding = table.externalBudgetPerRound; execution.poolAfter = pool
                case .resolution:
                    // No rule observes a mutation caused by another matching row.
                    execution.matches = sortedRules.compactMap { rule in
                        let facts = rule.conditions.enumerated().map { index, condition in
                            (index, evaluate(condition, actors: actors, round: round))
                        }
                        guard facts.allSatisfy({ $0.1.matches }) else { return nil }
                        return KnowledgeRuleMatch(ruleID: rule.id, facts: facts.map {
                            KnowledgeRuleFact(conditionIndex: $0.0, actualNumber: $0.1.number, actualID: $0.1.id)
                        })
                    }
                case .passage: break
                case .settlement:
                    let result = try settle(actors: actors, pool: pool, rules: sortedRules, matches: execution.matches, round: round)
                    actors = result.actors; pool = result.pool
                    execution.transfers = result.transfers; execution.stateChanges = result.states; execution.poolAfter = pool
                    completed.append(KnowledgeRoundResult(round: round, settledTick: tick, totalContribution: execution.deposits,
                                                          obstacleCleared: false, actors: actors, ruleExecution: execution))
                }
                events.append(KnowledgeEvent(tick: tick, round: round, phase: phase, actors: actors,
                                             totalContribution: execution.deposits, threshold: 0, obstacleCleared: false, ruleExecution: execution))
            }
        }
        struct Input: Codable { var model: KnowledgeSimulation; var seed: UInt64 }
        return KnowledgeTrace(version: 3, inputDigest: try Codec.digest(Input(model: model, seed: seed)), seed: seed,
                              throughTick: throughTick, events: events, rounds: completed,
                              finalResources: actors.map { KnowledgeBalance(id: $0.id, resources: $0.resources) })
    }

    public static func initialActors(_ model: KnowledgeSimulation) -> [KnowledgeActorState] {
        // Record validates duplicates first; this public observation helper must
        // still avoid a dictionary precondition trap for an unvalidated draft.
        let states = Dictionary((model.ruleTable?.plans ?? []).map { ($0.actorID, $0.initialStateID) }, uniquingKeysWith: { first, _ in first })
        return model.participants.sorted { $0.id < $1.id }.map { participant in
            KnowledgeActorState(id: participant.id, resources: participant.initialResources, choice: nil,
                                contribution: 0, cost: 0, benefit: 0, passed: false, ruleStateID: states[participant.id])
        }
    }

    private struct Observation { var matches: Bool; var number: Int? = nil; var id: String? = nil }
    private static func evaluate(_ condition: KnowledgeRuleCondition, actors: [KnowledgeActorState], round: Int) -> Observation {
        let actor = actors.first { $0.id == condition.actorID }
        switch condition.kind {
        case .action: return Observation(matches: actor?.executedActionID == condition.actionID, id: actor?.executedActionID)
        case .state: return Observation(matches: actor?.ruleStateID == condition.stateID, id: actor?.ruleStateID)
        case .resources:
            let value = actor!.resources
            return Observation(matches: (condition.minimum!...condition.maximum!).contains(value), number: value)
        case .actionCount:
            let value = actors.filter { $0.executedActionID == condition.actionID }.count
            return Observation(matches: (condition.minimum!...condition.maximum!).contains(value), number: value)
        case .round: return Observation(matches: (condition.minimum!...condition.maximum!).contains(round), number: round)
        }
    }

    private struct Settlement {
        var actors: [KnowledgeActorState]; var pool: Int
        var transfers: [KnowledgeRuleTransfer]; var states: [KnowledgeRuleStateChange]
    }
    private static func settle(actors: [KnowledgeActorState], pool: Int, rules: [KnowledgeRule], matches: [KnowledgeRuleMatch], round: Int) throws -> Settlement {
        let matched = Set(matches.map(\.ruleID)), indexes = Dictionary(uniqueKeysWithValues: actors.enumerated().map { ($0.element.id, $0.offset) })
        var debits = [Int](repeating: 0, count: actors.count + 1), credits = debits
        let poolIndex = actors.count
        var transfers: [KnowledgeRuleTransfer] = [], states: [KnowledgeRuleStateChange] = []
        var written = Set<String>()
        for rule in rules where matched.contains(rule.id) {
            for effect in rule.effects {
                switch effect.kind {
                case .transfer:
                    let source = effect.sourceActorID.map { indexes[$0]! } ?? poolIndex
                    let destination = effect.destinationActorID.map { indexes[$0]! } ?? poolIndex
                    let amount = effect.amount!
                    debits[source] += amount; credits[destination] += amount
                    transfers.append(KnowledgeRuleTransfer(ruleID: rule.id, sourceActorID: effect.sourceActorID,
                                                          destinationActorID: effect.destinationActorID, amount: amount))
                case .setState:
                    let actorID = effect.actorID!
                    guard written.insert(actorID).inserted else { throw VideoError.invalid("第\(round)轮规则\(rule.id)重复写入实体\(actorID)状态；原子结算拒绝相互覆盖") }
                    states.append(KnowledgeRuleStateChange(ruleID: rule.id, actorID: actorID,
                                                          beforeStateID: actors[indexes[actorID]!].ruleStateID!, afterStateID: effect.stateID!))
                }
            }
        }
        let available = actors.map(\.resources) + [pool]
        guard debits.enumerated().allSatisfy({ $0.element <= available[$0.offset] }) else {
            throw VideoError.invalid("第\(round)轮匹配规则合计扣款超过同一快照的实体资源或公共池；不能透支、按顺序借用本轮入账或截断效果")
        }
        var result = actors
        for index in result.indices {
            result[index].resources = available[index] - debits[index] + credits[index]
            result[index].cost += debits[index]; result[index].benefit = credits[index]
        }
        for change in states { result[indexes[change.actorID]!].ruleStateID = change.afterStateID }
        let finalPool = pool - debits[poolIndex] + credits[poolIndex]
        guard result.allSatisfy({ (0...KnowledgeRuleTable.maximumResources).contains($0.resources) }),
              (0...KnowledgeRuleTable.maximumResources).contains(finalPool),
              result.reduce(finalPool, { $0 + $1.resources }) == available.reduce(0, +) else {
            throw VideoError.invalid("规则原子结算超出资源预算或不守恒")
        }
        return Settlement(actors: result, pool: finalPool, transfers: transfers, states: states)
    }
}
