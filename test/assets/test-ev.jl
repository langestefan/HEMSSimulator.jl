@testitem "EV schedule expands a commuting pattern" tags = [:unit, :fast] begin
    using Dates: Dates, Date, DateTime

    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 7)      # a week beginning on a Monday
    schedule = ev_schedule(grid; departure_hour = 8, return_hour = 18, kwh_per_day = 10.0)

    # Away ten hours a day on five weekdays.
    @test count(!, schedule.connected) == 10 * 4 * 5
    @test sum(schedule.trip_kwh) ≈ 50.0
    # Energy is spread across the away intervals rather than dropped in one step.
    @test count(>(0), schedule.trip_kwh) == 10 * 4 * 5
    @test all(≈(10.0 / 40), schedule.trip_kwh[.!schedule.connected])

    times = timestamps(grid)
    for k = 1:96                                        # Monday
        @test schedule.connected[k] == !(8 <= Dates.hour(times[k]) < 18)
    end
    @test all(schedule.connected[(5*96+1):(7*96)])      # the weekend

    # One deadline per driving day, on the interval before the car leaves.
    @test count(>(0), schedule.target_soc) == 5
    departures = findall(>(0), schedule.target_soc)
    @test all(Dates.hour(times[k]) == 7 && Dates.minute(times[k]) == 45 for k in departures)
    @test all(schedule.target_soc[departures] .== 0.8)

    # Distance times efficiency is the same thing said differently.
    by_distance = ev_schedule(grid; km_per_day = 50, kwh_per_km = 0.2)
    @test sum(by_distance.trip_kwh) ≈ 50.0

    # A variable pattern is a function of the date.
    varying = ev_schedule(grid; kwh_per_day = day -> Dates.dayofweek(day) == 1 ? 20.0 : 5.0)
    @test sum(varying.trip_kwh) ≈ 20.0 + 4 * 5.0

    # Driving at weekends too: the same ten hours, seven days.
    everyday = ev_schedule(grid; departure_hour = 8, return_hour = 18, weekdays_only = false)
    @test count(!, everyday.connected) == 10 * 4 * 7
    @test count(>(0), everyday.target_soc) == 7
end

@testitem "EV schedule rejects patterns it cannot express" tags = [:unit, :fast] begin
    using Dates: DateTime

    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 7)
    # Overnight trips would need a different construction, so they are refused rather than
    # silently producing a car that is home all night and never leaves.
    @test_throws ArgumentError ev_schedule(grid; departure_hour = 22, return_hour = 6)
    @test_throws ArgumentError ev_schedule(grid; target_soc = 1.5)
    @test_throws ArgumentError ev_schedule(grid; kwh_per_day = 10, km_per_day = 40)
end

@testitem "An EV validates its own schedule" tags = [:unit, :fast] begin
    using Dates: DateTime

    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 7)
    ok = ev_schedule(grid)

    @test_throws ArgumentError ElectricVehicle(;
        capacity_kwh = 60.0,
        charge_power_kw = 11.0,
        connected = ok.connected,
        trip_kwh = ok.trip_kwh[1:10],
        target_kwh = ok.target_soc,
    )
    @test_throws ArgumentError ElectricVehicle(;
        capacity_kwh = 60.0,
        charge_power_kw = 11.0,
        connected = falses(grid.n),
        trip_kwh = zeros(grid.n),
        target_kwh = zeros(grid.n),
    )
    # Driving while plugged in.
    @test_throws ArgumentError ElectricVehicle(;
        capacity_kwh = 60.0,
        charge_power_kw = 11.0,
        connected = trues(grid.n),
        trip_kwh = fill(0.1, grid.n),
        target_kwh = zeros(grid.n),
    )
    # A deadline the car physically cannot reach.
    @test_throws ArgumentError ElectricVehicle(;
        capacity_kwh = 60.0,
        charge_power_kw = 11.0,
        connected = ok.connected,
        trip_kwh = ok.trip_kwh,
        target_kwh = fill(100.0, grid.n),
    )
end

@testmodule EVHome begin
    using BatteryBusinessCase
    using Dates: DateTime

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 7)
    weather = synthetic_weather(grid, site; seed = 11)
    load = synthetic_load(grid; annual_kwh = 3000)
    prices = synthetic_prices(grid)
    contract = Contract(
        grid;
        commodity = prices .+ 0.02,
        feed_in = 0.04,
        net_metering_fraction = 0.0,
    )
    pv = [PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180)]
    make_ev(; kwargs...) = ElectricVehicle(
        grid;
        capacity_kwh = 60.0,
        charge_power_kw = 11.0,
        km_per_day = 45,
        kwargs...,
    )
    home_with(assets) = HomeSystem(site = site, pv = pv, assets = assets)
end

@testitem "The car is always full enough to leave" tags =
    [:integration, :slow] setup = [EVHome] begin
    ev = EVHome.make_ev()
    result = simulate(EVHome.home_with([ev]), EVHome.weather, EVHome.load, EVHome.contract)
    soc = result.frame.ev_soc_kwh

    for k = 1:length(ev.connected)
        ev.target_kwh[k] > 0 || continue
        @test soc[k] >= ev.target_kwh[k] - 1e-6
    end
    # The reserve is a charging policy, so it binds while plugged in and not on the road.
    floor_kwh = ev.soc_min * ev.capacity_kwh
    @test all(soc[ev.connected] .>= floor_kwh - 1e-6)
    @test all(soc .<= ev.soc_max * ev.capacity_kwh + 1e-6)
    # And it can only draw power at home.
    @test all(iszero, result.frame.ev_charge_kw[.!ev.connected])
end

@testitem "Every kWh the car uses was bought, once, with losses" tags =
    [:integration, :slow] setup = [EVHome] begin
    ev = EVHome.make_ev()
    result = simulate(EVHome.home_with([ev]), EVHome.weather, EVHome.load, EVHome.contract)
    soc = result.frame.ev_soc_kwh

    charged = ev_energy_kwh(result)
    driven = sum(ev.trip_kwh)
    stored = soc[end] - ev.soc_initial * ev.capacity_kwh
    @test charged * ev.charge_efficiency ≈ driven + stored rtol = 1e-8
    @test maximum(abs, balance_residual(result)) < 1e-9
end

@testitem "Charging is moved to the cheap hours, which is the point" tags =
    [:integration, :slow] setup = [EVHome] begin
    using Statistics: mean

    ev = EVHome.make_ev()
    result = simulate(EVHome.home_with([ev]), EVHome.weather, EVHome.load, EVHome.contract)

    charge = result.frame.ev_charge_kw
    paid = sum(charge .* result.frame.price_buy) / sum(charge)
    available = mean(result.frame.price_buy[ev.connected])
    @test paid < available
    # Not a rounding effect: the flexible load lands materially below the average price it could
    # have paid while plugged in.
    @test paid < 0.95 * available
end

@testitem "Terminal value belongs to storage, not to a car" tags =
    [:integration, :slow] setup = [EVHome] begin
    # A home battery needs an end-of-window value or the receding horizon empties it. A car does
    # not: its departure targets already anchor the trajectory. Crediting its charge as well made
    # it profitable to fill 60 kWh whenever the price dipped, so without V2G the credit is off —
    # and switching the option must therefore change nothing at all.
    ev = EVHome.make_ev()
    home = EVHome.home_with([ev])
    with = simulate(
        home,
        EVHome.weather,
        EVHome.load,
        EVHome.contract;
        options = RunOptions(terminal_value = true),
    )
    without = simulate(
        home,
        EVHome.weather,
        EVHome.load,
        EVHome.contract;
        options = RunOptions(terminal_value = false),
    )
    @test ev_energy_kwh(with) ≈ ev_energy_kwh(without) rtol = 1e-8
    # The car ends the week where its last deadline left it, not brimmed.
    @test with.frame.ev_soc_kwh[end] < 0.9 * ev.capacity_kwh

    # With V2G the charge really can come back out, so it is worth what a battery's is.
    v2g = EVHome.make_ev(discharge_power_kw = 11.0, degradation_cost = 0.05)
    @test supports_v2g(v2g)
    @test !supports_v2g(ev)
    banked = simulate(
        EVHome.home_with([v2g]),
        EVHome.weather,
        EVHome.load,
        EVHome.contract,
    )
    @test banked.frame.ev_soc_kwh[end] > with.frame.ev_soc_kwh[end]
end

@testitem "Asset flows reach the reporting layer without it knowing the type" tags =
    [:integration, :slow] setup = [EVHome] begin
    # `balance_residual` and the self-consumption metrics rebuild the balance from the result
    # frame. They find each asset's columns through `consumption_columns` / `production_columns`,
    # so adding an asset cannot silently drop its flows out of the accounting.
    @test consumption_columns(Battery(5.0, 2.5)) == [:battery_charge_kw]
    @test production_columns(EVHome.make_ev()) == [:ev_discharge_kw]

    combinations = [
        AbstractAsset[],
        AbstractAsset[Battery(10.0, 5.0)],
        AbstractAsset[EVHome.make_ev()],
        AbstractAsset[EVHome.make_ev(), Battery(10.0, 5.0)],
        AbstractAsset[Battery(10.0, 5.0), EVHome.make_ev()],
        AbstractAsset[Battery(5.0, 2.5), EVHome.make_ev(), Battery(5.0, 2.5)],
    ]
    for assets in combinations
        result = simulate(
            EVHome.home_with(assets),
            EVHome.weather,
            EVHome.load,
            EVHome.contract,
        )
        @test maximum(abs, balance_residual(result)) < 1e-9
        @test 0 <= self_consumption(result) <= 1
        @test 0 <= self_sufficiency(result) <= 1
        # Two assets of a type get suffixed columns, and each keeps writing to its own for the
        # whole run rather than migrating to a suffixed one after the first window.
        for (asset, mapping) in zip(assets, result.asset_columns)
            for name in vcat(consumption_columns(asset), production_columns(asset))
                @test haskey(mapping, name)
                @test hasproperty(result.frame, mapping[name])
            end
        end
        @test length(unique(vcat((collect(values(m)) for m in result.asset_columns)...))) ==
              sum(length, result.asset_columns; init = 0)
    end
end

@testitem "A schedule shorter than the run is caught, not truncated" tags =
    [:unit, :fast] setup = [EVHome] begin
    using Dates: DateTime

    short = TimeGrid(DateTime(2024, 4, 1), 96 * 2)
    ev = ElectricVehicle(short; capacity_kwh = 60.0, charge_power_kw = 11.0)
    @test_throws ArgumentError simulate(
        EVHome.home_with([ev]),
        EVHome.weather,
        EVHome.load,
        EVHome.contract,
    )
end
