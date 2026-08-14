@testmodule ENTSOEFixture begin
    using BatteryBusinessCase

    const path = joinpath(@__DIR__, "..", "fixtures", "entsoe-day-ahead-nl-2024-09-01.xml")

    "A recorded Publication_MarketDocument: NL day-ahead prices, 2024-09-01T22:00 to 22T22:00 UTC."
    xml() = read(path, String)
end

@testitem "ENTSO-E: a recorded document parses into EUR/kWh" tags = [:unit, :fast] setup =
    [ENTSOEFixture] begin
    using Dates: DateTime, Hour

    prices = parse_entsoe_prices(ENTSOEFixture.xml())

    @test length(prices.times) == 24
    @test first(prices.times) == DateTime(2024, 9, 1, 22)
    @test last(prices.times) == DateTime(2024, 9, 2, 21)
    @test BatteryBusinessCase.source_step(prices.times) == Hour(1)
    # ENTSO-E publishes EUR/MWh; every price in this package is EUR/kWh, so a wholesale price is
    # cents, not tens of euros. Getting the factor wrong is a 1000x error that still "runs".
    @test all(0.0 .< prices.prices .< 1.0)
    @test maximum(prices.prices) ≈ 0.25553
    @test minimum(prices.prices) ≈ 0.08102
end

@testitem "ENTSO-E: prices are held flat across their market time unit" tags =
    [:unit, :fast] setup = [ENTSOEFixture] begin
    using Dates: DateTime

    prices = parse_entsoe_prices(ENTSOEFixture.xml())
    grid = TimeGrid(DateTime(2024, 9, 1, 22), 96)
    aligned = resample(StepHold(), prices.times, prices.prices, grid)

    @test length(aligned) == 96
    # Four identical quarters per settled hour: a quarter inside an hourly-settled period cleared
    # at that hour's price, and interpolating would let the optimizer trade a ramp that never was.
    for h = 0:23
        @test allequal(aligned[(4h+1):(4h+4)])
        @test aligned[4h+1] == prices.prices[h+1]
    end
end

@testitem "ENTSO-E: duplicate publications collapse" tags = [:unit, :fast] begin
    using Dates: DateTime, Hour

    # A bidding zone in the middle of a market time unit change publishes the same period twice.
    time = [
        DateTime(2024, 9, 1, 1),
        DateTime(2024, 9, 1, 0),
        DateTime(2024, 9, 1, 0),
        DateTime(2024, 9, 1, 2),
    ]
    value = [20.0, 10.0, 10.0, 30.0]
    unique = BatteryBusinessCase._sorted_unique(time, value)
    @test unique.times == [DateTime(2024, 9, 1, h) for h = 0:2]
    @test unique.prices == [10.0, 20.0, 30.0]
end

@testitem "ENTSO-E: an empty document is reported, not returned" tags = [:unit, :fast] begin
    acknowledgement = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Acknowledgement_MarketDocument xmlns="urn:iec62325.351:tc57wg16:451-1:acknowledgementdocument:8:0">
      <mRID>abc</mRID>
      <Reason><code>999</code><text>No matching data found</text></Reason>
    </Acknowledgement_MarketDocument>
    """
    @test_throws ErrorException parse_entsoe_prices(acknowledgement)
end

@testitem "ENTSO-E: downloading a real year" tags = [:integration, :network] begin
    using Dates: DateTime

    haskey(ENV, "ENTSOE_API_TOKEN") ||
        error("set ENTSOE_API_TOKEN to run the :network tests")
    grid = TimeGrid(DateTime(2023, 1, 1), DateTime(2024, 1, 1))
    prices = entsoe_prices(grid)

    @test length(prices) == 35_040
    @test all(isfinite, prices)
    # Dutch day-ahead in 2023 averaged around 10 ct/kWh, with hours below zero.
    @test 0.02 < sum(prices) / length(prices) < 0.20
    @test minimum(prices) < 0.0
end
