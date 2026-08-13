@testitem "Cash flows and NPV" tags = [:unit, :fast] begin
    investment = Investment(
        capex = 100.0,
        lifetime_years = 4,
        discount_rate = 0.0,
        capacity_fade = 0.0,
    )
    flows = cashflows(25.0, investment)
    @test flows == [-100.0, 25.0, 25.0, 25.0, 25.0]
    @test npv(flows, 0.0) ≈ 0.0

    # A positive discount rate must make the same flows worth less.
    @test npv(flows, 0.05) < 0
end

@testitem "Fade and escalation move savings in opposite directions" tags = [:unit, :fast] begin
    base = Investment(
        capex = 0.0,
        lifetime_years = 3,
        discount_rate = 0.0,
        capacity_fade = 0.0,
    )
    faded = Investment(
        capex = 0.0,
        lifetime_years = 3,
        discount_rate = 0.0,
        capacity_fade = 0.10,
    )
    escalating = Investment(
        capex = 0.0,
        lifetime_years = 3,
        discount_rate = 0.0,
        capacity_fade = 0.0,
        savings_escalation = 0.10,
    )
    @test sum(cashflows(100.0, faded)) < sum(cashflows(100.0, base))
    @test sum(cashflows(100.0, escalating)) > sum(cashflows(100.0, base))

    # The first year is never faded or escalated: it is the year the simulation measured.
    @test cashflows(100.0, faded)[2] ≈ 100.0
    @test cashflows(100.0, escalating)[2] ≈ 100.0
end

@testitem "IRR and payback on closed-form cases" tags = [:unit, :fast] begin
    # Flows that exactly return the capital over four years have a zero rate of return.
    @test irr([-100.0, 25.0, 25.0, 25.0, 25.0]) ≈ 0.0 atol = 1e-6
    @test payback([-100.0, 25.0, 25.0, 25.0, 25.0]) ≈ 4.0

    # Doubling the money in one year is a 100% return.
    @test irr([-100.0, 200.0]) ≈ 1.0 atol = 1e-6

    # Payback interpolates inside the year it happens.
    @test payback([-100.0, 50.0, 100.0]) ≈ 1.5

    # An investment that returns a little has a deeply negative but perfectly real IRR, and
    # never pays back.
    @test irr([-100.0, 1.0, 1.0]) < -0.8
    @test payback([-100.0, 1.0, 1.0]) == Inf

    # Flows that never turn positive have no IRR at all.
    @test isnan(irr([-100.0, -1.0, -1.0]))
end

@testitem "KPIs measure a case against a baseline" tags = [:unit, :fast] setup =
    [BillFixtures] begin
    result = BillFixtures.tiny_result()
    baseline = settle(result, BillFixtures.bare_contract(net_metering_fraction = 0.0))
    case = settle(result, BillFixtures.bare_contract(net_metering_fraction = 1.0))
    investment = Investment(capex = 1000.0, lifetime_years = 10, discount_rate = 0.03)

    metrics = kpis(baseline, case, investment)
    # The netted contract is cheaper, so switching to it saves money every year.
    @test metrics.annual_savings > 0
    @test metrics.npv > -investment.capex
    @test metrics.payback_years > 0
end
