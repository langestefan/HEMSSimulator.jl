@testitem "Sweep tabulates a business case per candidate" tags = [:integration, :slow] begin
    using Dates: DateTime
    using DataFrames: nrow

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 14)
    weather = synthetic_weather(grid, site; seed = 21)
    load = synthetic_load(grid; annual_kwh = 3500)
    prices = synthetic_prices(grid; seed = 23)
    contract = Contract(
        grid;
        commodity = prices .+ 0.02,
        feed_in = 0.04,
        net_metering_fraction = 0.0,
    )
    home = HomeSystem(
        site = site,
        pv = [
            PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180),
        ],
    )

    candidates = [Battery(kwh, kwh / 2) for kwh in (2.5, 5.0, 10.0)]
    table = sweep(
        home,
        weather,
        load,
        contract,
        candidates;
        investment = b -> Investment(capex = 500 + 500 * b.capacity_kwh),
    )

    @test nrow(table) == 3
    @test table.capacity_kwh == [2.5, 5.0, 10.0]
    # A bigger battery saves more but costs more; savings must be positive and monotone in size.
    @test all(table.annual_savings .> 0)
    @test issorted(table.annual_savings)
    @test all(0 .<= table.self_consumption .<= 1)
    @test all(0 .<= table.self_sufficiency .<= 1)
    @test all(table.cycles_per_year .> 0)
end

@testitem "Sizing optimum at the edge of the grid is flagged" tags = [:unit, :fast] begin
    using DataFrames: DataFrame

    table = DataFrame(npv = [1.0, 5.0, 3.0])
    @test best(table).npv == 5.0

    rising = DataFrame(npv = [1.0, 2.0, 9.0])
    @test_logs (:warn, r"edge of the candidate range") best(rising)
end

@testitem "A scenario sweep stacks one block per regime" tags = [:integration, :slow] begin
    using Dates: DateTime
    using DataFrames: nrow

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 14)
    weather = synthetic_weather(grid, site; seed = 21)
    load = synthetic_load(grid; annual_kwh = 3500)
    prices = synthetic_prices(grid; seed = 23)
    home = HomeSystem(
        site = site,
        pv = [
            PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180),
        ],
    )
    regimes = scenarios(grid; commodity = prices .+ 0.02, feed_in = 0.04)
    candidates = [Battery(kwh, kwh / 2; degradation_cost = 0.05) for kwh in (2.5, 5.0, 7.5)]

    table = sweep(
        home,
        weather,
        load,
        regimes,
        candidates;
        investment = b -> Investment(capex = 1000 + 450 * b.capacity_kwh),
    )

    @test nrow(table) == 4 * 3
    @test unique(table.scenario) == collect(SCENARIO_NAMES)
    @test all(table.annual_savings .> 0)

    winners = best_by_scenario(table)
    @test nrow(winners) == 4
    @test unique(winners.scenario) == collect(SCENARIO_NAMES)
    @test_throws ArgumentError best_by_scenario(table[!, [:capacity_kwh, :npv]])
end

@testitem "The two policy axes move battery savings independently" tags =
    [:integration, :slow] begin
    using Dates: DateTime

    # The headline result the four scenarios exist to show. The axes are not two versions of one
    # lever: netting absorbs the commodity price and the energy tax, while transport is charged on
    # physical flow and is never netted. So a time-of-use tariff pays a battery whether or not
    # netting applies, ending netting is the larger effect, and the two compound.
    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 14)
    weather = synthetic_weather(grid, site; seed = 21)
    load = synthetic_load(grid; annual_kwh = 3500)
    prices = synthetic_prices(grid; seed = 23)
    home = HomeSystem(
        site = site,
        pv = [
            PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180),
        ],
    )
    regimes = scenarios(grid; commodity = prices .+ 0.02, feed_in = 0.04)
    candidates = [Battery(5.0, 2.5; degradation_cost = 0.05)]

    table = sweep(
        home,
        weather,
        load,
        regimes,
        candidates;
        investment = b -> Investment(capex = 1000 + 450 * b.capacity_kwh),
    )
    savings = Dict(zip(table.scenario, table.annual_savings))

    # Time-of-use transport pays, in both netting regimes.
    @test savings[:netting_variable] > 1.1 * savings[:netting_fixed]
    @test savings[:no_netting_variable] > 1.1 * savings[:no_netting_fixed]
    # Ending netting is the bigger of the two levers.
    @test savings[:no_netting_fixed] > 1.3 * savings[:netting_fixed]
    @test savings[:no_netting_variable] > 1.3 * savings[:netting_variable]
    # And they compound, which is what makes the fourth cell worth simulating separately.
    @test savings[:no_netting_variable] == maximum(values(savings))
    @test savings[:netting_fixed] == minimum(values(savings))
end

@testitem "An EV removes the saturation that caps battery size" tags = [:integration, :slow] begin
    using Dates: DateTime

    # Without other flexible load a home battery runs out of work: past a point there is no more
    # PV surplus or price spread left for extra capacity to capture, and annual savings flatten.
    # A car is a large, shiftable load, and it keeps the marginal kWh of storage earning. That is
    # why sizing a battery for a household that will buy an EV, without modelling the EV, is the
    # optimistic mistake — it understates what the larger battery would do.
    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 14)
    weather = synthetic_weather(grid, site; seed = 21)
    load = synthetic_load(grid; annual_kwh = 3000)
    prices = synthetic_prices(grid; seed = 23)
    pv = [PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180)]
    contract = Contract(
        grid;
        commodity = prices .+ 0.02,
        feed_in = 0.04,
        net_metering_fraction = 0.0,
    )
    candidates = [Battery(kwh, kwh / 2; degradation_cost = 0.05) for kwh = 2.5:2.5:15.0]
    investment = b -> Investment(capex = 1000 + 450 * b.capacity_kwh)

    plain = sweep(
        HomeSystem(site = site, pv = pv),
        weather,
        load,
        contract,
        candidates;
        investment,
    )
    ev = ElectricVehicle(grid; capacity_kwh = 60.0, charge_power_kw = 11.0, km_per_day = 45)
    with_car = sweep(
        HomeSystem(site = site, pv = pv, assets = [ev]),
        weather,
        load,
        contract,
        candidates;
        investment,
    )

    # Same candidates, and the sweep keeps the car in both arms, so these are like for like.
    @test with_car.capacity_kwh == plain.capacity_kwh
    @test plain.annual_savings[end] < 1.02 * plain.annual_savings[4]
    @test with_car.annual_savings[end] > 1.15 * with_car.annual_savings[4]
end
