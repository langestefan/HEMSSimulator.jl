@testitem "recourse reproduces the solver under a perfect forecast" tags = [:unit, :fast] begin
    using Dates
    # The whole forecast layer rests on this: with nothing to be wrong about, the flows written by
    # `recourse!` must be the ones the optimizer itself returned. If they are not, every comparison
    # between a perfect and an imperfect forecast is measuring the recourse policy rather than the
    # value of knowing.
    grid = TimeGrid(DateTime(2024, 6, 1), 96 * 4)
    weather = synthetic_weather(grid, Site(52.1, 5.2); seed = 3)
    load = synthetic_load(grid; annual_kwh = 3500.0)
    prices = synthetic_prices(grid; seed = 5)
    # Tax and VAT on import only, so an exported kWh is worth much less than an imported one and
    # self-consumption is what the battery is for. With a narrow spread the battery idles, forecast
    # error costs nothing, and the test passes while proving nothing.
    contract = Contract(
        grid;
        commodity = prices .+ 0.0205,
        feed_in = prices .+ 0.0205,
        energy_tax = 0.0916,
        net_metering_fraction = 0.0,
    )
    system = HomeSystem(
        site = Site(52.1, 5.2),
        pv = [PVArray(dc_capacity_kwp = 6.0, ac_capacity_kw = 5.4, tilt = 35, azimuth = 180)],
        assets = AbstractAsset[Battery(10.0, 5.0)],
    )
    options = RunOptions(window_hours = 24, step_hours = 0.25, terminal_value = false)
    result = simulate(system, weather, load, contract; options)

    # Rebuilt from the truth rather than read from the solver, so agreement is a real check.
    @test maximum(abs, balance_residual(result)) < 1e-8
    @test all(>=(-1e-9), result.frame.import_kw)
    @test all(>=(-1e-9), result.frame.export_kw)
    @test all(>=(-1e-9), result.frame.curtail_kw)
    # Curtailment can never exceed what the array offered.
    @test all(result.frame.curtail_kw .<= result.frame.pv_available_kw .+ 1e-9)
end

@testitem "a noisy forecast costs money but keeps the books" tags = [:unit, :fast] begin
    using Dates
    grid = TimeGrid(DateTime(2024, 6, 1), 96 * 4)
    weather = synthetic_weather(grid, Site(52.1, 5.2); seed = 3)
    load = synthetic_load(grid; annual_kwh = 3500.0)
    prices = synthetic_prices(grid; seed = 5)
    # Tax and VAT on import only, so an exported kWh is worth much less than an imported one and
    # self-consumption is what the battery is for. With a narrow spread the battery idles, forecast
    # error costs nothing, and the test passes while proving nothing.
    contract = Contract(
        grid;
        commodity = prices .+ 0.0205,
        feed_in = prices .+ 0.0205,
        energy_tax = 0.0916,
        net_metering_fraction = 0.0,
    )
    system = HomeSystem(
        site = Site(52.1, 5.2),
        pv = [PVArray(dc_capacity_kwp = 6.0, ac_capacity_kw = 5.4, tilt = 35, azimuth = 180)],
        assets = AbstractAsset[Battery(10.0, 5.0)],
    )
    options = RunOptions(window_hours = 24, step_hours = 0.25, terminal_value = false)
    perfect = simulate(system, weather, load, contract; options)
    guessed = simulate(
        system,
        weather,
        load,
        contract;
        options,
        forecast = NoisyForecast(pv_sigma = 0.3, load_sigma = 0.4, seed = 7),
    )

    # The accounting must survive being wrong: whatever the controller believed, the meter balances.
    @test maximum(abs, balance_residual(guessed)) < 1e-8
    @test all(guessed.frame.curtail_kw .<= guessed.frame.pv_available_kw .+ 1e-9)
    # Acting on a worse belief cannot beat acting on the truth, up to solver noise.
    @test annualise(settle(guessed, contract)) >= annualise(settle(perfect, contract)) - 1e-6
    # And it must actually change the battery's behaviour, or the forecast is not being applied.
    @test guessed.frame.battery_charge_kw != perfect.frame.battery_charge_kw
end

@testitem "forecast error shrinks as the interval approaches" tags = [:unit, :fast] begin
    using Dates
    using Statistics: mean
    grid = TimeGrid(DateTime(2024, 6, 1), 96 * 2)
    weather = synthetic_weather(grid, Site(52.1, 5.2); seed = 3)
    load = synthetic_load(grid; annual_kwh = 3500.0)
    prices = synthetic_prices(grid; seed = 5)
    # Tax and VAT on import only, so an exported kWh is worth much less than an imported one and
    # self-consumption is what the battery is for. With a narrow spread the battery idles, forecast
    # error costs nothing, and the test passes while proving nothing.
    contract = Contract(
        grid;
        commodity = prices .+ 0.0205,
        feed_in = prices .+ 0.0205,
        energy_tax = 0.0916,
        net_metering_fraction = 0.0,
    )
    system = HomeSystem(
        site = Site(52.1, 5.2),
        pv = [PVArray(dc_capacity_kwp = 6.0, ac_capacity_kw = 5.4, tilt = 35, azimuth = 180)],
    )
    inputs = prepare(system, weather, load, contract)
    f = NoisyForecast(pv_sigma = 0.3, load_sigma = 0.3, seed = 11)
    believed = forecast_window(f, inputs, 1, 96)
    truth = HEMSSimulator.window(inputs, 1, 96)
    # The interval being implemented now is metered, not predicted.
    @test believed.load_kw[1] ≈ truth.load_kw[1]
    # A day out, it is not.
    early = mean(abs.(believed.load_kw[1:8] .- truth.load_kw[1:8]))
    late = mean(abs.(believed.load_kw[89:96] .- truth.load_kw[89:96]))
    @test late > early
    # Prices are known in this market and must be passed through untouched.
    @test believed.price_buy == truth.price_buy
    @test believed.price_sell == truth.price_sell
end

@testitem "a perfect forecast leaves the cache key untouched" tags = [:unit, :fast] begin
    using Dates
    # Reflection over `RunOptions` means a new *field* invalidates every cached simulation in
    # existence, and this package has studies with thousands of annual solves behind them. The
    # forecast is therefore a `simulate` argument rather than an option, and contributes to the
    # digest only when it is not the default — so keys written before forecasts existed still hit.
    grid = TimeGrid(DateTime(2024, 6, 1), 96)
    weather = synthetic_weather(grid, Site(52.1, 5.2); seed = 3)
    load = synthetic_load(grid; annual_kwh = 3500.0)
    prices = synthetic_prices(grid; seed = 5)
    contract = Contract(grid; commodity = prices, feed_in = prices .- 0.05)
    system = HomeSystem(
        site = Site(52.1, 5.2),
        pv = [PVArray(dc_capacity_kwp = 6.0, ac_capacity_kw = 5.4, tilt = 35, azimuth = 180)],
        assets = AbstractAsset[Battery(10.0, 5.0)],
    )
    options = RunOptions(window_hours = 24, step_hours = 0.25)
    inputs = prepare(system, weather, load, contract; options)
    @test simulation_key(system, inputs, options) ==
          simulation_key(system, inputs, options, PerfectForecast())
    @test simulation_key(system, inputs, options) !=
          simulation_key(system, inputs, options, NoisyForecast())
    # Two different forecasts must not collide either.
    @test simulation_key(system, inputs, options, NoisyForecast(seed = 1)) !=
          simulation_key(system, inputs, options, NoisyForecast(seed = 2))
end
