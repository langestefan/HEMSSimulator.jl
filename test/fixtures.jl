# Shared test fixtures. TestItemRunner discovers `@testsnippet` and `@testmodule` blocks anywhere in
# the package, so these are available to any `@testitem` that names them in `setup = [...]`.

@testsnippet SmallHome begin
    using Dates: DateTime

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 7)
    weather = synthetic_weather(grid, site; seed = 11)
    load = synthetic_load(grid; annual_kwh = 3500)
    prices = synthetic_prices(grid; seed = 13)
    contract = Contract(grid; commodity = prices .+ 0.02, feed_in = 0.04)
    home = HomeSystem(
        site = site,
        pv = [
            PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180),
        ],
    )
end

@testsnippet SunnyDay begin
    using Dates: DateTime

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 6, 21), 96)
    weather = synthetic_weather(grid, site; seed = 7)
end

@testmodule BillFixtures begin
    using BatteryBusinessCase
    using DataFrames: DataFrame
    using Dates: DateTime

    """
    A four-interval result with one interval importing 4 kW (1 kWh) and one exporting 2 kW
    (0.5 kWh). Small enough that every bill component can be computed by hand in the test.
    """
    function tiny_result()
        grid = TimeGrid(DateTime(2024, 1, 1), 4)
        frame = DataFrame(
            timestamp = timestamps(grid),
            load_kw = [4.0, 0.0, 0.0, 0.0],
            pv_available_kw = [0.0, 0.0, 2.0, 0.0],
            price_buy = zeros(4),
            price_sell = zeros(4),
            curtail_kw = zeros(4),
            import_kw = [4.0, 0.0, 0.0, 0.0],
            export_kw = [0.0, 0.0, 2.0, 0.0],
        )
        system = HomeSystem(site = Site(52.1, 5.18))
        return SimulationResult(grid, frame, system, 1, 0.0)
    end

    "A contract with every fixed component switched off, so only the tested terms are non-zero."
    function bare_contract(; kwargs...)
        return Contract(;
            commodity = [0.10, 0.10, 0.20, 0.10],
            feed_in = fill(0.05, 4),
            energy_tax = 0.10,
            tax_credit = 0.0,
            vat = 0.21,
            standing_charge = 0.0,
            feed_in_fee = 0.0,
            grid = FixedCapacityTariff(annual_eur = 0.0),
            kwargs...,
        )
    end
end
