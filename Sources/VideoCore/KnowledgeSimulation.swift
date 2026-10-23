import Foundation

/// Bounded teaching mechanisms, not Chrome's rules or predictions of people.
/// Version 1 is the original threshold public good. Version 2 is a two-person,
/// two-action payoff matrix. Version 3 is an editable finite rule table.
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
    public var payoffMatrix: KnowledgePayoffMatrix?
    public var ruleTable: KnowledgeRuleTable?

    public init(knowledgeLabel: String, resourceLabel: String = "资源",
                participants: [KnowledgeParticipant], rounds: Int = 3,
                roundTicks: Int = 6, startTick: Int = 0,
                contributionCost: Int = 1, contributionUnits: Int = 1,
                threshold: Int = 1, benefit: Int = 3,
                payoffMatrix: KnowledgePayoffMatrix? = nil, ruleTable: KnowledgeRuleTable? = nil) {
        self.knowledgeLabel = knowledgeLabel; self.resourceLabel = resourceLabel
        self.participants = participants; self.rounds = rounds
        self.roundTicks = roundTicks; self.startTick = startTick
        self.contributionCost = contributionCost; self.contributionUnits = contributionUnits
        self.threshold = threshold; self.benefit = benefit
        self.payoffMatrix = payoffMatrix
        self.ruleTable = ruleTable
        if payoffMatrix != nil { version = 2 }
        if ruleTable != nil { version = 3 }
    }

    public static let teachingNotice = "有界教学模型；实体、行动、状态、资金和规则由当前输入决定，不是原作游戏规则、现实预测或自动事实结论。"

    public var isPayoffMatrix: Bool { version == 2 }
    public var isRuleTable: Bool { version == 3 }

    public func phaseTitle(_ phase: KnowledgePhase) -> String {
        if isRuleTable {
            switch phase {
            case .preparation: return "本轮开始"
            case .decision: return "同时选择"
            case .contribution: return "实际行动与自费"
            case .resolution: return "匹配因果规则"
            case .passage: return "规则演绎"
            case .settlement: return "原子结算与状态转换"
            }
        }
        guard isPayoffMatrix else { return phase.rawValue }
        switch phase {
        case .preparation: return "本轮开始"
        case .decision: return "同时选择"
        case .contribution: return "押金入池"
        case .resolution: return "确定收益格"
        case .passage: return "交互展示"
        case .settlement: return "收益结算"
        }
    }

    public func actionLabel(_ choice: KnowledgeChoice?) -> String {
        switch choice {
        case .actionFirst: return payoffMatrix?.firstActionLabel ?? "行动一"
        case .actionSecond: return payoffMatrix?.secondActionLabel ?? "行动二"
        case .none: return "尚未选择"
        default: return choice?.rawValue ?? "尚未选择"
        }
    }

    public func validate() throws {
        guard (1...3).contains(version), KnowledgeSimulationEngine.validText(knowledgeLabel, maximum: 240),
              KnowledgeSimulationEngine.validText(resourceLabel, maximum: 60),
              (2...8).contains(participants.count), Set(participants.map(\.id)).count == participants.count,
              (1...64).contains(rounds), (6...30).contains(roundTicks),
              (0...1800).contains(startTick), (0...100_000).contains(contributionCost),
              (1...1000).contains(contributionUnits), (1...10_000).contains(threshold),
              (0...100_000).contains(benefit) else {
            throw VideoError.invalid("知识模型版本、标签、参与者数量、轮次或成本/门槛/收益超出有限范围")
        }
        if version == 1 {
            guard payoffMatrix == nil, ruleTable == nil, participants.allSatisfy({ $0.matrixStrategy == nil }) else {
                throw VideoError.invalid("公共品版本不能混入收益矩阵或矩阵策略")
            }
        } else if version == 2 {
            guard let payoffMatrix, ruleTable == nil, participants.count == 2,
                  participants.allSatisfy({ $0.matrixStrategy != nil && $0.strategy == .contribute }) else {
                throw VideoError.invalid("收益矩阵必须完整指定两名参与者及各自矩阵策略；旧出力策略不能混用")
            }
            try payoffMatrix.validate()
        } else {
            guard let ruleTable, payoffMatrix == nil,
                  participants.allSatisfy({ $0.matrixStrategy == nil && $0.strategy == .contribute }) else {
                throw VideoError.invalid("有限规则表须使用完整版本3规则，不混入旧出力或矩阵策略")
            }
            try ruleTable.validate(participants: participants, rounds: rounds)
        }
        let people = participants.sorted { $0.id < $1.id }
        for participant in participants {
            guard participant.id.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil,
                  KnowledgeSimulationEngine.validText(participant.name, maximum: 120),
                  (0...1_000_000).contains(participant.initialResources) else {
                throw VideoError.invalid("知识参与者标识、名称或可能获得的资源超过有限预算")
            }
            let maximumGain: Int
            if isRuleTable { maximumGain = 0 }
            else if let matrix = payoffMatrix {
                let requiredStake = try KnowledgeSimulationEngine.multiply(rounds, matrix.stake)
                guard participant.initialResources >= requiredStake else {
                    throw VideoError.invalid("收益矩阵初始资源须覆盖全部轮次的最坏押金，不能透支或中途虚构行动")
                }
                let row = people.first?.id == participant.id
                let maximumPayout = matrix.cells.map { row ? $0.rowPayout : $0.columnPayout }.max() ?? 0
                maximumGain = max(0, maximumPayout - matrix.stake)
            } else { maximumGain = benefit }
            guard try KnowledgeSimulationEngine.add(participant.initialResources, KnowledgeSimulationEngine.multiply(rounds, maximumGain)) <= 1_000_000 else {
                throw VideoError.invalid("知识参与者的最坏可获资源超出有限预算")
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

    public func maximumTotalResources() throws -> Int {
        try validate()
        if let ruleTable { return try ruleTable.maximumTotalResources(participants: participants, rounds: rounds) }
        return try participants.sorted { $0.id < $1.id }.enumerated().reduce(0) { total, entry in
            let maximumPayout = payoffMatrix.map { matrix in
                matrix.cells.map { entry.offset == 0 ? $0.rowPayout : $0.columnPayout }.max() ?? 0
            }
            let gain = maximumPayout.map { max(0, $0 - (payoffMatrix?.stake ?? 0)) } ?? benefit
            return try KnowledgeSimulationEngine.add(total, KnowledgeSimulationEngine.add(entry.element.initialResources, KnowledgeSimulationEngine.multiply(rounds, gain)))
        }
    }
}

public enum KnowledgeMatrixAction: String, Codable, CaseIterable, Sendable {
    case first, second
}

public enum KnowledgeMatrixStrategy: String, Codable, CaseIterable, Sendable {
    case alwaysFirst = "始终选择行动一"
    case alwaysSecond = "始终选择行动二"
    case reciprocate = "复制对方上轮行动"
    case winStayLoseShift = "净收益非负保持，否则切换"
    case alternate = "按种子交替行动"
}

public struct KnowledgePayoffCell: Codable, Equatable, Sendable {
    public var rowAction: KnowledgeMatrixAction
    public var columnAction: KnowledgeMatrixAction
    public var rowPayout: Int
    public var columnPayout: Int
    public init(rowAction: KnowledgeMatrixAction, columnAction: KnowledgeMatrixAction, rowPayout: Int, columnPayout: Int) {
        self.rowAction = rowAction; self.columnAction = columnAction
        self.rowPayout = rowPayout; self.columnPayout = columnPayout
    }
    private enum CodingKeys: String, CodingKey { case rowAction, columnAction, rowPayout, columnPayout }
    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: KnowledgeRuleKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(["rowAction", "columnAction", "rowPayout", "columnPayout"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "收益格字段缺失或含未知规则"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rowAction = try values.decode(KnowledgeMatrixAction.self, forKey: .rowAction)
        columnAction = try values.decode(KnowledgeMatrixAction.self, forKey: .columnAction)
        rowPayout = try values.decode(Int.self, forKey: .rowPayout)
        columnPayout = try values.decode(Int.self, forKey: .columnPayout)
    }
}

/// Cells specify actual allocations, not unbacked changes to a participant's balance.
/// Net payoff is allocation minus that participant's stake. Any unallocated amount
/// stays in the round's pool ledger, rather than becoming another actor's benefit.
public struct KnowledgePayoffMatrix: Codable, Equatable, Sendable {
    public var firstActionLabel: String
    public var secondActionLabel: String
    public var stake: Int
    public var externalBudget: Int
    public var cells: [KnowledgePayoffCell]

    public init(firstActionLabel: String, secondActionLabel: String, stake: Int, externalBudget: Int, cells: [KnowledgePayoffCell]) {
        self.firstActionLabel = firstActionLabel; self.secondActionLabel = secondActionLabel
        self.stake = stake; self.externalBudget = externalBudget; self.cells = cells
    }

    public static func prisonersDilemma() -> Self {
        Self(firstActionLabel: "合作", secondActionLabel: "背离", stake: 2, externalBudget: 6, cells: [
            KnowledgePayoffCell(rowAction: .first, columnAction: .first, rowPayout: 5, columnPayout: 5),
            KnowledgePayoffCell(rowAction: .first, columnAction: .second, rowPayout: 0, columnPayout: 7),
            KnowledgePayoffCell(rowAction: .second, columnAction: .first, rowPayout: 7, columnPayout: 0),
            KnowledgePayoffCell(rowAction: .second, columnAction: .second, rowPayout: 3, columnPayout: 3)
        ])
    }

    public func validate() throws {
        guard KnowledgeSimulationEngine.validText(firstActionLabel, maximum: 60),
              KnowledgeSimulationEngine.validText(secondActionLabel, maximum: 60), firstActionLabel != secondActionLabel,
              (0...100_000).contains(stake), (0...200_000).contains(externalBudget), cells.count == 4 else {
            throw VideoError.invalid("收益矩阵须有两个不同的有限行动名称、押金、外部预算及完整四格")
        }
        let pool = try KnowledgeSimulationEngine.add(KnowledgeSimulationEngine.multiply(2, stake), externalBudget)
        var combinations = Set<String>()
        for cell in cells {
            guard combinations.insert(cell.rowAction.rawValue + ":" + cell.columnAction.rawValue).inserted,
                  (0...200_000).contains(cell.rowPayout), (0...200_000).contains(cell.columnPayout),
                  try KnowledgeSimulationEngine.add(cell.rowPayout, cell.columnPayout) <= pool else {
                throw VideoError.invalid("收益矩阵四格必须各不重复、发放非负且总额不超过当轮两人押金和外部预算")
            }
        }
    }

    public func cell(row: KnowledgeMatrixAction, column: KnowledgeMatrixAction) throws -> KnowledgePayoffCell {
        guard let value = cells.first(where: { $0.rowAction == row && $0.columnAction == column }) else {
            throw VideoError.invalid("收益矩阵缺少当前行动组合")
        }
        return value
    }

    // Reject unknown rule keys rather than silently treating them as active rules.
    private enum CodingKeys: String, CodingKey { case firstActionLabel, secondActionLabel, stake, externalBudget, cells }
    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: KnowledgeRuleKey.self)
        let allowed = Set(["firstActionLabel", "secondActionLabel", "stake", "externalBudget", "cells"])
        guard Set(all.allKeys.map(\.stringValue)) == allowed else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "收益矩阵字段缺失或含未知规则"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        firstActionLabel = try values.decode(String.self, forKey: .firstActionLabel)
        secondActionLabel = try values.decode(String.self, forKey: .secondActionLabel)
        stake = try values.decode(Int.self, forKey: .stake)
        externalBudget = try values.decode(Int.self, forKey: .externalBudget)
        cells = try values.decode([KnowledgePayoffCell].self, forKey: .cells)
    }
}

private struct KnowledgeRuleKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public struct KnowledgeMatrixPool: Codable, Equatable, Sendable {
    public var available: Int
    public var distributed: Int
    public var remainder: Int
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
    public var matrixStrategy: KnowledgeMatrixStrategy?
    public init(id: String, name: String, strategy: KnowledgeStrategy, initialResources: Int = 3,
                matrixStrategy: KnowledgeMatrixStrategy? = nil) {
        self.id = id; self.name = name; self.strategy = strategy; self.initialResources = initialResources
        self.matrixStrategy = matrixStrategy
    }
}

public enum KnowledgeChoice: String, Codable, Sendable {
    case contribute = "出力"
    case wait = "等待"
    case constrained = "资源不足，无法出力"
    case actionFirst = "行动一"
    case actionSecond = "行动二"
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
    public var ruleStateID: String? = nil
    public var requestedActionID: String? = nil
    public var executedActionID: String? = nil
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
    public var matrixPool: KnowledgeMatrixPool? = nil
    public var ruleExecution: KnowledgeRuleExecution? = nil
    public var id: String { "\(round)-\(phase.rawValue)" }
}

public struct KnowledgeRoundResult: Codable, Equatable, Sendable {
    public var round: Int
    public var settledTick: Int
    public var totalContribution: Int
    public var obstacleCleared: Bool
    public var actors: [KnowledgeActorState]
    public var matrixPool: KnowledgeMatrixPool? = nil
    public var ruleExecution: KnowledgeRuleExecution? = nil
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
    public var matrixPool: KnowledgeMatrixPool? = nil
    public var ruleExecution: KnowledgeRuleExecution? = nil
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
        if model.isRuleTable { return KnowledgeRuleTableEngine.initialActors(model) }
        return model.participants.sorted { $0.id < $1.id }.map {
            KnowledgeActorState(id: $0.id, resources: $0.initialResources, choice: nil,
                                contribution: 0, cost: 0, benefit: 0, passed: false)
        }
    }

    public static func record(model: KnowledgeSimulation, seed: UInt64, throughTick: Int) throws -> KnowledgeTrace {
        try model.validate()
        guard (0...1800).contains(throughTick) else { throw VideoError.invalid("知识重放刻度超出有限范围") }
        if model.isRuleTable { return try KnowledgeRuleTableEngine.record(model: model, seed: seed, throughTick: throughTick) }
        if model.isPayoffMatrix { return try recordMatrix(model: model, seed: seed, throughTick: throughTick) }
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

    private static func action(_ choice: KnowledgeChoice?) throws -> KnowledgeMatrixAction {
        switch choice {
        case .actionFirst: return .first
        case .actionSecond: return .second
        default: throw VideoError.invalid("收益矩阵事件缺少完整行动，不能采用公共品动作或隐藏回退")
        }
    }

    private static func recordMatrix(model: KnowledgeSimulation, seed: UInt64, throughTick: Int) throws -> KnowledgeTrace {
        guard let matrix = model.payoffMatrix else { throw VideoError.invalid("收益矩阵规则缺失") }
        let people = model.participants.sorted { $0.id < $1.id }
        var actors = initialActors(model), events: [KnowledgeEvent] = [], completed: [KnowledgeRoundResult] = []
        for round in 1...model.rounds {
            let start = try add(model.startTick, multiply(round - 1, model.roundTicks))
            guard start <= throughTick else { break }
            let previous = completed.last
            actors = actors.map { KnowledgeActorState(id: $0.id, resources: $0.resources, choice: nil, contribution: 0, cost: 0, benefit: 0, passed: false) }
            var deposited = 0, pool: KnowledgeMatrixPool?
            for (offset, phase) in KnowledgePhase.allCases.enumerated() {
                let tick = try add(start, offset)
                guard tick <= throughTick else { break }
                switch phase {
                case .preparation: break
                case .decision:
                    // Both actors observe the same completed-round snapshot, never
                    // the other actor's current-round decision or future payoff.
                    actors = try actors.enumerated().map { index, actor in
                        guard let strategy = people[index].matrixStrategy else { throw VideoError.invalid("收益矩阵策略缺失") }
                        let choice: KnowledgeMatrixAction
                        switch strategy {
                        case .alwaysFirst: choice = .first
                        case .alwaysSecond: choice = .second
                        case .reciprocate:
                            choice = try previous.map { try action($0.actors[1 - index].choice) } ?? .first
                        case .winStayLoseShift:
                            if let previous {
                                let own = previous.actors[index], last = try action(own.choice)
                                choice = own.benefit >= own.cost ? last : last == .first ? .second : .first
                            } else { choice = .first }
                        case .alternate:
                            choice = (Int(seed % 2) + index + round - 1) % 2 == 0 ? .first : .second
                        }
                        var value = actor; value.choice = choice == .first ? .actionFirst : .actionSecond
                        return value
                    }
                case .contribution:
                    actors = try actors.map { actor in
                        guard actor.resources >= matrix.stake else { throw VideoError.invalid("收益矩阵押金不可透支") }
                        var value = actor; value.resources = try add(value.resources, -matrix.stake)
                        value.cost = matrix.stake; deposited = try add(deposited, matrix.stake)
                        return value
                    }
                    let available = try add(deposited, matrix.externalBudget)
                    pool = KnowledgeMatrixPool(available: available, distributed: 0, remainder: available)
                case .resolution:
                    _ = try matrix.cell(row: action(actors[0].choice), column: action(actors[1].choice))
                case .passage: break
                case .settlement:
                    let cell = try matrix.cell(row: action(actors[0].choice), column: action(actors[1].choice))
                    guard let funded = pool else { throw VideoError.invalid("收益矩阵缺少已实际入池的押金") }
                    let payouts = [cell.rowPayout, cell.columnPayout], distributed = try add(cell.rowPayout, cell.columnPayout)
                    guard distributed <= funded.available else { throw VideoError.invalid("收益矩阵不能发放超过当轮资金池的资源") }
                    actors = try actors.enumerated().map { index, actor in
                        var value = actor; value.benefit = payouts[index]; value.resources = try add(actor.resources, value.benefit)
                        guard (0...1_000_000).contains(value.resources) else { throw VideoError.invalid("收益矩阵结算超出参与者有限预算") }
                        return value
                    }
                    pool = KnowledgeMatrixPool(available: funded.available, distributed: distributed, remainder: try add(funded.available, -distributed))
                    completed.append(KnowledgeRoundResult(round: round, settledTick: tick, totalContribution: deposited,
                                                          obstacleCleared: false, actors: actors, matrixPool: pool))
                }
                events.append(KnowledgeEvent(tick: tick, round: round, phase: phase, actors: actors,
                                             totalContribution: deposited, threshold: 0, obstacleCleared: false, matrixPool: pool))
            }
        }
        return KnowledgeTrace(version: 2, inputDigest: try Codec.digest(Input(model: model, seed: seed)), seed: seed,
                              throughTick: throughTick, events: events, rounds: completed,
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
                                   threshold: event.threshold, obstacleCleared: event.obstacleCleared, matrixPool: event.matrixPool, ruleExecution: event.ruleExecution)
    }

    /// A causal comparison keeps the participant identities, round count and seed
    /// fixed. Both results are actually computed; supplied/old results are not reused.
    public static func compare(baseline: KnowledgeSimulation, alternative: KnowledgeSimulation, seed: UInt64) throws -> KnowledgeCounterfactual {
        try baseline.validate(); try alternative.validate()
        guard baseline.version == alternative.version,
              Set(baseline.participants.map(\.id)) == Set(alternative.participants.map(\.id)), baseline.rounds == alternative.rounds else {
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
    /// Frozen input-schema 2: its public-good contract must not gain matrix keys.
    private static let publicGoodRecords: [String: String] = [
        "KnowledgeSimulation": "version:i knowledgeLabel:s resourceLabel:s participants:[KnowledgeParticipant] rounds:i roundTicks:i startTick:i contributionCost:i contributionUnits:i threshold:i benefit:i",
        "KnowledgeParticipant": "id:s name:s strategy:KnowledgeStrategy initialResources:i",
        "KnowledgeActorState": "id:s resources:i choice?:KnowledgeChoice contribution:i cost:i benefit:i passed:b",
        "KnowledgeEvent": "tick:i round:i phase:KnowledgePhase actors:[KnowledgeActorState] totalContribution:i threshold:i obstacleCleared:b",
        "KnowledgeRoundResult": "round:i settledTick:i totalContribution:i obstacleCleared:b actors:[KnowledgeActorState]",
        "KnowledgeBalance": "id:s resources:i",
        "KnowledgeTrace": "version:i inputDigest:s seed:n throughTick:i events:[KnowledgeEvent] rounds:[KnowledgeRoundResult] finalResources:[KnowledgeBalance]"
    ]
    private static let publicGoodEnums: [String: [String]] = [
        "KnowledgeStrategy": KnowledgeStrategy.allCases.map(\.rawValue),
        "KnowledgeChoice": [KnowledgeChoice.contribute.rawValue, KnowledgeChoice.wait.rawValue, KnowledgeChoice.constrained.rawValue],
        "KnowledgePhase": KnowledgePhase.allCases.map(\.rawValue)
    ]
    public static var records: [String: String] { records(forInputSchemaVersion: 5) }
    public static var enums: [String: [String]] { enums(forInputSchemaVersion: 5) }
    public static func records(forInputSchemaVersion version: Int) -> [String: String] {
        guard version >= 3 else { return publicGoodRecords }
        var result = publicGoodRecords
        result["KnowledgeSimulation"]! += " payoffMatrix?:KnowledgePayoffMatrix"
        result["KnowledgeParticipant"]! += " matrixStrategy?:KnowledgeMatrixStrategy"
        result["KnowledgeEvent"]! += " matrixPool?:KnowledgeMatrixPool"
        result["KnowledgeRoundResult"]! += " matrixPool?:KnowledgeMatrixPool"
        result["KnowledgePayoffMatrix"] = "firstActionLabel:s secondActionLabel:s stake:i externalBudget:i cells:[KnowledgePayoffCell]"
        result["KnowledgePayoffCell"] = "rowAction:KnowledgeMatrixAction columnAction:KnowledgeMatrixAction rowPayout:i columnPayout:i"
        result["KnowledgeMatrixPool"] = "available:i distributed:i remainder:i"
        if version >= 5 {
            result["KnowledgeSimulation"]! += " ruleTable?:KnowledgeRuleTable"
            result["KnowledgeActorState"]! += " ruleStateID?:s requestedActionID?:s executedActionID?:s"
            result["KnowledgeEvent"]! += " ruleExecution?:KnowledgeRuleExecution"
            result["KnowledgeRoundResult"]! += " ruleExecution?:KnowledgeRuleExecution"
            result["KnowledgeRuleTable"] = "version:i actions:[KnowledgeRuleAction] states:[KnowledgeRuleState] plans:[KnowledgeRuleActorPlan] rules:[KnowledgeRule] initialPool:i externalBudgetPerRound:i"
            result["KnowledgeRuleAction"] = "id:s label:s cost:i pose:KnowledgeRulePose"
            result["KnowledgeRuleState"] = "id:s label:s pose:KnowledgeRulePose"
            result["KnowledgeRuleActorPlan"] = "actorID:s initialStateID:s defaultActionID:s cycleActionIDs:[s] decisions:[KnowledgeRuleDecision]"
            result["KnowledgeRuleDecision"] = "id:s priority:i conditions:[KnowledgeRuleCondition] actionID:s"
            result["KnowledgeRuleCondition"] = "kind:KnowledgeRuleConditionKind actorID?:s actionID?:s stateID?:s minimum?:i maximum?:i"
            result["KnowledgeRuleEffect"] = "kind:KnowledgeRuleEffectKind sourceActorID?:s destinationActorID?:s amount?:i actorID?:s stateID?:s"
            result["KnowledgeRule"] = "id:s label:s conditions:[KnowledgeRuleCondition] effects:[KnowledgeRuleEffect]"
            result["KnowledgeRuleFact"] = "conditionIndex:i actualNumber?:i actualID?:s"
            result["KnowledgeRuleMatch"] = "ruleID:s facts:[KnowledgeRuleFact]"
            result["KnowledgeRuleTransfer"] = "ruleID:s sourceActorID?:s destinationActorID?:s amount:i"
            result["KnowledgeRuleStateChange"] = "ruleID:s actorID:s beforeStateID:s afterStateID:s"
            result["KnowledgeRuleExecution"] = "poolBefore:i poolAfter:i externalFunding:i deposits:i matches:[KnowledgeRuleMatch] transfers:[KnowledgeRuleTransfer] stateChanges:[KnowledgeRuleStateChange]"
        }
        return result
    }
    public static func enums(forInputSchemaVersion version: Int) -> [String: [String]] {
        guard version >= 3 else { return publicGoodEnums }
        var result = publicGoodEnums
        result["KnowledgeChoice"]! += [KnowledgeChoice.actionFirst.rawValue, KnowledgeChoice.actionSecond.rawValue]
        result["KnowledgeMatrixAction"] = KnowledgeMatrixAction.allCases.map(\.rawValue)
        result["KnowledgeMatrixStrategy"] = KnowledgeMatrixStrategy.allCases.map(\.rawValue)
        if version >= 5 {
            result["KnowledgeRulePose"] = KnowledgeRulePose.allCases.map(\.rawValue)
            result["KnowledgeRuleConditionKind"] = KnowledgeRuleConditionKind.allCases.map(\.rawValue)
            result["KnowledgeRuleEffectKind"] = KnowledgeRuleEffectKind.allCases.map(\.rawValue)
        }
        return result
    }
}
