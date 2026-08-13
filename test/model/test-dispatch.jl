@testitem "Meter balance holds every interval" tags = [:integration] setup = [SmallHome] begin
    for assets in ([], [Battery(10.0, 5.0)])
        system = with_assets(home, assets)
        result = simulate(system, weather, load, contract)
        @test maximum(abs, balance_residual(result)) < 1e-8
        @test all(result.frame.import_kw .>= -1e-9)
        @test all(result.frame.export_kw .>= -1e-9)
        @test all(result.frame.import_kw .<= system.connection_kw + 1e-9)
        @test all(result.frame.export_kw .<= system.connection_kw + 1e-9)
    end
end

@testitem "Import and export never happen at once" tags = [:integration] setup = [SmallHome] begin
    system = with_assets(home, [Battery(10.0, 5.0)])
    result = simulate(system, weather, load, contract)
    frame = result.frame
    @test all(frame.import_kw .* frame.export_kw .< 1e-8)
    @test all(frame.battery_charge_kw .* frame.battery_discharge_kw .< 1e-8)
end

@testitem "A battery cannot make the household worse off" tags = [:integration] setup =
    [SmallHome] begin
    baseline = settle(simulate(home, weather, load, contract), contract)
    with_battery = settle(
        simulate(with_assets(home, [Battery(10.0, 5.0)]), weather, load, contract),
        contract,
    )
    # The dispatch objective is a proxy for the bill, so this is not a theorem — but a battery that
    # increased the bill would mean the price signal and the settlement engine disagree badly.
    @test with_battery.total <= baseline.total + 1e-6
end

@testitem "Rolling horizon does not drain storage at window boundaries" tags =
    [:integration] setup = [SmallHome] begin
    # With a flat price there is nothing to arbitrage, so a battery should simply sit still rather
    # than being emptied at the end of every window by a horizon that cannot see past it.
    flat = Contract(grid; commodity = 0.10, feed_in = 0.10, net_metering_fraction = 0.0)
    system = with_assets(home, [Battery(10.0, 5.0; soc_initial = 0.5)])
    result = simulate(system, weather, load, flat)

    boundaries = 96:96:(length(grid)-1)
    for k in boundaries
        # The state carried into the next window must be what the previous one ended on.
        @test result.frame.battery_soc_kwh[k] > 0.5 - 1e-6
    end
end

@testitem "Window and step geometry are respected" tags = [:integration] setup = [SmallHome] begin
    options = RunOptions(window_hours = 24, step_hours = 12)
    result =
        simulate(with_assets(home, [Battery(5.0, 2.5)]), weather, load, contract; options)
    # Seven days advanced twelve hours at a time.
    @test result.windows == 14
    @test maximum(abs, balance_residual(result)) < 1e-8

    @test_throws ArgumentError simulate(
        home,
        weather,
        load,
        contract;
        options = RunOptions(window_hours = 12, step_hours = 24),
    )
end

@testitem "Negative prices need the binary formulation" tags = [:integration] setup =
    [SmallHome] begin
    # Deeply negative prices make burning energy profitable, which is exactly the case the linear
    # program cannot represent: it will charge and discharge at once to dump kWh. The LP is
    # expected to warn; the binary formulation is expected to fix it.
    commodity = fill(-0.50, length(grid))
    commodity[1:2:end] .= 0.30
    perverse = Contract(grid; commodity, feed_in = -0.50, net_metering_fraction = 0.0)
    system = with_assets(home, [Battery(10.0, 5.0)])

    lp = simulate(
        system,
        weather,
        load,
        perverse;
        options = RunOptions(check_degeneracy = false),
    )
    simultaneous = sum(lp.frame.battery_charge_kw .* lp.frame.battery_discharge_kw .> 1e-6)

    milp = simulate(
        system,
        weather,
        load,
        perverse;
        options = RunOptions(exclusive = true, check_degeneracy = false),
    )
    @test all(milp.frame.battery_charge_kw .* milp.frame.battery_discharge_kw .< 1e-6)
    @test maximum(abs, balance_residual(milp)) < 1e-6
    # If the LP ever stops being degenerate here, this test has stopped testing anything.
    @test simultaneous > 0
end
