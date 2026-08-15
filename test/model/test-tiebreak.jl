@testitem "the tie-break makes the optimum unique across solvers" tags =
    [:integration, :fast] begin
    using Dates: DateTime, Minute
    using JuMP: optimizer_with_attributes, value
    using HiGHS: HiGHS

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 6, 1), 96 * 4)
    # Step-holding an hourly price onto quarter-hours is what creates the ties: four consecutive
    # intervals cost exactly the same, so when to charge is a coin flip for the optimizer.
    hourly = synthetic_prices(TimeGrid(DateTime(2024, 6, 1), Minute(60), 24 * 4))
    prices = resample(
        StepHold(),
        timestamps(TimeGrid(DateTime(2024, 6, 1), Minute(60), 24 * 4)),
        hourly,
        grid,
    )
    weather = synthetic_weather(grid, site; seed = 5)
    load = synthetic_load(grid; annual_kwh = 3500)
    contract = Contract(
        grid;
        commodity = prices .+ 0.02,
        feed_in = 0.04,
        net_metering_fraction = 0.0,
    )
    home = HomeSystem(
        site = site,
        pv = [
            PVArray(dc_capacity_kwp = 5.0, ac_capacity_kw = 4.5, tilt = 35, azimuth = 180),
        ],
        assets = AbstractAsset[
            ElectricVehicle(
                grid;
                capacity_kwh = 60.0,
                charge_power_kw = 11.0,
                km_per_day = 40,
            ),
            Battery(10.0, 5.0),
        ],
    )
    settings(; tie_break, optimizer = HiGHS.Optimizer, direct = true) = RunOptions(;
        window_hours = 24,
        step_hours = 1.0,
        terminal_value = false,
        tie_break,
        optimizer,
        direct,
    )
    presolve_off = optimizer_with_attributes(HiGHS.Optimizer, "presolve" => "off")

    with = simulate(home, weather, load, contract; options = settings(tie_break = 1e-6))
    other = simulate(
        home,
        weather,
        load,
        contract;
        options = settings(tie_break = 1e-6, optimizer = presolve_off),
    )
    # Two solver settings, one answer. This is the property the tie-break exists to give.
    @test with.frame.import_kw ≈ other.frame.import_kw atol = 1e-6
    @test settle(with, contract).total ≈ settle(other, contract).total atol = 1e-6

    @test maximum(abs, balance_residual(with)) < 1e-9

    # It is a tie-break, not a thumb on the scale — but that has to be checked on a *single* window
    # from a *single* starting state. Comparing whole runs would not show it: a receding horizon
    # feeds each window's solution into the next as its initial state, so picking a different tie in
    # window one puts window two in a different place and the trajectories diverge from there. The
    # totals then differ by far more than the tie-break term could ever contribute, in either
    # direction. That compounding is exactly why solver choice moved an annual bill by EUR 0.51.
    inputs = prepare(home, weather, load, contract; options = settings(tie_break = 1e-6))
    states = [initial_state(a) for a in home.assets]
    len = round(Int, 24 / hours(grid))
    dispatch_cost(tie) = begin
        options = settings(tie_break = tie)
        ctx = HEMSSimulator.DispatchContext(
            HEMSSimulator.window(grid, 1, len),
            hours(grid),
            HEMSSimulator.window(inputs, 1, len),
            options,
            1,
        )
        vars, _, _ = solve_window(home, ctx, states)
        dt = hours(grid)
        sum(
            dt * (
                ctx.inputs.price_buy[k] * value(vars.imported[k]) -
                ctx.inputs.price_sell[k] * value(vars.exported[k])
            ) for k = 1:len
        )
    end
    @test dispatch_cost(1e-6) ≈ dispatch_cost(0.0) atol = 1e-6
end

@testitem "tie_break is a run option with a documented default" tags = [:unit, :fast] begin
    @test RunOptions().tie_break == 1.0e-6
    @test RunOptions(tie_break = 0.0).tie_break == 0.0
end
