@testitem "Inverter clipping caps AC output" tags = [:unit, :fast] setup = [SunnyDay] begin
    big = PVArray(dc_capacity_kwp = 10.0, ac_capacity_kw = 3.0, tilt = 35, azimuth = 180)
    power = production(big, site, weather)
    @test maximum(power) <= 3.0 + 1e-9
    # A 10 kWp array in June must actually reach the inverter limit, otherwise this test would
    # pass for the wrong reason.
    @test maximum(power) ≈ 3.0 atol = 1e-6
end

@testitem "Production is zero at night and non-negative always" tags = [:unit, :fast] setup =
    [SunnyDay] begin
    array = PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 4.0, tilt = 35, azimuth = 180)
    power = production(array, site, weather)
    positions = solar_positions(site, grid)
    @test all(power .>= 0)
    @test all(power[k] == 0 for k = 1:length(grid) if positions.zenith[k] >= 90)
end

@testitem "Cell temperature derates output" tags = [:unit, :fast] begin
    array = PVArray(dc_capacity_kwp = 1.0, ac_capacity_kw = 1.0, tilt = 0, azimuth = 180)
    # At 1000 W/m² the NOCT model puts the cell well above ambient, so a hot day yields less.
    cold = cell_temperature(array, 1000.0, 0.0)
    hot = cell_temperature(array, 1000.0, 30.0)
    @test hot - cold ≈ 30.0
    @test cold ≈ 0.0 + (45 - 20) / 800 * 1000
end

@testitem "Multiple arrays clip independently" tags = [:unit, :fast] setup = [SunnyDay] begin
    east = PVArray(dc_capacity_kwp = 2.0, ac_capacity_kw = 1.0, tilt = 35, azimuth = 90)
    west = PVArray(dc_capacity_kwp = 2.0, ac_capacity_kw = 1.0, tilt = 35, azimuth = 270)
    split = production([east, west], site, weather)
    @test maximum(split) <= 2.0 + 1e-9
    @test sum(split) ≈
          sum(production(east, site, weather)) + sum(production(west, site, weather))
end

@testitem "Annual yield is physically plausible for the Netherlands" tags =
    [:integration, :slow] begin
    using Dates: DateTime

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2023, 1, 1), DateTime(2024, 1, 1))
    weather = synthetic_weather(grid, site)

    # Loose sanity bounds, not a validation: a Dutch rooftop is quoted around 900 kWh/kWp.
    annual_ghi = sum(weather.ghi) * hours(grid) / 1000
    @test 850 <= annual_ghi <= 1150
    @test 0.45 <= sum(weather.dhi) / sum(weather.ghi) <= 0.65

    south = PVArray(dc_capacity_kwp = 1.0, ac_capacity_kw = 1.0, tilt = 35, azimuth = 180)
    flat = PVArray(dc_capacity_kwp = 1.0, ac_capacity_kw = 1.0, tilt = 0, azimuth = 180)
    north = PVArray(dc_capacity_kwp = 1.0, ac_capacity_kw = 1.0, tilt = 35, azimuth = 0)

    @test 800 <= annual_yield(south, site, weather) <= 1000
    @test annual_yield(south, site, weather) > annual_yield(flat, site, weather)
    @test annual_yield(flat, site, weather) > annual_yield(north, site, weather)
end
