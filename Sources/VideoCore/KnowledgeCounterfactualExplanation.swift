import Foundation

/// A read-only explanation of two freshly computed traces. This does not infer
/// a unique cause, re-evaluate conditions, or change the recorded simulation.
public struct KnowledgeCounterfactualExplanation: Codable, Equatable, Sendable {
    public let comparison: KnowledgeCounterfactual
    public let changedEvents: [KnowledgeCounterfactualEventDifference]
    public let timingChanges: [KnowledgeCounterfactualTimingDifference]

    /// First recorded observation difference, including stable rule/state
    /// identity or condition-fact differences. It is not proof of a sole cause.
    public var firstOutcomeDifference: KnowledgeCounterfactualEventDifference? { changedEvents.first }
    /// A teaching performance needs a changed action, state, resource or applied
    /// flow. Diagnostic rule identities and matched condition facts remain in
    /// changedEvents, but cannot alone qualify as changed behavior. The traces
    /// have already been recomputed and semantically aligned by build().
    public var hasBehaviorDifference: Bool {
        guard comparison.baseline.events.count == comparison.alternative.events.count else { return false }
        return zip(comparison.baseline.events, comparison.alternative.events).contains { left, right in
            guard left.round == right.round, left.phase == right.phase else { return false }
            return left.actors.sorted{$0.id < $1.id} != right.actors.sorted{$0.id < $1.id} || left.totalContribution != right.totalContribution ||
                left.obstacleCleared != right.obstacleCleared || left.matrixPool != right.matrixPool ||
                AppliedRuleBehavior(left.ruleExecution) != AppliedRuleBehavior(right.ruleExecution)
        }
    }
    public static let notice = "以下按同一种子、同一轮次与阶段对照实际记录，也包括规则身份和条件观测变化；记录不同不证明唯一成因，同时改动多项输入更不能归因于其中一项。未命中规则的负条件事实未记录，不能补造；模型不证明现实因果。"

    private struct AppliedRuleBehavior: Equatable {
        private struct Transfer: Equatable {
            let source: String?, destination: String?, amount: Int
        }
        private struct StateChange: Equatable {
            let actor: String, before: String, after: String
        }
        private let poolBefore: Int, poolAfter: Int, funding: Int, deposits: Int
        private let transfers: [Transfer]
        private let stateChanges: [StateChange]
        init(_ execution: KnowledgeRuleExecution?) {
            poolBefore=execution?.poolBefore ?? 0;poolAfter=execution?.poolAfter ?? 0
            funding=execution?.externalFunding ?? 0;deposits=execution?.deposits ?? 0
            // Settlement is atomic. Rule order and rule IDs do not make a new
            // flow; the actual endpoint/amount multiset does. Keep offsetting
            // transfers, even when their final balance deltas cancel out.
            transfers=(execution?.transfers ?? []).map{Transfer(source:$0.sourceActorID,destination:$0.destinationActorID,amount:$0.amount)}.sorted{
                ($0.source ?? "",$0.destination ?? "",$0.amount) < ($1.source ?? "",$1.destination ?? "",$1.amount)
            }
            stateChanges=(execution?.stateChanges ?? []).filter{$0.beforeStateID != $0.afterStateID}.map{
                StateChange(actor:$0.actorID,before:$0.beforeStateID,after:$0.afterStateID)
            }.sorted{($0.actor,$0.before,$0.after) < ($1.actor,$1.before,$1.after)}
        }
    }

    public static func build(baseline: KnowledgeSimulation, alternative: KnowledgeSimulation,
                             seed: UInt64) throws -> KnowledgeCounterfactualExplanation {
        // Keep the original engine, its validation, arithmetic and full-run
        // semantics as the single source of truth. No supplied trace is trusted.
        let comparison = try KnowledgeSimulationEngine.compare(baseline: baseline, alternative: alternative, seed: seed)
        let expected = baseline.rounds * KnowledgePhase.allCases.count
        guard comparison.baseline.events.count == expected, comparison.alternative.events.count == expected else {
            throw VideoError.invalid("完整反事实轨迹缺少实际轮次或阶段，不能拼接不完整的解释")
        }
        var changes: [KnowledgeCounterfactualEventDifference] = []
        var timing: [KnowledgeCounterfactualTimingDifference] = []
        // The two models may use different start ticks and round lengths. Align
        // by the semantic event identity, never by an array's clock timestamp.
        for (left, right) in zip(comparison.baseline.events, comparison.alternative.events) {
            guard left.round == right.round, left.phase == right.phase else {
                throw VideoError.invalid("反事实轨迹轮次与阶段不对应，不能比较不同语义的事件")
            }
            if left.tick != right.tick {
                timing.append(.init(round: left.round, phase: left.phase,
                                    baselineTick: left.tick, alternativeTick: right.tick))
            }
            let actorIDs = left.actors.compactMap { actor in
                actor == right.actors.first(where: { $0.id == actor.id }) ? nil : actor.id
            }
            var fields: [KnowledgeCounterfactualObservationField] = []
            if !actorIDs.isEmpty { fields.append(.actors) }
            if left.totalContribution != right.totalContribution { fields.append(.totalContribution) }
            if left.obstacleCleared != right.obstacleCleared { fields.append(.obstacleCleared) }
            if left.matrixPool != right.matrixPool { fields.append(.matrixPool) }
            if left.ruleExecution != right.ruleExecution { fields.append(.ruleExecution) }
            // Threshold is a model input repeated on every event, not an
            // already-observed consequence at preparation. Labels, digests and
            // timestamp-only changes likewise cannot manufacture an outcome.
            if !fields.isEmpty {
                changes.append(.init(baseline: left, alternative: right, changedActorIDs: actorIDs,
                                     changedRuleIDs: changedRules(left.ruleExecution, right.ruleExecution),
                                     observationFields: fields))
            }
        }
        return .init(comparison: comparison, changedEvents: changes, timingChanges: timing)
    }

    private static func changedRules(_ left: KnowledgeRuleExecution?, _ right: KnowledgeRuleExecution?) -> [String] {
        func ids(_ value: KnowledgeRuleExecution?) -> Set<String> {
            Set((value?.matches.map(\.ruleID) ?? []) + (value?.transfers.map(\.ruleID) ?? []) +
                (value?.stateChanges.map(\.ruleID) ?? []))
        }
        return ids(left).union(ids(right)).sorted().filter { id in
            left?.matches.filter { $0.ruleID == id } != right?.matches.filter { $0.ruleID == id } ||
            left?.transfers.filter { $0.ruleID == id } != right?.transfers.filter { $0.ruleID == id } ||
            left?.stateChanges.filter { $0.ruleID == id } != right?.stateChanges.filter { $0.ruleID == id }
        }
    }
}

public enum KnowledgeCounterfactualObservationField: String, Codable, Sendable {
    case actors, totalContribution, obstacleCleared, matrixPool, ruleExecution
    public var title: String {
        switch self {
        case .actors: return "实体选择、行动或状态"
        case .totalContribution: return "实际投入"
        case .obstacleCleared: return "实际清障结果"
        case .matrixPool: return "实际矩阵资金池"
        case .ruleExecution: return "实际规则观察与结算"
        }
    }
}

public struct KnowledgeCounterfactualEventDifference: Codable, Equatable, Identifiable, Sendable {
    public let baseline: KnowledgeEvent
    public let alternative: KnowledgeEvent
    public let changedActorIDs: [String]
    /// Rules whose recorded facts or applied effects differ. These are observed
    /// differences, not an inferred list of sole causes or failed conditions.
    public let changedRuleIDs: [String]
    public let observationFields: [KnowledgeCounterfactualObservationField]
    public var id: String { baseline.id }
    public var round: Int { baseline.round }
    public var phase: KnowledgePhase { baseline.phase }
}

public struct KnowledgeCounterfactualTimingDifference: Codable, Equatable, Identifiable, Sendable {
    public let round: Int
    public let phase: KnowledgePhase
    public let baselineTick: Int
    public let alternativeTick: Int
    public var id: String { "\(round)-\(phase.rawValue)" }
}
