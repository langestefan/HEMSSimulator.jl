@testitem "A full year, end to end" tags = [:integration, :slow] begin
    using Dates: DateTime
    using DataFrames: nrow

    # The milestone-1 acceptance criterion, and the only test that runs the horizon the package is
    # actually for. A fortnight annualised can produce almost any optimum; a year cannot. It also
    # carries the two physical sanity checks that need a whole year to mean anything, so the
    # expensive baseline simulation is paid for once.
    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 1, 1), DateTime(2025, 1, 1))
    weather = synthetic_weather(grid, site; seed = 21)
    load = synthetic_load(grid; annual_kwh = 3500)
    prices = synthetic_prices(grid; seed = 23)
    home = HomeSystem(
        site = site,
        pv = [
            PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180),
        ],
    )
    contract = Contract(
        grid;
        commodity = prices .+ 0.02,
        feed_in = 0.04,
        net_metering_fraction = 0.0,
    )
    inputs = prepare(home, weather, load, contract)

    @test length(grid) == 366 * 96      # 2024 is a leap year

    # A Dutch home with PV and no storage self-consumes about 30% of what it generates. This is the
    # cross-check the plan asked for: it is a property of the load shape against the solar day, and
    # it falls out of the model rather than being fitted, so it is worth pinning.
    baseline = simulate(home, inputs)
    @test 0.20 < self_consumption(baseline) < 0.40
    @test 0.20 < self_sufficiency(baseline) < 0.40
    @test 3000 < produced_kwh(baseline) < 4000       # ~900 kWh/kWp from 4 kWp
    @test consumed_kwh(baseline) ≈ 3500 rtol = 0.02
    @test maximum(abs, balance_residual(baseline)) < 1e-9

    candidates = [Battery(kwh, kwh / 2; degradation_cost = 0.05) for kwh = 2.5:2.5:20.0]
    table = sweep(
        home,
        inputs,
        contract,
        candidates;
        investment = b -> Investment(
            capex = 1000 + 450 * b.capacity_kwh,
            lifetime_years = 15,
            discount_rate = 0.04,
        ),
    )

    @test nrow(table) == length(candidates)
    @test table.capacity_kwh == collect(2.5:2.5:20.0)
    @test all(table.annual_savings .> 0)
    @test issorted(table.annual_savings)
    @test all(0 .<= table.self_consumption .<= 1)
    @test all(0 .<= table.self_sufficiency .<= 1)
    @test all(table.cycles_per_year .> 0)

    # Storage raises self-consumption sharply and then saturates, which is why NPV turns over.
    @test table.self_consumption[1] > self_consumption(baseline)
    @test issorted(table.self_consumption)

    # The optimum is interior, so the candidate grid brackets it and `best` does not warn. An
    # optimum on the boundary would mean the answer is "wider than anything tested".
    optimum = argmax(table.npv)
    @test 1 < optimum < nrow(table)
    winner = best(table)
    @test winner.capacity_kwh == table.capacity_kwh[optimum]
    @test winner.npv > 0
    @test 5 < winner.payback_years < 15
    # Beyond the optimum the extra capacity costs more than it saves.
    @test table.npv[end] < winner.npv
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

@testitem "Threading a sweep changes the wall clock, not the answer" tags =
    [:integration, :slow] begin
    using Dates: DateTime
    using DataFrames: nrow

    # Candidates are independent, so the only thing that can go wrong is a shared mutable. There is
    # none: each candidate builds its own model and solver, and rows are written by index. This
    # asserts that, and it is meaningful even on one thread because it also pins determinism.
    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 14)
    weather = synthetic_weather(grid, site; seed = 21)
    load = synthetic_load(grid; annual_kwh = 3000)
    prices = synthetic_prices(grid; seed = 23)
    home = HomeSystem(
        site = site,
        pv = [
            PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180),
        ],
    )
    contract = Contract(
        grid;
        commodity = prices .+ 0.02,
        feed_in = 0.04,
        net_metering_fraction = 0.0,
    )
    candidates = [Battery(kwh, kwh / 2; degradation_cost = 0.05) for kwh = 2.5:2.5:10.0]
    investment = b -> Investment(capex = 1000 + 450 * b.capacity_kwh)

    serial = sweep(home, weather, load, contract, candidates; investment, threaded = false)
    parallel = sweep(home, weather, load, contract, candidates; investment, threaded = true)

    @test nrow(serial) == nrow(parallel) == length(candidates)
    @test serial.capacity_kwh == parallel.capacity_kwh
    for column in (:annual_savings, :npv, :annual_bill, :cycles_per_year, :self_consumption)
        @test serial[!, column] ≈ parallel[!, column]
    end
end

@testitem "Savings per kWh is what ranks the sizes" tags = [:integration, :slow] begin
    using Dates: DateTime

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 14)
    weather = synthetic_weather(grid, site; seed = 21)
    load = synthetic_load(grid; annual_kwh = 3000)
    prices = synthetic_prices(grid; seed = 23)
    home = HomeSystem(
        site = site,
        pv = [
            PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180),
        ],
    )
    contract = Contract(
        grid;
        commodity = prices .+ 0.02,
        feed_in = 0.04,
        net_metering_fraction = 0.0,
    )
    candidates = [Battery(kwh, kwh / 2; degradation_cost = 0.05) for kwh = 2.5:2.5:15.0]

    table = sweep(
        home,
        weather,
        load,
        contract,
        candidates;
        investment = b -> Investment(capex = 1000 + 450 * b.capacity_kwh),
    )

    @test table.savings_per_kwh ≈ table.annual_savings ./ table.capacity_kwh
    # Total savings rise steeply and then saturate — they never say when to stop, and past the
    # saturation point they can even tick down as the degradation cost outweighs the last kWh of
    # arbitrage. The per-kWh figure falls monotonically, and that is the one that ranks sizes.
    @test table.annual_savings[end] > table.annual_savings[1]
    @test issorted(table.savings_per_kwh; rev = true)
    @test table.savings_per_kwh[1] > 2 * table.savings_per_kwh[end]
end
