import XCTest
@testable import VideoCore

final class KnowledgePresentationScheduleTests:XCTestCase {
    private func model()->KnowledgeSimulation {
        KnowledgeSimulation(knowledgeLabel:"交付条件",participants:[
            .init(id:"a",name:"甲",strategy:.contribute,initialResources:10),
            .init(id:"b",name:"乙",strategy:.contribute,initialResources:10)
        ],rounds:1,ruleTable:KnowledgeRuleTable(actions:[.init(id:"act",label:"交付",cost:1)],
            states:[.init(id:"open",label:"等待")],
            plans:["a","b"].map{.init(actorID:$0,initialStateID:"open",defaultActionID:"act")},
            rules:[.init(id:"one",label:"原子交付",conditions:[.init(kind:.round,minimum:1,maximum:1)],
                effects:[.transfer(from:"b",to:"a",amount:2),.transfer(from:"a",to:"b",amount:1),
                         .transfer(from:"b",to:"a",amount:1)])]))
    }
    private func event(_ phase:KnowledgePhase,model:KnowledgeSimulation?=nil)throws->KnowledgeEvent {
        try XCTUnwrap(KnowledgeSimulationEngine.record(model:model ?? self.model(),seed:7,throughTick:KnowledgePhase.allCases.firstIndex(of:phase)!).events.first{$0.phase==phase})
    }
    func testOnlyAppliedRoutesAreMergedWithoutLosingAmountOrDirection()throws {
        let outcome=try event(.settlement),before=try event(.resolution)
        XCTAssertEqual(outcome.ruleExecution?.transfers.count,3)
        let flows=try KnowledgePresentationSchedule.flowMoments(event:outcome).map(\.flow)
        XCTAssertEqual(flows.map{$0.sourceActorID!+"→"+$0.destinationActorID!},["a→b","b→a"])
        XCTAssertEqual(flows.map(\.amount),[1,3]);XCTAssertEqual(Set(flows.map(\.id)).count,2)
        XCTAssertFalse(try XCTUnwrap(before.ruleExecution).matches.isEmpty)
        XCTAssertTrue(try KnowledgePresentationSchedule.flowMoments(event:before).isEmpty)
    }
    func testSequentialSoundCentersSelectTheSameActualGameEncounter()throws {
        let actual=try event(.settlement),moments=try KnowledgePresentationSchedule.flowMoments(event:actual)
        XCTAssertEqual(moments.map(\.sourceFrame),[158,173])
        for moment in moments {
            let state=try KnowledgeSimulationEngine.frameState(model:model(),seed:7,frame:moment.sourceFrame)
            let encounter=try XCTUnwrap(KnowledgePresentationSchedule.encounter(state:state))
            XCTAssertEqual(encounter.flow,moment.flow);XCTAssertEqual(encounter.index,moment.index)
            XCTAssertTrue((0.35...0.65).contains(encounter.progress))
            XCTAssertTrue(moment.isVisible(atSourceFrame:moment.sourceFrame,fps:30))
            XCTAssertFalse(moment.isVisible(atSourceFrame:actual.tick*30,fps:30))
            XCTAssertFalse(moment.isVisible(atSourceFrame:180,fps:30))
        }
        XCTAssertEqual(try KnowledgePresentationSchedule.flowMoments(event:actual),moments)
    }
    func testRequestAndConstrainedActorNeverProduceDeposit()throws {
        var input=model();input.participants[0].initialResources=0
        XCTAssertTrue(try KnowledgePresentationSchedule.flowMoments(event:event(.decision,model:input)).isEmpty)
        let moments=try KnowledgePresentationSchedule.flowMoments(event:event(.contribution,model:input))
        XCTAssertEqual(moments.map{$0.flow.sourceActorID},["b"])
        XCTAssertEqual(moments.map(\.sourceFrame),[75]);XCTAssertEqual(moments.map{$0.flow.amount},[1])
    }
    func testZeroCostAndStateOnlyEffectsNeverInventAResourceHandoff()throws {
        var input=model();input.ruleTable?.actions[0].cost=0
        input.ruleTable?.states.append(.init(id:"done",label:"完成",pose:.celebrate))
        input.ruleTable?.rules[0].effects=[.setState(actorID:"a",stateID:"done")]
        let action=try event(.contribution,model:input),settled=try event(.settlement,model:input)
        XCTAssertTrue(action.actors.allSatisfy{$0.executedActionID=="act"})
        XCTAssertEqual(settled.ruleExecution?.stateChanges.count,1)
        XCTAssertTrue(try KnowledgePresentationSchedule.flowMoments(event:action).isEmpty)
        XCTAssertTrue(try KnowledgePresentationSchedule.flowMoments(event:settled).isEmpty)
    }
    func testMatrixRoutesShareParallelMidpointWithoutBecomingSequentialTrade()throws {
        let input=KnowledgeSimulation(knowledgeLabel:"双方结算",participants:[
            .init(id:"a",name:"甲",strategy:.contribute,initialResources:20,matrixStrategy:.alwaysFirst),
            .init(id:"b",name:"乙",strategy:.contribute,initialResources:20,matrixStrategy:.alwaysFirst)
        ],rounds:1,payoffMatrix:.prisonersDilemma())
        let outcome=try event(.settlement,model:input),moments=try KnowledgePresentationSchedule.flowMoments(event:outcome)
        XCTAssertEqual(moments.count,2);XCTAssertEqual(moments.map(\.sourceFrame),[165,165])
        XCTAssertTrue(moments.allSatisfy{!$0.sequential && $0.flow.sourceActorID==nil})
        let state=try KnowledgeSimulationEngine.frameState(model:input,seed:7,frame:165)
        XCTAssertNil(try KnowledgePresentationSchedule.encounter(state:state))
        XCTAssertEqual(moments.map(\.flow),KnowledgePresentationSchedule.matrixFlows(state:state))
    }
    func testUnrepresentableHandoffAndInvalidTimingRejectWithoutMovingTheEvent()throws {
        let actual=try event(.settlement)
        XCTAssertThrowsError(try KnowledgePresentationSchedule.flowMoments(event:actual,fps:1))
        XCTAssertThrowsError(try KnowledgePresentationSchedule.flowMoments(event:actual,fps:0))
        var invalid=actual;invalid.tick=Int.max
        XCTAssertThrowsError(try KnowledgePresentationSchedule.flowMoments(event:invalid))
        var state=try KnowledgeSimulationEngine.frameState(model:model(),seed:7,frame:165)
        state.phaseProgress = .nan
        XCTAssertThrowsError(try KnowledgePresentationSchedule.encounter(state:state))
    }
    func testScheduleObservationDoesNotChangeRecordedBytesOrInputDigest()throws {
        let trace=try KnowledgeSimulationEngine.record(model:model(),seed:7,throughTick:5),bytes=try Codec.data(trace)
        for event in trace.events {_ = try KnowledgePresentationSchedule.flowMoments(event:event)}
        XCTAssertEqual(try Codec.data(trace),bytes)
        try KnowledgeSimulationEngine.verify(trace,model:model(),seed:7)
    }
}
