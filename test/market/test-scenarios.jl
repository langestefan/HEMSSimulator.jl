@testitem "Peak intervals follow clock hours and working days" tags = [:unit, :fast] begin
    using Dates: Dates, DateTime, Hour

    # A full week beginning on a Monday.
    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 7)
    peak = peak_intervals(grid)

    # Five hours a day on five weekdays, out of a week.
    @test sum(peak) == 5 * 4 * 5
    @test sum(peak) / length(peak) ≈ 25 / 168

    times = timestamps(grid)
    @test all(peak[k] == (16 <= Dates.hour(times[k]) <= 20) for k = 1:96)          # Monday
    @test !any(peak[(5*96+1):(7*96)])                                              # the weekend

    # Both switches work.
    @test sum(peak_intervals(grid; weekdays_only = false)) == 5 * 4 * 7
    @test sum(peak_intervals(grid; hours = 17:18)) == 2 * 4 * 5
    @test !any(peak_intervals(grid; hours = 3:2))
end

@testitem "The time-of-use transport tariff has exactly two blocks" tags = [:unit, :fast] begin
    using Dates: DateTime

    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 7)
    tariff = peak_transport_tariff(
        grid;
        peak_eur_per_kwh = 0.07,
        offpeak_eur_per_kwh = 0.02,
        export_peak_eur_per_kwh = 0.01,
        annual_eur = 150.0,
    )

    @test tariff isa TimeVaryingGridTariff
    @test sort(unique(tariff.import_eur_per_kwh)) == [0.02, 0.07]
    @test sort(unique(tariff.export_eur_per_kwh)) == [0.0, 0.01]
    @test BatteryBusinessCase.fixed_grid_cost(tariff) == 150.0

    peak = peak_intervals(grid)
    @test all(tariff.import_eur_per_kwh[peak] .== 0.07)
    @test all(tariff.import_eur_per_kwh[.!peak] .== 0.02)
    @test all(tariff.export_eur_per_kwh[.!peak] .== 0.0)
end

@testitem "The four scenarios are four values, not four code paths" tags = [:unit, :fast] begin
    using Dates: DateTime

    grid = TimeGrid(DateTime(2024, 4, 1), 96)
    regimes = scenarios(grid; commodity = 0.10, feed_in = 0.04, standing_charge = 60.0)

    @test keys(regimes) == SCENARIO_NAMES
    @test regimes.netting_fixed.net_metering_fraction == 1.0
    @test regimes.netting_variable.net_metering_fraction == 1.0
    @test regimes.no_netting_fixed.net_metering_fraction == 0.0
    @test regimes.no_netting_variable.net_metering_fraction == 0.0

    @test regimes.netting_fixed.grid isa FixedCapacityTariff
    @test regimes.no_netting_fixed.grid isa FixedCapacityTariff
    @test regimes.netting_variable.grid isa TimeVaryingGridTariff
    @test regimes.no_netting_variable.grid isa TimeVaryingGridTariff

    # Everything else is shared, so a study changes one keyword rather than four contracts.
    for contract in regimes
        @test contract.standing_charge == 60.0
        @test contract.energy_tax == NL_TARIFFS_2025.energy_tax
        @test length(contract.commodity) == grid.n
    end

    # A phase-out year is this parameter, not a fifth scenario.
    ramp = scenarios(grid; commodity = 0.10, feed_in = 0.04, netting_fraction = 0.36)
    @test ramp.netting_fixed.net_metering_fraction == 0.36
    @test ramp.no_netting_fixed.net_metering_fraction == 0.0

    @test_throws ArgumentError scenarios(
        grid;
        commodity = 0.10,
        feed_in = 0.04,
        netting_fraction = 1.5,
    )
end

@testitem "Netting changes what an exported kWh is worth" tags =
    [:unit, :fast] setup = [BillFixtures] begin
    using Dates: DateTime

    grid = TimeGrid(DateTime(2024, 1, 1), 4)
    result = BillFixtures.tiny_result()
    regimes = scenarios(
        grid;
        commodity = 0.10,
        feed_in = 0.04,
        tax_credit = 0.0,
        standing_charge = 0.0,
        fixed_tariff = FixedCapacityTariff(annual_eur = 0.0),
        variable_tariff = peak_transport_tariff(grid; annual_eur = 0.0),
    )

    netted = settle(result, regimes.netting_fixed)
    plain = settle(result, regimes.no_netting_fixed)

    @test netted.netted_kwh > 0
    @test plain.netted_kwh == 0
    # The home exports 0.5 kWh and imports 1 kWh, so netting absorbs the whole export at retail
    # rather than paying the far lower feed-in price. It cannot be worse off.
    @test netted.total < plain.total
end

@testitem "Tariff defaults are the published Dutch figures" tags = [:unit, :fast] begin
    using Dates: DateTime

    # These move every Belastingplan, so the defaults are pinned to a named, dated set rather than
    # to literals scattered through the struct definitions.
    grid = TimeGrid(DateTime(2024, 1, 1), 4)
    contract = Contract(grid; commodity = 0.10, feed_in = 0.04)

    @test contract.energy_tax == NL_TARIFFS_2025.energy_tax == 0.10154
    @test contract.tax_credit == NL_TARIFFS_2025.tax_credit == 524.95
    @test contract.vat == NL_TARIFFS_2025.vat == 0.21
    @test FixedCapacityTariff().annual_eur == NL_TARIFFS_2025.capacity_tariff

    # The retail price of a kWh under a flat 10 ct commodity: (0.10 + tax) x VAT.
    @test retail_price(contract)[1] ≈ (0.10 + 0.10154) * 1.21
end
