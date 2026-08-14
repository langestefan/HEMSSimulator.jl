@testitem "The draw profile carries the right amount of water" tags = [:unit, :fast] begin
    using Dates: Dates, DateTime

    grid = TimeGrid(DateTime(2024, 1, 8), 96 * 7)
    draw = dhw_draw(grid; litres_per_day = 120.0, setpoint_c = 60.0, cold_inlet_c = 10.0)

    per_day = 120.0 * WATER_KWH_PER_LITRE_K * 50.0
    @test length(draw) == grid.n
    @test all(>=(0), draw)
    @test sum(draw) ≈ 7 * per_day
    for day = 0:6
        @test sum(draw[(day*96+1):(day*96+96)]) ≈ per_day
    end

    # Two peaks where people wash, not a flat trickle.
    times = timestamps(grid)
    morning = findall(t -> Dates.hour(t) == 7, times)
    small_hours = findall(t -> Dates.hour(t) == 3, times)
    @test sum(draw[morning]) > 10 * sum(draw[small_hours])
    @test 0.35 < sum(draw[findall(t -> Dates.hour(t) < 12, times)]) / sum(draw) < 0.6

    # Half a day at the end of the horizon gets half a day's water, not a whole one.
    partial = dhw_draw(TimeGrid(DateTime(2024, 1, 8), 96 + 48); litres_per_day = 120.0)
    @test sum(partial[97:end]) ≈ per_day * 48 / 96

    @test_throws ArgumentError dhw_draw(grid; morning_share = 1.5)
    @test_throws ArgumentError dhw_draw(grid; setpoint_c = 10.0, cold_inlet_c = 10.0)
end

@testitem "Tank capacity is water, temperature and nothing else" tags = [:unit, :fast] begin
    using Dates: DateTime

    grid = TimeGrid(DateTime(2024, 1, 8), 96)
    tank = WaterTank(grid; volume_litre = 200.0, setpoint_c = 60.0, cold_inlet_c = 10.0)

    @test tank_capacity_kwh(tank) ≈ 200 * WATER_KWH_PER_LITRE_K * 50
    @test tank_capacity_kwh(tank) ≈ 11.63 atol = 0.01
    @test tank_reserve_kwh(tank) ≈ 200 * WATER_KWH_PER_LITRE_K * 35
    @test initial_state(tank) ≈ 0.8 * tank_capacity_kwh(tank)
    # A bigger tank holds more; a hotter one holds more still.
    @test tank_capacity_kwh(WaterTank(grid; volume_litre = 300.0)) >
          tank_capacity_kwh(tank)

    @test_throws ArgumentError WaterTank(grid; volume_litre = 0.0)
    @test_throws ArgumentError WaterTank(grid; minimum_c = 70.0)
    @test_throws ArgumentError WaterTank(grid; max_power_kw = 0.0)
    @test_throws ArgumentError WaterTank(; draw_kwh = [-1.0])
end

@testmodule TankHome begin
    using BatteryBusinessCase
    using Dates: DateTime

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 1, 8), 96 * 7)
    weather = synthetic_weather(grid, site; seed = 31)
    load = synthetic_load(grid; annual_kwh = 2500)
    prices = synthetic_prices(grid; seed = 33)
    contract = Contract(
        grid;
        commodity = prices .+ 0.02,
        feed_in = 0.04,
        net_metering_fraction = 0.0,
    )
    pv = [PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180)]

    make_tank(; kwargs...) = WaterTank(grid; litres_per_day = 120.0, kwargs...)
    home_with(assets) = HomeSystem(site = site, pv = pv, assets = assets)
    run(assets) = simulate(home_with(assets), weather, load, contract)
end

@testitem "The tank stays hot and reheats when power is cheap" tags =
    [:integration, :slow] setup = [TankHome] begin
    using Statistics: mean

    tank = TankHome.make_tank()
    result = TankHome.run([tank])
    stored = result.frame.dhw_energy_kwh

    @test dhw_shortfall_kwh(result) < 1e-6
    @test dhw_unserved_kwh(result) < 1e-6
    @test all(stored .>= tank_reserve_kwh(tank) - 1e-6)
    @test all(stored .<= tank_capacity_kwh(tank) + 1e-6)
    @test maximum(abs, balance_residual(result)) < 1e-9
    @test all(0 .<= result.frame.dhw_kw .<= tank.max_power_kw + 1e-9)

    # The whole reason to model it: a few kWh of store facing a large daily price swing.
    charge = result.frame.dhw_kw
    paid = sum(charge .* result.frame.price_buy) / sum(charge)
    @test paid < 0.9 * mean(result.frame.price_buy)
end

@testitem "Every kWh drawn was heated, and some was lost standing" tags =
    [:integration, :slow] setup = [TankHome] begin
    tank = TankHome.make_tank()
    result = TankHome.run([tank])

    drawn = sum(tank.draw_kwh)
    electric = dhw_energy_kwh(result)
    stored = result.frame.dhw_energy_kwh[end] - initial_state(tank)

    # Heat in must cover the draw, the change in store, and the standing loss on top.
    heat_in = sum(
        result.frame.dhw_kw[k] *
        BatteryBusinessCase.cop(tank.cop_model, TankHome.weather.t_amb[k]) for
        k = 1:TankHome.grid.n
    ) * hours(TankHome.grid)
    @test heat_in > drawn + stored
    @test heat_in ≈ drawn + stored + (heat_in - drawn - stored)   # standing loss is the remainder
    losses = heat_in - drawn - stored
    @test 0 < losses < 0.25 * drawn
    # Reaching 60 °C is dear: the effective COP is well below a space-heating one.
    @test 1.5 < heat_in / electric < 3.5
end

@testitem "A tank that cannot keep up says so" tags =
    [:integration, :slow] setup = [TankHome] begin
    # It takes a lot to break a tank: 0.3 kW is only 18 kWh of heat a day, but a normal 120 L
    # household needs 7, and the store buffers the morning peak. Four hundred litres a day is more
    # than the element can make. A hard reserve would be infeasible; the soft one reports the kWh.
    weak = TankHome.run([
        TankHome.make_tank(max_power_kw = 0.3, litres_per_day = 400.0),
    ])

    @test dhw_shortfall_kwh(weak) > 0.1
    # Not just lukewarm: the tank empties and some of the draw is simply not delivered.
    @test dhw_unserved_kwh(weak) > 0.1
    @test minimum(weak.frame.dhw_energy_kwh) < tank_reserve_kwh(TankHome.make_tank())
    @test all(isfinite, weak.frame.dhw_energy_kwh)
    @test maximum(weak.frame.dhw_kw) ≈ 0.3 atol = 1e-6

    # A normal element keeps up comfortably, which is why the failing case had to be built.
    normal = TankHome.run([TankHome.make_tank(max_power_kw = 0.3)])
    @test dhw_shortfall_kwh(normal) < 1e-6
    @test dhw_unserved_kwh(normal) < 1e-6
end

@testitem "A resistive tank is the same model with COP one" tags =
    [:integration, :slow] setup = [TankHome] begin
    # `cop_min` matters here: the models clamp to 1.5 by default, which would make this "resistive"
    # tank a poor heat pump instead of an element.
    element = TankHome.make_tank(
        cop_model = LinearCOP(reference = 1.0, slope = 0.0, cop_min = 1.0),
    )
    heatpump = TankHome.make_tank()

    resistive = TankHome.run([element])
    pumped = TankHome.run([heatpump])

    @test dhw_shortfall_kwh(resistive) < 1e-6
    # Same heat, roughly a third of the electricity.
    @test dhw_energy_kwh(resistive) > 2 * dhw_energy_kwh(pumped)
end

@testitem "The tank joins the other assets without special-casing" tags =
    [:integration, :slow] setup = [TankHome] begin
    @test consumption_columns(TankHome.make_tank()) == [:dhw_kw]

    result = TankHome.run([
        TankHome.make_tank(),
        HeatPump(
            TankHome.grid;
            building = BuildingSpec(120.0; heat_loss_kw = 6.0),
            setpoint = 20.0,
        ),
        Battery(10.0, 5.0),
    ])

    @test maximum(abs, balance_residual(result)) < 1e-9
    @test hasproperty(result.frame, :dhw_kw)
    @test hasproperty(result.frame, :heatpump_kw)
    @test hasproperty(result.frame, :battery_charge_kw)
    @test 0 <= self_consumption(result) <= 1
end

@testitem "A draw profile shorter than the run is caught" tags =
    [:unit, :fast] setup = [TankHome] begin
    using Dates: DateTime

    short = WaterTank(TimeGrid(DateTime(2024, 1, 8), 96 * 2))
    @test_throws ArgumentError TankHome.run([short])
end
