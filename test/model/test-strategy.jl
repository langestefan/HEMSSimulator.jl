@testitem "A strategy is two weights, not a branch" tags = [:unit, :fast] begin
    economic = objective_weights(EconomicStrategy(), nothing)
    @test economic.import_kwh == 0.0
    @test economic.cost == 1.0

    green = objective_weights(GreenStrategy(), nothing)
    @test green.import_kwh == 1.0
    @test green.cost == 1.0e-3
    @test objective_weights(GreenStrategy(cost_weight = 0.0), nothing).cost == 0.0

    # The default has to stay economic, or every result in the package changes meaning.
    @test RunOptions().strategy === EconomicStrategy()
    @test RunOptions(strategy = GreenStrategy()).strategy isa GreenStrategy
end

@testmodule TwoStrategies begin
    using HEMSSimulator
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
    home = HomeSystem(
        site = site,
        pv = [PVArray(dc_capacity_kwp = 5.0, ac_capacity_kw = 4.5, tilt = 35, azimuth = 180)],
        assets = [Battery(10.0, 5.0; degradation_cost = 0.02)],
    )
    run(strategy) = simulate(
        home,
        weather,
        load,
        contract;
        options = RunOptions(
            window_hours = 24,
            step_hours = 0.25,
            terminal_value = false,
            strategy = strategy,
        ),
    )
end

@testitem "Green never charges the battery from the grid" tags =
    [:integration, :slow] setup = [TwoStrategies] begin
    # Not a rule in the model — a consequence of the objective. Charging from the grid *is* an
    # import, and a round trip loses energy, so it can never avoid as much later import as it costs
    # now. An import-minimising optimizer therefore never does it.
    green = TwoStrategies.run(GreenStrategy())
    economic = TwoStrategies.run(EconomicStrategy())

    grid_charging(result) = count(
        k ->
            result.frame.import_kw[k] > 1e-6 && result.frame.battery_charge_kw[k] > 1e-6,
        1:length(result),
    )

    @test grid_charging(green) == 0
    # And the economic controller does do it, or the comparison would be vacuous.
    @test grid_charging(economic) > 0
end

@testitem "Each strategy wins on its own measure" tags =
    [:integration, :slow] setup = [TwoStrategies] begin
    green = TwoStrategies.run(GreenStrategy())
    economic = TwoStrategies.run(EconomicStrategy())
    bill(result) = settle(result, TwoStrategies.contract).total

    # Green takes less from the grid; economic pays less. Neither can beat the other at its own
    # objective, which is the whole content of having two.
    @test imported_kwh(green) < imported_kwh(economic)
    @test bill(economic) < bill(green)

    @test maximum(abs, balance_residual(green)) < 1e-9
    @test maximum(abs, balance_residual(economic)) < 1e-9
end

@testitem "Self-sufficiency flatters the economic strategy" tags =
    [:integration, :slow] setup = [TwoStrategies] begin
    # A trap worth pinning down. `self_sufficiency` counts battery discharge as on-site supply
    # whatever the battery was charged from, so a controller that buys cheap grid energy at night
    # and discharges it by day scores *higher* than one that never imports to store at all.
    # Imported energy is the honest measure of how green a run was; self-sufficiency is not.
    green = TwoStrategies.run(GreenStrategy())
    economic = TwoStrategies.run(EconomicStrategy())

    @test imported_kwh(green) < imported_kwh(economic)
    @test self_sufficiency(economic) > self_sufficiency(green)
end
