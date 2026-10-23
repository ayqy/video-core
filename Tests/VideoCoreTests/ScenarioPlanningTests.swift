import XCTest
@testable import VideoCore

final class ScenarioPlanningTests: XCTestCase {
    private func decimal(_ value: String) -> Decimal { Decimal(string: value)! }
    private func portfolio() -> ScenarioPlan {
        var plan = ScenarioPlan(); plan.courses[3].quantity = 50; plan.toolEnabled = true; plan.brandEnabled = true
        return plan
    }
    func testSeventyCourseOrdersReachOnlySingleMonthTarget() throws {
        let result = try ScenarioPlanning.evaluate(ScenarioPlan())
        XCTAssertEqual(result.courseContribution, 11508); XCTAssertEqual(result.sharedCashCost, 1500)
        XCTAssertEqual(result.operatingSurplus, 10008); XCTAssertEqual(result.operatingHours, decimal("90.5"))
        XCTAssertEqual(result.targetReached, true); XCTAssertEqual(result.capacityExceeded, false)
        XCTAssertEqual(result.incentiveContribution, 0); XCTAssertTrue(ScenarioPlanning.notice.contains("不保证稳定"))
    }
    func testOrderDownsideDoesNotClaimStableTenThousand() throws {
        var plan = ScenarioPlan(); plan.courses[3].quantity = 49
        let result = try ScenarioPlanning.evaluate(plan)
        XCTAssertEqual(result.operatingSurplus, decimal("6555.60")); XCTAssertEqual(result.operatingHours, decimal("87.35"))
        XCTAssertEqual(result.targetReached, false)
    }
    func testPortfolioSharesCostsOnceAndSeparatesDevelopmentAndOpportunityCost() throws {
        let result = try ScenarioPlanning.evaluate(portfolio())
        XCTAssertEqual(result.courseContribution, 8220); XCTAssertEqual(result.toolContribution, decimal("1561.9")); XCTAssertEqual(result.brandContribution, 4260)
        XCTAssertEqual(result.incentiveContribution, 0); XCTAssertEqual(result.sharedCashCost, 1500); XCTAssertEqual(result.additionalToolCash, 1000)
        XCTAssertEqual(result.operatingSurplus, decimal("11541.90")); XCTAssertEqual(result.operatingHours, decimal("131.5"))
        XCTAssertEqual(result.economicProfit, decimal("-1608.1")); XCTAssertEqual(result.developmentHours, 40); XCTAssertEqual(result.developmentEconomicCost, 5000)
        XCTAssertNil(result.developmentMonthlyRecovery); XCTAssertNil(result.afterDevelopmentRecovery)
    }
    func testPriceMixUsesExactUnroundedPerOrderContribution() throws {
        var plan = ScenarioPlan(); plan.courses[1].quantity = 24; plan.courses[2].quantity = 61; plan.courses[3].quantity = 37
        XCTAssertEqual(try ScenarioPlanning.evaluate(plan).operatingSurplus, decimal("10094.083"))
    }
    func testDifferentPlatformFeesSettlementAndAcquisitionBudgetChangeCalculatedResult() throws {
        var plan = ScenarioPlan(); plan.courses[3].platformRate = decimal("0.15"); plan.courses[3].settlementRate = decimal("0.06")
        XCTAssertEqual(try ScenarioPlanning.evaluate(plan).operatingSurplus, decimal("7765.2"))
        plan = ScenarioPlan(); plan.courses[3].quantity = 100; plan.courses[3].acquisitionCash = 50
        XCTAssertEqual(try ScenarioPlanning.evaluate(plan).operatingSurplus, 9940)
        plan.courses[3].quantity = 101; XCTAssertEqual(try ScenarioPlanning.evaluate(plan).targetReached, true)
    }
    func testUnknownActiveFeesAreUnknownButZeroQuantityDoesNotInventRevenue() throws {
        var plan = ScenarioPlan(); plan.courses[3].platformRate = nil
        let unknown = try ScenarioPlanning.evaluate(plan)
        XCTAssertNil(unknown.courseContribution); XCTAssertNil(unknown.operatingSurplus); XCTAssertNil(unknown.targetReached)
        XCTAssertTrue(unknown.unknownInputs.contains("课程槽位4平台费比例"))
        plan.courses[3].quantity = 0
        let empty = try ScenarioPlanning.evaluate(plan)
        XCTAssertEqual(empty.courseContribution, 0); XCTAssertEqual(empty.operatingSurplus, -1500)
    }
    func testUnknownHoursDoNotBecomeZeroOrEraseKnownCashCalculation() throws {
        var plan = ScenarioPlan(); plan.courses[3].serviceHours = nil
        let result = try ScenarioPlanning.evaluate(plan)
        XCTAssertEqual(result.operatingSurplus, 10008); XCTAssertNil(result.operatingHours); XCTAssertNil(result.economicProfit); XCTAssertNil(result.capacityExceeded)
    }
    func testIncentiveExcludedUnknownRpmAndVerifiedReceiptStayDistinct() throws {
        var plan = ScenarioPlan(); plan.incentiveMode = .unknown
        XCTAssertNil(try ScenarioPlanning.evaluate(plan).incentiveContribution); XCTAssertNil(try ScenarioPlanning.evaluate(plan).operatingSurplus)
        plan.incentiveMode = .rpm; plan.incentiveViews = 1000000; plan.incentiveRPM = decimal("0.5")
        XCTAssertEqual(try ScenarioPlanning.evaluate(plan).incentiveContribution, 450)
        plan.incentiveMode = .settlement; plan.incentiveSettlement = 25
        XCTAssertThrowsError(try ScenarioPlanning.evaluate(plan))
        plan.incentiveReceipt = "isolated-known-reference"
        XCTAssertEqual(try ScenarioPlanning.evaluate(plan).operatingSurplus, 10033)
    }
    func testSubscriptionChurnRoundsRequiredReplacementsWithoutDuplicatingPaidActiveIncome() throws {
        var plan = ScenarioPlan(); plan.toolEnabled = true; plan.toolSubscription = true
        plan.tool.quantity = 395; plan.tool.price = 49; plan.tool.serviceCash = 8; plan.tool.serviceHours = decimal("0.05")
        let five = try ScenarioPlanning.evaluate(plan); XCTAssertEqual(five.requiredReplacementSubscribers, 20)
        plan.toolChurnRate = decimal("0.15")
        let fifteen = try ScenarioPlanning.evaluate(plan); XCTAssertEqual(fifteen.requiredReplacementSubscribers, 60)
        XCTAssertEqual(five.toolContribution, fifteen.toolContribution)
        plan.toolChurnRate = nil; XCTAssertNil(try ScenarioPlanning.evaluate(plan).requiredReplacementSubscribers)
    }
    func testEnabledZeroSaleToolRouteStillPaysItsFixedCashAndHours() throws {
        var plan = ScenarioPlan(); plan.courses[3].quantity = 0; plan.toolEnabled = true; plan.tool.quantity = 0
        let result = try ScenarioPlanning.evaluate(plan)
        XCTAssertEqual(result.operatingSurplus, -2500); XCTAssertEqual(result.operatingHours, 100)
    }
    func testFullRefundRetainsPlatformCostAndCapacityOverflowIsVisible() throws {
        var plan = ScenarioPlan(); plan.courses[3].refundRate = 1
        XCTAssertLessThan(try XCTUnwrap(ScenarioPlanning.evaluate(plan).courseContribution), 0)
        plan = ScenarioPlan(); plan.courses[3].quantity = 0; plan.courses[0].quantity = 18054
        let result = try ScenarioPlanning.evaluate(plan)
        XCTAssertEqual(result.operatingHours, decimal("441.08")); XCTAssertEqual(result.capacityExceeded, true)
    }
    func testDevelopmentAmortizationIsExplicitAndLeavesOperatingHoursUntouched() throws {
        var plan = portfolio(); plan.amortizeDevelopment = true
        let result = try ScenarioPlanning.evaluate(plan)
        XCTAssertEqual(result.developmentMonthlyRecovery, Decimal(5000) / 6)
        XCTAssertEqual(result.afterDevelopmentRecovery, decimal("11541.9") - Decimal(5000) / 6)
        XCTAssertEqual(result.operatingHours, decimal("131.5")); XCTAssertEqual(result.operatingSurplus, decimal("11541.9"))
        plan.developmentRecoveryMonths = 0; XCTAssertThrowsError(try ScenarioPlanning.evaluate(plan))
    }
    func testActualUnknownBaselineAndCannibalizationAreNotSilentlyZeroed() throws {
        var plan = ScenarioPlan(); plan.existingSurplus = 5000; plan.cannibalizedContribution = 600
        XCTAssertEqual(try ScenarioPlanning.evaluate(plan).operatingSurplus, 14408)
        plan.existingSurplus = nil; XCTAssertNil(try ScenarioPlanning.evaluate(plan).operatingSurplus)
    }
    func testInvalidRatesAmountsCountsAndCurrencyAreRejectedWithoutExchange() throws {
        var plan = ScenarioPlan(); plan.courses[3].taxReserveRate = decimal("1.1"); XCTAssertThrowsError(try ScenarioPlanning.evaluate(plan))
        plan = ScenarioPlan(); plan.brandEnabled = true; plan.brandQuantity = -1; XCTAssertThrowsError(try ScenarioPlanning.evaluate(plan))
        plan = ScenarioPlan(); plan.runningCash = .nan; XCTAssertThrowsError(try ScenarioPlanning.evaluate(plan))
        plan = ScenarioPlan(); plan.hourlyOpportunityCost = Decimal(string: String(repeating: "9", count: 38) + "e127")
        plan.developmentHours = 0; plan.developmentCash = 0; XCTAssertThrowsError(try ScenarioPlanning.evaluate(plan))
        plan = ScenarioPlan(); plan.currency = "CNY/USD"; XCTAssertThrowsError(try ScenarioPlanning.evaluate(plan))
        plan.currency = "EUR"; let result = try ScenarioPlanning.evaluate(plan); XCTAssertEqual(result.currency, "EUR"); XCTAssertEqual(result.operatingSurplus, 10008)
    }
}
