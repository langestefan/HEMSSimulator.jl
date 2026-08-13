@testitem "Bill under full net metering" tags = [:unit, :fast] setup = [BillFixtures] begin
    result = BillFixtures.tiny_result()
    contract = BillFixtures.bare_contract(net_metering_fraction = 1.0)
    bill = settle(result, contract)

    # Imported 1.0 kWh, exported 0.5 kWh, so all export is netted.
    @test bill.imported_kwh ≈ 1.0
    @test bill.exported_kwh ≈ 0.5
    @test bill.netted_kwh ≈ 0.5

    # Commodity: 1 kWh imported at 0.10. Netting credit: 0.5 kWh exported at its own interval
    # price of 0.20. Energy tax falls on net consumption only: (1.0 - 0.5) * 0.10.
    @test bill.commodity_cost ≈ 0.10
    @test bill.netting_credit ≈ 0.10
    @test bill.feed_in_revenue ≈ 0.0
    @test bill.energy_tax ≈ 0.05
    @test bill.vat ≈ 0.21 * 0.05
    @test bill.total ≈ 0.05 * 1.21
end

@testitem "Bill without net metering" tags = [:unit, :fast] setup = [BillFixtures] begin
    result = BillFixtures.tiny_result()
    contract = BillFixtures.bare_contract(net_metering_fraction = 0.0)
    bill = settle(result, contract)

    @test bill.netted_kwh ≈ 0.0
    @test bill.netting_credit ≈ 0.0
    # Export is now paid the feed-in rate only, and tax falls on the whole import.
    @test bill.feed_in_revenue ≈ 0.05 * 0.5
    @test bill.energy_tax ≈ 0.10
    @test bill.total ≈ (0.10 + 0.10) * 1.21 - 0.025

    # Removing net metering must make the household worse off, all else equal.
    netted = settle(result, BillFixtures.bare_contract(net_metering_fraction = 1.0))
    @test bill.total > netted.total
end

@testitem "Bill with a time-varying grid tariff" tags = [:unit, :fast] setup =
    [BillFixtures] begin
    result = BillFixtures.tiny_result()
    tariff = TimeVaryingGridTariff(import_eur_per_kwh = fill(0.04, 4))
    plain = settle(result, BillFixtures.bare_contract(net_metering_fraction = 0.0))
    varying = settle(
        result,
        BillFixtures.bare_contract(net_metering_fraction = 0.0, grid = tariff),
    )

    # One imported kWh now also pays 0.04 of transport, plus VAT on it.
    @test varying.transport_cost ≈ 0.04
    @test varying.total - plain.total ≈ 0.04 * 1.21
end

@testitem "Fixed charges are prorated to the simulated period" tags = [:unit, :fast] setup =
    [BillFixtures] begin
    result = BillFixtures.tiny_result()
    contract = BillFixtures.bare_contract(
        net_metering_fraction = 0.0,
        tax_credit = 8760.0,
        standing_charge = 8760.0,
        grid = FixedCapacityTariff(annual_eur = 8760.0),
    )
    bill = settle(result, contract)

    # The result covers one hour, so exactly 1/8760 of a year: each annual item contributes 1.00.
    @test bill.years ≈ 1 / 8760
    @test bill.tax_credit ≈ -1.0
    @test bill.fixed_cost ≈ 1.0
    @test bill.transport_cost ≈ 1.0
end

@testitem "Netting is capped by consumption" tags = [:unit, :fast] setup = [BillFixtures] begin
    using DataFrames: DataFrame

    # Export far exceeding import: netting can only cancel what was consumed, and the energy tax
    # cannot go negative.
    result = BillFixtures.tiny_result()
    result.frame.export_kw .= [0.0, 0.0, 40.0, 0.0]
    bill = settle(result, BillFixtures.bare_contract(net_metering_fraction = 1.0))

    @test bill.netted_kwh ≈ bill.imported_kwh
    @test bill.energy_tax ≈ 0.0
    @test bill.feed_in_revenue > 0
end
