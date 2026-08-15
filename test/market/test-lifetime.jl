@testitem "effective_lifetime takes the shorter of calendar and cycles" tags = [:unit, :fast] begin
    inv = Investment(capex = 2400.0, lifetime_years = 15, rated_cycles = 4000.0)

    @test effective_lifetime(inv, 334.1) ≈ 4000 / 334.1        # worked hard: cycles bind
    @test effective_lifetime(inv, 228.6) == 15.0               # worked gently: calendar binds
    @test effective_lifetime(inv, 4000 / 15) ≈ 15.0            # exactly at the crossover

    # Opt-in: without a rating, or without a cycle count, only the calendar applies. This is what
    # keeps every existing study's numbers unchanged.
    plain = Investment(capex = 2400.0, lifetime_years = 15)
    @test effective_lifetime(plain, 334.1) == 15.0
    @test effective_lifetime(inv, nothing) == 15.0
    @test effective_lifetime(inv, NaN) == 15.0                 # no battery in the system
    @test effective_lifetime(inv, 0.0) == 15.0                 # a battery that never cycles
end

@testitem "cashflows pro-rate the final part year" tags = [:unit, :fast] begin
    inv = Investment(
        capex = 1000.0,
        lifetime_years = 15,
        rated_cycles = 1000.0,
        capacity_fade = 0.0,
    )

    # 1000 cycles at 400 a year is 2.5 years: two whole years and a half.
    flows = cashflows(100.0, inv; cycles_per_year = 400.0)
    @test length(flows) == 4
    @test flows == [-1000.0, 100.0, 100.0, 50.0]

    # No cliff: a hair either side of a whole year differs by a hair, not by a year of savings.
    just_under = cashflows(100.0, inv; cycles_per_year = 1000 / 2.999)
    just_over = cashflows(100.0, inv; cycles_per_year = 1000 / 3.001)
    @test sum(just_over) - sum(just_under) ≈ 0.2 atol = 0.01

    # A whole number of years leaves no part year behind.
    @test cashflows(100.0, inv; cycles_per_year = 500.0) == [-1000.0, 100.0, 100.0]

    # The residual value still lands in the final year, whether or not that year is a part one.
    with_residual = Investment(
        capex = 1000.0,
        lifetime_years = 15,
        rated_cycles = 1000.0,
        capacity_fade = 0.0,
        residual_value = 60.0,
    )
    @test cashflows(100.0, with_residual; cycles_per_year = 400.0)[end] == 50.0 + 60.0
end

@testitem "a cycle rating penalises the candidates that work hardest" tags = [:unit, :fast] begin
    using Dates: DateTime

    # Two candidates saving the same per year, one cycling twice as hard. Without a rating they are
    # worth the same; with one, the hard-worked one is worth less — which is the whole point.
    inv = Investment(
        capex = 2000.0,
        lifetime_years = 15,
        discount_rate = 0.0,
        rated_cycles = 3000.0,
    )
    gentle = npv(cashflows(300.0, inv; cycles_per_year = 150.0), 0.0)
    hard = npv(cashflows(300.0, inv; cycles_per_year = 400.0), 0.0)
    @test hard < gentle

    unrated = Investment(capex = 2000.0, lifetime_years = 15, discount_rate = 0.0)
    @test npv(cashflows(300.0, unrated; cycles_per_year = 150.0), 0.0) ==
          npv(cashflows(300.0, unrated; cycles_per_year = 400.0), 0.0)
end

@testitem "kpis reports the lifetime it actually used" tags = [:integration, :fast] begin
    using Dates: DateTime

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 3)
    weather = synthetic_weather(grid, site; seed = 3)
    load = synthetic_load(grid; annual_kwh = 3500)
    contract = Contract(grid; commodity = synthetic_prices(grid) .+ 0.02, feed_in = 0.04)
    home = HomeSystem(
        site = site,
        pv = [PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180)],
        assets = AbstractAsset[],
    )
    options = RunOptions(window_hours = 24, step_hours = 6, terminal_value = false)
    bare = settle(simulate(home, weather, load, contract; options), contract)

    battery = Battery(10.0, 5.0)
    with = with_assets(home, [battery])
    result = simulate(with, weather, load, contract; options)
    case = settle(result, contract)

    # A rating low enough to bind whatever this week's cycling turns out to be.
    inv = Investment(capex = 4400.0, lifetime_years = 15, rated_cycles = 10.0)
    k = kpis(bare, case, inv; result)
    @test k.lifetime_years ≈ 10.0 / k.cycles_per_year
    @test k.lifetime_years < 15.0

    # And without a result there is nothing to bind on, so the calendar stands.
    @test kpis(bare, case, inv).lifetime_years == 15.0
end
