import Foundation

/// A bounded teaching model of a threshold public good, not Chrome's original rules
/// and not a prediction of real people. Other knowledge models need their own rules.
public struct KnowledgeSimulation: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var knowledgeLabel: String
    public var resourceLabel: String
    public var participants: [KnowledgeParticipant]
    public var rounds: Int
    public var roundTicks: Int
    public var startTick: Int
    public var contributionCost: Int
    public var contributionUnits: Int
    public var threshold: Int
    public var benefit: Int

    public init(knowledgeLabel: String, resourceLabel: String = "资源",
                participants: [KnowledgeParticipant], rounds: Int = 3,
                roundTicks: Int = 6, startTick: Int = 0,
                contributionCost: Int = 1, contributionUnits: Int = 1,
                threshold: Int = 1, benefit: Int = 3) {
        self.knowledgeLabel = knowledgeLabel; self.resourceLabel = resourceLabel
        self.participants = participants; self.rounds = rounds
        self.roundTicks = roundTicks; self.startTick = startTick
        self.contributionCost = contributionCost; self.contributionUnits = contributionUnits
        self.threshold = threshold; self.benefit = benefit
    }

    public static let teachingNotice = "阈值公共品教学模型；规则和收益由当前输入决定，不是原作游戏规则或现实预测。"

    public func validate() throws {
        guard version == 1, KnowledgeSimulationEngine.validText(knowledgeLabel, maximum: 240),
              KnowledgeSimulationEngine.validText(resourceLabel, maximum: 60),
              (2...8).contains(participants.count), Set(participants.map(\.id)).count == participants.count,
              (1...64).contains(rounds), (6...30).contains(roundTicks),
              (0...1800).contains(startTick), (0...100_000).contains(contributionCost),
              (1...1000).contains(contributionUnits), (1...10_000).contains(threshold),
              (0...100_000).contains(benefit) else {
            throw VideoError.invalid("知识模型版本、标签、参与者数量、轮次或成本/门槛/收益超出有限范围")
        }
        let totalBenefit = try KnowledgeSimulationEngine.multiply(rounds, benefit)
        for participant in participants {
            guard participant.id.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil,
                  KnowledgeSimulationEngine.validText(participant.name, maximum: 120),
                  (0...1_000_000).contains(participant.initialResources),
                  try KnowledgeSimulationEngine.add(participant.initialResources, totalBenefit) <= 1_000_000 else {
                throw VideoError.invalid("知识参与者标识、名称或可能获得的资源超过有限预算")
            }
        }
        guard try lastSettlementTick() <= 1800 else {
            throw VideoError.invalid("知识模型的完整结算超出30分钟规则时域；请减少轮次或缩短每轮")
        }
    }

    /// The caller must display this tick before calling the whole recording complete.
    public func lastSettlementTick() throws -> Int {
        guard (1...64).contains(rounds), (6...30).contains(roundTicks), (0...1800).contains(startTick) else {
            throw VideoError.invalid("知识模型轮次或时域无效")
        }
        return try KnowledgeSimulationEngine.add(KnowledgeSimulationEngine.add(startTick, KnowledgeSimulationEngine.multiply(rounds - 1, roundTicks)), 5)
    }
}

public enum KnowledgeStrategy: String, Codable, CaseIterable, Sendable {
    case contribute = "每轮出力"
    case freeRide = "等待他人出力"
    case reciprocate = "上轮他人出力才互惠"
    case rotate = "按轮次轮流出力"
}

public struct KnowledgeParticipant: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var strategy: KnowledgeStrategy
    public var initialResources: Int
    public init(id: String, name: String, strategy: KnowledgeStrategy, initialResources: Int = 3) {
        self.id = id; self.name = name; self.strategy = strategy; self.initialResources = initialResources
    }
}

public enum KnowledgeChoice: String, Codable, Sendable {
    case contribute = "出力"
    case wait = "等待"
    case constrained = "资源不足，无法出力"
}

public enum KnowledgePhase: String, Codable, CaseIterable, Sendable {
    case preparation = "本轮开始"
    case decision = "同时选择"
    case contribution = "实际出力与扣费"
    case resolution = "清障判定"
    case passage = "通行或受阻"
    case settlement = "收益结算"
}

public struct KnowledgeActorState: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var resources: Int
    public var choice: KnowledgeChoice?
    public var contribution: Int
    public var cost: Int
    public var benefit: Int
    public var passed: Bool
}

/// Every stored event is already visible at throughTick; no future choices or
/// settlements are published when the caller asks for a partial replay.
public struct KnowledgeEvent: Codable, Equatable, Identifiable, Sendable {
    public var tick: Int
    public var round: Int
    public var phase: KnowledgePhase
    public var actors: [KnowledgeActorState]
    public var totalContribution: Int
    public var threshold: Int
    public var obstacleCleared: Bool
    public var id: String { "\(round)-\(phase.rawValue)" }
}

public struct KnowledgeRoundResult: Codable, Equatable, Sendable {
    public var round: Int
    public var settledTick: Int
    public var totalContribution: Int
    public var obstacleCleared: Bool
    public var actors: [KnowledgeActorState]
}

public struct KnowledgeBalance: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var resources: Int
}

public struct KnowledgeTrace: Codable, Equatable, Sendable {
    public var version: Int
    public var inputDigest: String
    public var seed: UInt64
    public var throughTick: Int
    public var events: [KnowledgeEvent]
    public var rounds: [KnowledgeRoundResult]
    public var finalResources: [KnowledgeBalance]
}

public struct KnowledgeFrameState: Equatable, Sendable {
    public var tick: Int
    public var round: Int?
    public var phase: KnowledgePhase?
    public var phaseProgress: Double
    public var actors: [KnowledgeActorState]
    public var totalContribution: Int
    public var threshold: Int
    public var obstacleCleared: Bool
}

public struct KnowledgeBalanceDelta: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var baseline: Int
    public var alternative: Int
    public var difference: Int
}

public struct KnowledgeCounterfactual: Codable, Equatable, Sendable {
    public var baseline: KnowledgeTrace
    public var alternative: KnowledgeTrace
    public var balances: [KnowledgeBalanceDelta]
    public var clearedRoundDifference: Int
}

public enum KnowledgeSimulationEngine {
    private struct Input: Codable { var model: KnowledgeSimulation; var seed: UInt64 }

    fileprivate static func validText(_ text: String, maximum: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximum &&
        !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    fileprivate static func add(_ a: Int, _ b: Int) throws -> Int {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw VideoError.invalid("知识模型整数运算超出范围") }
        return result.partialValue
    }
    fileprivate static func multiply(_ a: Int, _ b: Int) throws -> Int {
        let result = a.multipliedReportingOverflow(by: b)
        guard !result.overflow else { throw VideoError.invalid("知识模型整数运算超出范围") }
        return result.partialValue
    }
    private static func initialActors(_ model: KnowledgeSimulation) -> [KnowledgeActorState] {
        model.participants.sorted { $0.id < $1.id }.map {
            KnowledgeActorState(id: $0.id, resources: $0.initialResources, choice: nil,
                                contribution: 0, cost: 0, benefit: 0, passed: false)
        }
    }

    public static func record(model: KnowledgeSimulation, seed: UInt64, throughTick: Int) throws -> KnowledgeTrace {
        try model.validate()
        guard (0...1800).contains(throughTick) else { throw VideoError.invalid("知识重放刻度超出有限范围") }
        let people = model.participants.sorted { $0.id < $1.id }
        var actors = initialActors(model), events: [KnowledgeEvent] = [], completed: [KnowledgeRoundResult] = []
        let rotation = Int(seed % UInt64(people.count))
        for round in 1...model.rounds {
            let start = try add(model.startTick, multiply(round - 1, model.roundTicks))
            guard start <= throughTick else { break }
            // Read only the previous completed round, never another decision this round.
            let previous = completed.last
            actors = actors.map { KnowledgeActorState(id: $0.id, resources: $0.resources, choice: nil, contribution: 0, cost: 0, benefit: 0, passed: false) }
            var total = 0, cleared = false
            for (offset, phase) in KnowledgePhase.allCases.enumerated() {
                let tick = try add(start, offset)
                guard tick <= throughTick else { break }
                switch phase {
                case .preparation: break
                case .decision:
                    // All choices use the same pre-contribution balances and history snapshot.
                    actors = actors.enumerated().map { index, actor in
                        var value = actor
                        let wantsToContribute: Bool
                        switch people[index].strategy {
                        case .contribute: wantsToContribute = true
                        case .freeRide: wantsToContribute = false
                        case .reciprocate:
                            wantsToContribute = previous.map { result in result.actors.contains { $0.id != actor.id && $0.contribution > 0 } } ?? true
                        case .rotate: wantsToContribute = index == (rotation + round - 1) % people.count
                        }
                        value.choice = !wantsToContribute ? .wait : actor.resources >= model.contributionCost ? .contribute : .constrained
                        return value
                    }
                case .contribution:
                    actors = try actors.map { actor in
                        var value = actor
                        if actor.choice == .contribute {
                            guard actor.resources >= model.contributionCost else { throw VideoError.invalid("知识出力成本超出参与者资源") }
                            value.resources = try add(actor.resources, -model.contributionCost)
                            value.cost = model.contributionCost; value.contribution = model.contributionUnits
                            total = try add(total, value.contribution)
                        }
                        return value
                    }
                case .resolution: cleared = total >= model.threshold
                case .passage: break
                case .settlement:
                    actors = try actors.map { actor in
                        var value = actor
                        if cleared { value.passed = true; value.benefit = model.benefit; value.resources = try add(actor.resources, model.benefit) }
                        guard (0...1_000_000).contains(value.resources) else { throw VideoError.invalid("知识结算超出参与者有限预算") }
                        return value
                    }
                    completed.append(KnowledgeRoundResult(round: round, settledTick: tick, totalContribution: total, obstacleCleared: cleared, actors: actors))
                }
                events.append(KnowledgeEvent(tick: tick, round: round, phase: phase, actors: actors,
                                             totalContribution: total, threshold: model.threshold, obstacleCleared: cleared))
            }
        }
        return KnowledgeTrace(version: 1, inputDigest: try Codec.digest(Input(model: model, seed: seed)),
                              seed: seed, throughTick: throughTick, events: events, rounds: completed,
                              finalResources: actors.map { KnowledgeBalance(id: $0.id, resources: $0.resources) })
    }

    public static func verify(_ trace: KnowledgeTrace, model: KnowledgeSimulation, seed: UInt64) throws {
        guard trace == (try record(model: model, seed: seed, throughTick: trace.throughTick)) else {
            throw VideoError.review("知识实体、策略、约束、收益、种子或逐事件结果已变；旧轨迹仅保留作历史，请重新运行复核")
        }
    }

    public static func frameState(model: KnowledgeSimulation, seed: UInt64, frame: Int, fps: Int = 30) throws -> KnowledgeFrameState {
        guard frame >= 0, (1...120).contains(fps), frame / fps <= 1800 else { throw VideoError.invalid("知识模型帧或帧率超出范围") }
        let tick = frame / fps, trace = try record(model: model, seed: seed, throughTick: tick)
        guard let event = trace.events.last else {
            return KnowledgeFrameState(tick: tick, round: nil, phase: nil, phaseProgress: 0,
                                       actors: initialActors(model), totalContribution: 0, threshold: model.threshold, obstacleCleared: false)
        }
        let elapsed = Double(frame - event.tick * fps) / Double(fps)
        return KnowledgeFrameState(tick: tick, round: event.round, phase: event.phase, phaseProgress: min(1, max(0, elapsed)),
                                   actors: event.actors, totalContribution: event.totalContribution,
                                   threshold: event.threshold, obstacleCleared: event.obstacleCleared)
    }

    /// A causal comparison keeps the participant identities, round count and seed
    /// fixed. Both results are actually computed; supplied/old results are not reused.
    public static func compare(baseline: KnowledgeSimulation, alternative: KnowledgeSimulation, seed: UInt64) throws -> KnowledgeCounterfactual {
        try baseline.validate(); try alternative.validate()
        guard Set(baseline.participants.map(\.id)) == Set(alternative.participants.map(\.id)), baseline.rounds == alternative.rounds else {
            throw VideoError.invalid("反事实比较须保留相同参与者身份和轮数，才能逐项比较同一模型中的策略/约束/收益")
        }
        let before = try record(model: baseline, seed: seed, throughTick: baseline.lastSettlementTick())
        let after = try record(model: alternative, seed: seed, throughTick: alternative.lastSettlementTick())
        let values = Dictionary(uniqueKeysWithValues: after.finalResources.map { ($0.id, $0.resources) })
        let differences = try before.finalResources.map { balance -> KnowledgeBalanceDelta in
            guard let changed = values[balance.id] else { throw VideoError.invalid("反事实结果缺少原参与者") }
            return KnowledgeBalanceDelta(id: balance.id, baseline: balance.resources, alternative: changed, difference: try add(changed, -balance.resources))
        }
        return KnowledgeCounterfactual(baseline: before, alternative: after, balances: differences,
                                       clearedRoundDifference: after.rounds.filter(\.obstacleCleared).count - before.rounds.filter(\.obstacleCleared).count)
    }
}

/// Shared wire declarations. These are data contracts, not a second rule engine.
public enum KnowledgeSimulationSchema {
    public static let records: [String: String] = [
        "KnowledgeSimulation": "version:i knowledgeLabel:s resourceLabel:s participants:[KnowledgeParticipant] rounds:i roundTicks:i startTick:i contributionCost:i contributionUnits:i threshold:i benefit:i",
        "KnowledgeParticipant": "id:s name:s strategy:KnowledgeStrategy initialResources:i",
        "KnowledgeActorState": "id:s resources:i choice?:KnowledgeChoice contribution:i cost:i benefit:i passed:b",
        "KnowledgeEvent": "tick:i round:i phase:KnowledgePhase actors:[KnowledgeActorState] totalContribution:i threshold:i obstacleCleared:b",
        "KnowledgeRoundResult": "round:i settledTick:i totalContribution:i obstacleCleared:b actors:[KnowledgeActorState]",
        "KnowledgeBalance": "id:s resources:i",
        "KnowledgeTrace": "version:i inputDigest:s seed:n throughTick:i events:[KnowledgeEvent] rounds:[KnowledgeRoundResult] finalResources:[KnowledgeBalance]"
    ]
    public static let enums: [String: [String]] = [
        "KnowledgeStrategy": KnowledgeStrategy.allCases.map(\.rawValue),
        "KnowledgeChoice": [KnowledgeChoice.contribute.rawValue, KnowledgeChoice.wait.rawValue, KnowledgeChoice.constrained.rawValue],
        "KnowledgePhase": KnowledgePhase.allCases.map(\.rawValue)
    ]
}
