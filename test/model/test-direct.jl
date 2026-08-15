@testitem "direct mode changes the speed, not the answer" tags = [:integration, :fast] begin
    using Dates: DateTime

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 6, 3), 96 * 4)
    weather = synthetic_weather(grid, site; seed = 19)
    load = synthetic_load(grid; annual_kwh = 3500)
    contract = Contract(
        grid;
        commodity = synthetic_prices(grid) .+ 0.02,
        feed_in = 0.04,
        net_metering_fraction = 0.0,
    )
    home = HomeSystem(
        site = site,
        pv = [PVArray(dc_capacity_kwp = 5.0, ac_capacity_kw = 4.5, tilt = 35, azimuth = 180)],
        assets = [
            Battery(10.0, 5.0; degradation_cost = 0.02),
            ElectricVehicle(grid; capacity_kwh = 60.0, charge_power_kw = 11.0, km_per_day = 40),
        ],
    )
    settings(direct) =
        RunOptions(window_hours = 24, step_hours = 6, terminal_value = false, direct = direct)

    fast = simulate(home, weather, load, contract; options = settings(true))
    cached = simulate(home, weather, load, contract; options = settings(false))

    # Every flow, not just the totals: `direct_model` skips the MOI caching layer, and skipping a
    # layer that only stores a copy must not move a single number.
    @test names(fast.frame) == names(cached.frame)
    for column in names(fast.frame)
        eltype(fast.frame[!, column]) <: Real || continue
        @test fast.frame[!, column] ≈ cached.frame[!, column] atol = 1e-9
    end
    @test settle(fast, contract).total ≈ settle(cached, contract).total atol = 1e-9
    @test maximum(abs, balance_residual(fast)) < 1e-9
end

@testitem "direct mode is the default and can be turned off" tags = [:unit, :fast] begin
    @test RunOptions().direct
    @test !RunOptions(direct = false).direct
end
