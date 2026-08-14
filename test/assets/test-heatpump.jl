@testmodule WinterHome begin
    using BatteryBusinessCase
    using Dates: DateTime

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 1, 8), 96 * 7)     # a January week: heating actually happens
    weather = synthetic_weather(grid, site; seed = 31)
    load = synthetic_load(grid; annual_kwh = 3000)
    prices = synthetic_prices(grid; seed = 33)
    contract = Contract(
        grid;
        commodity = prices .+ 0.02,
        feed_in = 0.04,
        net_metering_fraction = 0.0,
    )
    pv = [PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180)]

    make_hp(; kwargs...) = HeatPump(
        grid;
        building = BuildingSpec(120.0; heat_loss_kw = 6.0),
        setpoint = 20.0,
        band = 1.0,
        max_power_kw = 4.0,
        kwargs...,
    )
    home_with(assets) = HomeSystem(site = site, pv = pv, assets = assets)
    run(hp) = simulate(home_with([hp]), weather, load, contract)
end

@testitem "A heat pump validates what it was given" tags = [:unit, :fast] begin
    using Dates: DateTime

    grid = TimeGrid(DateTime(2024, 1, 1), 96)
    building = BuildingSpec(120.0)

    @test_throws ArgumentError HeatPump(grid; building, control = :clairvoyant)
    @test_throws ArgumentError HeatPump(grid; building, band = -1.0)
    @test_throws ArgumentError HeatPump(grid; building, max_power_kw = 0.0)
    # A scalar setpoint is expanded; a series of the wrong length is refused.
    @test length(HeatPump(grid; building, setpoint = 20.0).setpoint) == 96
    @test_throws ArgumentError HeatPump(grid; building, setpoint = fill(20.0, 10))
end

@testitem "The comfort band is held, and it is the flexibility" tags = [:integration, :slow] setup =
    [WinterHome] begin
    hp = WinterHome.make_hp()
    result = WinterHome.run(hp)
    indoor = result.frame.indoor_temp

    @test all(19.0 - 1e-6 .<= indoor .<= 21.0 + 1e-6)
    @test discomfort_kh(result) < 1e-6
    @test maximum(abs, balance_residual(result)) < 1e-9
    # The temperature is genuinely used as storage rather than pinned to the setpoint.
    @test maximum(indoor) - minimum(indoor) > 0.5
    @test heat_demand_kwh(result) > 0
    @test all(0 .<= result.frame.heatpump_kw .<= hp.max_power_kw + 1e-9)
end

@testitem "Optimising the temperature beats a thermostat" tags = [:integration, :slow] setup =
    [WinterHome] begin
    # The headline claim of the heat pump model. Two effects, and they are separable: the optimizer
    # buys fewer kWh (it heats when the COP is better and does not overshoot the band), and it buys
    # them cheaper (it heats when electricity is cheap). Neither is available to a controller that
    # only knows the current indoor temperature.
    dumb = WinterHome.run(WinterHome.make_hp(control = :thermostat))
    smart = WinterHome.run(WinterHome.make_hp(control = :optimized))

    dt = hours(WinterHome.grid)
    cost(r) = sum(r.frame.heatpump_kw .* r.frame.price_buy) * dt

    @test heat_demand_kwh(smart) < heat_demand_kwh(dumb)
    @test cost(smart) < 0.85 * cost(dumb)
    # Cheaper per kWh as well as fewer of them.
    @test cost(smart) / heat_demand_kwh(smart) < cost(dumb) / heat_demand_kwh(dumb)

    # The thermostat overshoots the band, because the emitter keeps giving off heat after it
    # switches off. That is the lag the third RC node exists to represent.
    @test maximum(dumb.frame.indoor_temp) > 21.0
    @test discomfort_kh(dumb; side = :warm) > discomfort_kh(smart; side = :warm)
end

@testitem "Thermostat mode runs exactly the rule-based controller" tags =
    [:integration, :slow] setup = [WinterHome] begin
    hp = WinterHome.make_hp(control = :thermostat)
    result = WinterHome.run(hp)

    # The first window is the one that starts from the declared initial state, so its profile can
    # be reproduced from `thermostat_profile` alone.
    window = 96                                     # the implemented step, 24 h
    expected = thermostat_profile(
        hp,
        initial_state(hp),
        hp.setpoint[1:window],
        WinterHome.weather.t_amb[1:window],
        WinterHome.weather.ghi[1:window],
        hours(WinterHome.grid),
    )
    @test result.frame.heatpump_kw[1:window] ≈ expected

    # It is bang-bang: full power or nothing.
    @test all(p -> p ≈ 0 || p ≈ hp.max_power_kw, result.frame.heatpump_kw)
end

@testitem "An undersized heat pump reports discomfort, not infeasibility" tags =
    [:integration, :slow] setup = [WinterHome] begin
    # A cold week and a 0.6 kW heat pump cannot hold 20 °C. A hard comfort constraint would come
    # back as `INFEASIBLE`, which tells the user nothing about how badly or when. The band is soft
    # and priced, so the run completes and the shortfall is a number of degree-hours.
    weak = WinterHome.run(WinterHome.make_hp(max_power_kw = 0.6))

    @test discomfort_kh(weak) > 1.0
    @test minimum(weak.frame.indoor_temp) < 19.0
    @test all(isfinite, weak.frame.indoor_temp)
    # It still runs flat out; it simply cannot keep up.
    @test maximum(weak.frame.heatpump_kw) ≈ 0.6 atol = 1e-6
end

@testitem "A setback is a change to the setpoint, not to the model" tags =
    [:integration, :slow] setup = [WinterHome] begin
    using Dates: Dates

    # Night setback: 17 °C between 23:00 and 06:00, 20 °C otherwise.
    times = timestamps(WinterHome.grid)
    setpoint = [(Dates.hour(t) >= 23 || Dates.hour(t) < 6) ? 17.0 : 20.0 for t in times]
    setback = WinterHome.run(WinterHome.make_hp(setpoint = setpoint))
    steady = WinterHome.run(WinterHome.make_hp())

    @test heat_demand_kwh(setback) < heat_demand_kwh(steady)
    @test minimum(setback.frame.indoor_temp) < minimum(steady.frame.indoor_temp)
    # Nobody is cold: the house is always at or above the setback band.
    @test discomfort_kh(setback; side = :cold) < 1e-6
    # But it is unavoidably *above* the band for a while every night, because 120 m² of masonry at
    # 20 °C does not fall to 18 °C the moment the setpoint does. That is physics, not a fault.
    @test discomfort_kh(setback; side = :warm) > 1.0
    @test discomfort_kh(steady; side = :warm) < 1e-6
end

@testitem "The heat pump reports its flows like any other asset" tags =
    [:integration, :slow] setup = [WinterHome] begin
    @test consumption_columns(WinterHome.make_hp()) == [:heatpump_kw]
    @test production_columns(WinterHome.make_hp()) == Symbol[]

    result = simulate(
        WinterHome.home_with([
            WinterHome.make_hp(),
            Battery(10.0, 5.0),
            ElectricVehicle(
                WinterHome.grid;
                capacity_kwh = 60.0,
                charge_power_kw = 11.0,
                km_per_day = 45,
            ),
        ]),
        WinterHome.weather,
        WinterHome.load,
        WinterHome.contract,
    )

    @test maximum(abs, balance_residual(result)) < 1e-9
    @test hasproperty(result.frame, :indoor_temp)
    @test hasproperty(result.frame, :emitter_temp)
    @test 0 <= self_sufficiency(result) <= 1
    # The emitter is warmer than the room whenever heat is flowing into it.
    running = result.frame.heatpump_kw .> 1e-6
    @test all(
        result.frame.emitter_temp[running] .>= result.frame.indoor_temp[running] .- 1e-6,
    )
end

@testitem "A setpoint shorter than the run is caught" tags = [:unit, :fast] setup =
    [WinterHome] begin
    using Dates: DateTime

    short = TimeGrid(DateTime(2024, 1, 8), 96 * 2)
    hp = HeatPump(short; building = BuildingSpec(120.0), setpoint = 20.0)
    @test_throws ArgumentError WinterHome.run(hp)
end
