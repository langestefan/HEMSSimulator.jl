@testitem "The capital recovery factor is the textbook annuity" tags = [:unit, :fast] begin
    # An annuity at rate r over n years: the factor turning a lump sum into equal payments.
    @test capital_recovery_factor(0.0, 10) ≈ 0.1
    @test capital_recovery_factor(0.04, 15) ≈ 0.04 / (1 - 1.04^-15)
    # Its reciprocal is the present-value factor the NPV path uses, so the two agree.
    @test 1 / capital_recovery_factor(0.04, 15) ≈ sum(1.04^-t for t = 1:15)
    @test_throws ArgumentError capital_recovery_factor(0.04, 0)
end

@testmodule LPHome begin
    using BatteryBusinessCase
    using Dates: DateTime

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 28)
    weather = synthetic_weather(grid, site; seed = 21)
    load = synthetic_load(grid; annual_kwh = 3000)
    prices = synthetic_prices(grid; seed = 23)
    home = HomeSystem(
        site = site,
        pv = [
            PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180),
        ],
    )
    contract(fraction) = Contract(
        grid;
        commodity = prices .+ 0.02,
        feed_in = 0.04,
        net_metering_fraction = fraction,
    )
    candidates(deg) = [Battery(kwh, kwh / 2; degradation_cost = deg) for kwh = 2.5:2.5:20.0]
    investment =
        b -> Investment(
            capex = 1000 + 450 * b.capacity_kwh,
            lifetime_years = 15,
            discount_rate = 0.04,
            capacity_fade = 0.0,
        )
end

@testitem "The sizing LP brackets the sweep from above" tags = [:integration, :slow] setup =
    [LPHome] begin
    # Like for like means the LP's template must not charge a degradation cost, because that is a
    # control-shaping term that never reaches a bill and so never reaches the sweep's savings.
    contract = LPHome.contract(0.0)
    bound = size_lp(
        LPHome.home,
        LPHome.weather,
        LPHome.load,
        contract;
        capex_per_kwh = 450.0,
        capex_fixed = 1000.0,
    )
    table = sweep(
        LPHome.home,
        LPHome.weather,
        LPHome.load,
        contract,
        LPHome.candidates(0.0);
        investment = LPHome.investment,
    )
    swept = table[argmax(table.npv), :capacity_kwh]

    @test !bound.at_bound
    @test bound.capacity_kwh >= swept - 1e-6
    @test bound.capacity_kwh < swept + 2.5      # and it is a useful bound, not a vacuous one
    @test bound.power_kw ≈ 0.5 * bound.capacity_kwh atol = 1e-6
    @test bound.capex ≈ 1000 + 450 * bound.capacity_kwh
end

@testitem "Charging the LP for wear the bill never sees under-sizes it" tags =
    [:integration, :slow] setup = [LPHome] begin
    contract = LPHome.contract(0.0)
    free = size_lp(LPHome.home, LPHome.weather, LPHome.load, contract)
    charged = size_lp(
        LPHome.home,
        LPHome.weather,
        LPHome.load,
        contract;
        template = Battery(1.0, 1.0; degradation_cost = 0.05),
    )
    @test charged.capacity_kwh < free.capacity_kwh
    # This is the documented trap, not a bug: it is why the bound is quoted with the template's
    # degradation cost at zero.
    @test charged.capacity_kwh < 4.0 < free.capacity_kwh
end

@testitem "Full netting is where the LP shows its teeth" tags = [:integration, :slow] setup =
    [LPHome] begin
    # Under *salderen* an exported kWh is worth a retail kWh, tax and VAT included, so the spread
    # the optimizer sees is the retail spread — inflated by 21% VAT on top of a 10 ct/kWh levy.
    # With nothing charged for wear the LP will happily buy an absurd battery to arbitrage it. This
    # is the pathology `degradation_cost` exists for, and here it is, quantified.
    free = size_lp(LPHome.home, LPHome.weather, LPHome.load, LPHome.contract(1.0))
    @test free.capacity_kwh > 20.0

    # Five cents a kWh of throughput is enough to make the whole idea uneconomic.
    charged = size_lp(
        LPHome.home,
        LPHome.weather,
        LPHome.load,
        LPHome.contract(1.0);
        template = Battery(1.0, 1.0; degradation_cost = 0.05),
    )
    @test charged.capacity_kwh < 1e-6

    # Without netting the answer is a real battery either way, and far less sensitive.
    plain = size_lp(
        LPHome.home,
        LPHome.weather,
        LPHome.load,
        LPHome.contract(0.0);
        template = Battery(1.0, 1.0; degradation_cost = 0.05),
    )
    @test 1.0 < plain.capacity_kwh < 10.0
end

@testitem "The sizing LP refuses to size around existing storage" tags = [:unit, :fast] setup =
    [LPHome] begin
    occupied = with_assets(LPHome.home, [Battery(5.0, 2.5)])
    @test_throws ArgumentError size_lp(
        occupied,
        LPHome.weather,
        LPHome.load,
        LPHome.contract(0.0),
    )
end
