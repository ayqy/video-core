import Foundation

/// A view of already applied engine results. This schedule never settles rules,
/// changes balances, or adds fields to a recorded trace or module input.
public enum KnowledgePresentationSchedule {
    public struct GateOpeningMoment: Equatable, Sendable {
        public let phaseStartFrame: Int
        public let sourceFrame: Int

        /// Opening must still be visible in the same actual resolution. A
        /// compressed presentation cannot move its sound into passage or a
        /// later round, nor replay it when a slice starts after this onset.
        public func isVisible(atSourceFrame frame: Int, fps: Int) -> Bool {
            guard (1...120).contains(fps), frame >= sourceFrame,
                  frame >= phaseStartFrame, frame - phaseStartFrame < fps else { return false }
            return true
        }
    }

    /// The optional four-cell shared gate and its sound use this same visual
    /// schedule. Applied clearing is observed, never inferred from deposits.
    public static func publicGoodGateStep(state: KnowledgeFrameState) throws -> Int {
        guard state.phaseProgress.isFinite, (0...1).contains(state.phaseProgress) else {
            throw VideoError.invalid("实际开门进度无效")
        }
        guard state.obstacleCleared else { return 0 }
        switch state.phase {
        case .resolution: return min(3, Int((state.phaseProgress * 4).rounded(.down)))
        case .passage, .settlement: return 3
        default: return 0
        }
    }

    public static func publicGoodGateOpening(event: KnowledgeEvent, fps: Int = 30) throws -> GateOpeningMoment? {
        guard (1...120).contains(fps), (0...1800).contains(event.tick) else {
            throw VideoError.invalid("实际开门声音的刻度或帧率无效")
        }
        guard event.phase == .resolution, event.obstacleCleared,
              event.matrixPool == nil, event.ruleExecution == nil else { return nil }
        // frameState divides integer elapsed frames by fps. At low or odd
        // rates, select the first representable non-closed cell, not a rounded
        // midpoint or the resolution's still-closed first frame.
        for offset in 0..<fps {
            let state = KnowledgeFrameState(tick: event.tick, round: event.round, phase: event.phase,
                phaseProgress: Double(offset) / Double(fps), actors: event.actors,
                totalContribution: event.totalContribution, threshold: event.threshold,
                obstacleCleared: event.obstacleCleared)
            if try publicGoodGateStep(state: state) > 0 {
                return GateOpeningMoment(phaseStartFrame: event.tick * fps, sourceFrame: event.tick * fps + offset)
            }
        }
        // At fps 1, resolution has only its still-closed frame. Leave manual
        // audio available rather than invent a resolution onset in passage.
        return nil
    }

    public struct Flow: Equatable, Sendable {
        public enum Kind: String, Sendable { case deposit, transfer }
        public let kind: Kind
        public let sourceActorID: String?
        public let destinationActorID: String?
        public let amount: Int
        /// Identical applied routes are merged before this identity is used.
        public var id: String {
            kind.rawValue + ":" + (sourceActorID.map { "actor=" + $0 } ?? "pool") + ":" +
                (destinationActorID.map { "actor=" + $0 } ?? "pool")
        }
    }
    public struct Encounter: Equatable, Sendable {
        public let flow: Flow
        public let index: Int
        public let total: Int
        public let progress: Double
    }
    public struct FlowMoment: Equatable, Sendable {
        public let flow: Flow
        public let index: Int
        public let total: Int
        public let phaseStartFrame: Int
        public let sourceFrame: Int
        public let sequential: Bool

        /// A retimed shot may sample a different integer source frame. It must
        /// still show this exact handoff, rather than the next route or phase.
        public func isVisible(atSourceFrame frame: Int, fps: Int) -> Bool {
            guard (1...120).contains(fps), frame >= phaseStartFrame,
                  frame - phaseStartFrame < fps else { return false }
            guard sequential else { return true }
            let scaled = Double(frame - phaseStartFrame) * Double(total) / Double(fps)
            let visibleIndex = min(total - 1, Int(scaled.rounded(.down)))
            return visibleIndex == index && (0.35...0.65).contains(scaled - Double(visibleIndex))
        }
    }

    public static func ruleFlows(state: KnowledgeFrameState) -> [Flow] {
        guard state.ruleExecution != nil else { return [] }
        if state.phase == .contribution {
            return state.actors.filter { $0.executedActionID != nil && $0.cost > 0 }
                .sorted { $0.id < $1.id }
                .map { Flow(kind: .deposit, sourceActorID: $0.id, destinationActorID: nil, amount: $0.cost) }
        }
        guard state.phase == .settlement else { return [] }
        struct Route: Hashable { let source: String?, destination: String? }
        var totals: [Route: Int] = [:]
        // Engine validation caps the entire conserved resource supply at one
        // million units. Matching conditions alone never create a route.
        for transfer in state.ruleExecution?.transfers ?? [] where transfer.amount > 0 {
            totals[Route(source: transfer.sourceActorID, destination: transfer.destinationActorID), default: 0] += transfer.amount
        }
        return totals.sorted { a, b in
            let left = (a.key.source ?? "") + "\u{0}" + (a.key.destination ?? "")
            let right = (b.key.source ?? "") + "\u{0}" + (b.key.destination ?? "")
            return left < right
        }.map { Flow(kind: .transfer, sourceActorID: $0.key.source, destinationActorID: $0.key.destination, amount: $0.value) }
    }

    public static func matrixFlows(state: KnowledgeFrameState) -> [Flow] {
        guard state.matrixPool != nil else { return [] }
        if state.phase == .contribution {
            return state.actors.filter { $0.cost > 0 }.sorted { $0.id < $1.id }
                .map { Flow(kind: .deposit, sourceActorID: $0.id, destinationActorID: nil, amount: $0.cost) }
        }
        if state.phase == .settlement {
            return state.actors.filter { $0.benefit > 0 }.sorted { $0.id < $1.id }
                .map { Flow(kind: .transfer, sourceActorID: nil, destinationActorID: $0.id, amount: $0.benefit) }
        }
        return []
    }

    public static func encounter(state: KnowledgeFrameState) throws -> Encounter? {
        guard state.phaseProgress.isFinite, (0...1).contains(state.phaseProgress) else {
            throw VideoError.invalid("实际交接进度无效")
        }
        let flows = ruleFlows(state: state)
        guard !flows.isEmpty else { return nil }
        let scaled = state.phaseProgress * Double(flows.count)
        let index = min(flows.count - 1, Int(scaled.rounded(.down)))
        return Encounter(flow: flows[index], index: index, total: flows.count,
                         progress: min(1, scaled - Double(index)))
    }

    /// Rule-table routes use the same sequential encounter as the game camera;
    /// matrix routes travel in parallel. Sounds target their visible midpoint.
    public static func flowMoments(event: KnowledgeEvent, fps: Int = 30) throws -> [FlowMoment] {
        guard (1...120).contains(fps), (0...1800).contains(event.tick) else {
            throw VideoError.invalid("实际交接声音的刻度或帧率无效")
        }
        let state = KnowledgeFrameState(tick: event.tick, round: event.round, phase: event.phase, phaseProgress: 0,
            actors: event.actors, totalContribution: event.totalContribution, threshold: event.threshold,
            obstacleCleared: event.obstacleCleared, matrixPool: event.matrixPool, ruleExecution: event.ruleExecution)
        let sequential = event.ruleExecution != nil
        let flows = sequential ? ruleFlows(state: state) : matrixFlows(state: state)
        return try flows.enumerated().map { index, flow in
            let center = sequential ? (Double(index) + 0.5) / Double(flows.count) : 0.5
            let offset = min(fps - 1, Int((center * Double(fps)).rounded()))
            let moment = FlowMoment(flow: flow, index: index, total: flows.count, phaseStartFrame: event.tick * fps,
                                    sourceFrame: event.tick * fps + offset, sequential: sequential)
            guard moment.isVisible(atSourceFrame: moment.sourceFrame, fps: fps) else {
                throw VideoError.review("单个源阶段的实际交接过密，当前帧率无法逐项显示交接声音；请调整模型阶段或帧率后重新录制，不会把声音移到其他交接")
            }
            return moment
        }
    }
}
