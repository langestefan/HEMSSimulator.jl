@testitem "Sweep tabulates a business case per candidate" tags = [:integration, :slow] begin
    using Dates: DateTime
    using DataFrames: nrow

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 14)
    weather = synthetic_weather(grid, site; seed = 21)
    load = synthetic_load(grid; annual_kwh = 3500)
    prices = synthetic_prices(grid; seed = 23)
    contract = Contract(
        grid;
        commodity = prices .+ 0.02,
        feed_in = 0.04,
        net_metering_fraction = 0.0,
    )
    home = HomeSystem(
        site = site,
        pv = [
            PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180),
        ],
    )

    candidates = [Battery(kwh, kwh / 2) for kwh in (2.5, 5.0, 10.0)]
    table = sweep(
        home,
        weather,
        load,
        contract,
        candidates;
        investment = b -> Investment(capex = 500 + 500 * b.capacity_kwh),
    )

    @test nrow(table) == 3
    @test table.capacity_kwh == [2.5, 5.0, 10.0]
    # A bigger battery saves more but costs more; savings must be positive and monotone in size.
    @test all(table.annual_savings .> 0)
    @test issorted(table.annual_savings)
    @test all(0 .<= table.self_consumption .<= 1)
    @test all(0 .<= table.self_sufficiency .<= 1)
    @test all(table.cycles_per_year .> 0)
end

@testitem "Sizing optimum at the edge of the grid is flagged" tags = [:unit, :fast] begin
    using DataFrames: DataFrame

    table = DataFrame(npv = [1.0, 5.0, 3.0])
    @test best(table).npv == 5.0

    rising = DataFrame(npv = [1.0, 2.0, 9.0])
    @test_logs (:warn, r"edge of the candidate range") best(rising)
end
