@testsnippet Attributed begin
    using Dates: DateTime

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 6, 1), 96 * 6)
    weather = synthetic_weather(grid, site; seed = 23)
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
        assets = AbstractAsset[
            ElectricVehicle(grid; capacity_kwh = 60.0, charge_power_kw = 11.0, km_per_day = 40),
            Battery(10.0, 5.0),
        ],
    )
    result = simulate(
        home,
        weather,
        load,
        contract;
        options = RunOptions(window_hours = 24, step_hours = 6, terminal_value = false),
    )
    dt = hours(grid)
end

@testitem "energy_flows conserves energy both ways" tags = [:integration, :fast] setup =
    [Attributed] begin
    using DataFrames

    flows = energy_flows(result)
    frame = result.frame

    # Every source's row sums to what that source actually supplied, and every sink's column to what
    # it actually took. If either fails the attribution is inventing or losing energy.
    pv_used = sum(frame.pv_available_kw .- frame.curtail_kw) * dt
    @test sum(flows[flows.source .== "PV", :kwh]) ≈ pv_used rtol = 1e-9
    @test sum(flows[flows.source .== "grid", :kwh]) ≈ sum(frame.import_kw) * dt rtol = 1e-9
    @test sum(flows[flows.sink .== "base load", :kwh]) ≈ sum(frame.load_kw) * dt rtol = 1e-9
    @test sum(flows[flows.sink .== "export", :kwh]) ≈ sum(frame.export_kw) * dt rtol = 1e-9

    # And the grand total is the meter balance, which `balance_residual` independently checks.
    @test sum(flows.kwh) ≈ sum(onsite_supply(result) .+ frame.import_kw) * dt rtol = 1e-9
    @test maximum(abs, balance_residual(result)) < 1e-9
end

@testitem "solar_use accounts for every available kWh" tags = [:integration, :fast] setup =
    [Attributed] begin
    use = solar_use(result)
    shares = [getfield(use, k) for k in keys(use) if k !== :available_kwh]

    # Curtailment is in there, which is why this sums to one against *available* PV rather than
    # against what was produced.
    @test sum(shares) ≈ 1.0 rtol = 1e-9
    @test use.available_kwh ≈ sum(result.frame.pv_available_kw) * dt rtol = 1e-9
    @test all(>=(-1e-12), shares)
    @test use.curtailed ≈
          sum(result.frame.curtail_kw) / sum(result.frame.pv_available_kw) rtol = 1e-9
end

@testitem "source_mix splits a sink into shares that sum to one" tags = [:integration, :fast] setup =
    [Attributed] begin
    for sink in ("ev charge", "battery charge", "base load")
        mix = source_mix(result, sink)
        shares = [getfield(mix, k) for k in keys(mix) if k !== :total_kwh]
        @test sum(shares) ≈ 1.0 rtol = 1e-9
        @test all(>=(-1e-12), shares)
    end
    @test source_mix(result, "base load").total_kwh ≈ sum(result.frame.load_kw) * dt rtol = 1e-9

    # A typo must not quietly answer "0% from everything".
    @test_throws ArgumentError source_mix(result, "ev charging")
end

@testitem "a house with no battery attributes nothing to one" tags = [:integration, :fast] setup =
    [Attributed] begin
    bare = with_assets(home, [a for a in home.assets if !(a isa Battery)])
    plain = simulate(
        bare,
        weather,
        load,
        contract;
        options = RunOptions(window_hours = 24, step_hours = 6, terminal_value = false),
    )
    flows = energy_flows(plain)
    @test !any(occursin.("battery", flows.source))
    @test !any(occursin.("battery", flows.sink))
    # And the EV can then only be fed by the two remaining sources.
    mix = source_mix(plain, "ev charge")
    @test Set(keys(mix)) == Set((:total_kwh, :PV, :grid))
end
