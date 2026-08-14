@testmodule HourlySky begin
    using BatteryBusinessCase
    using Dates: DateTime, Hour
    using Statistics: mean

    const site = Site(52.1, 5.18)

    """
    Build an hourly source by averaging a 15-minute synthetic day, so the true fine-resolution
    answer is known and the upsampler can be scored against it rather than only against itself.
    """
    function hourly_from_fine(day::DateTime, days::Integer; seed = 5)
        fine = synthetic_weather(TimeGrid(day, 96 * days), site; seed)
        times = collect(day:Hour(1):(day+Hour(24*days-1)))
        mean_of(v) = [mean(v[(4i+1):(4i+4)]) for i = 0:(length(times)-1)]
        return (; fine, times, ghi = mean_of(fine.ghi), dhi = mean_of(fine.dhi))
    end
end

@testitem "Upsampling: energy is conserved within every source interval" tags =
    [:unit, :fast] setup = [HourlySky] begin
    using Dates: DateTime
    using Statistics: mean

    src = HourlySky.hourly_from_fine(DateTime(2024, 6, 20), 3)
    site = HourlySky.site
    grid = TimeGrid(DateTime(2024, 6, 21), 96)

    up = upsample_irradiance(site, grid, src.times, src.ghi; dhi = src.dhi)

    # Interval 1 of the grid is hour 25 of the source.
    for k = 0:23
        @test mean(up.ghi[(4k+1):(4k+4)]) ≈ src.ghi[24+k+1] atol = 1e-9
        @test mean(up.dhi[(4k+1):(4k+4)]) ≈ src.dhi[24+k+1] atol = 1e-9
    end
end

@testitem "Upsampling: the three components close at every interval" tags = [:unit, :fast] setup =
    [HourlySky] begin
    using Dates: DateTime

    src = HourlySky.hourly_from_fine(DateTime(2024, 4, 10), 2)
    site = HourlySky.site
    grid = TimeGrid(DateTime(2024, 4, 10), 96)
    positions = BatteryBusinessCase.solar_positions(site, grid)

    up = upsample_irradiance(site, grid, src.times, src.ghi; dhi = src.dhi)

    @test all(up.ghi .>= 0)
    @test all(up.dni .>= 0)
    @test all(up.dhi .>= -1e-12)
    @test all(up.dhi .<= up.ghi .+ 1e-9)
    for k = 1:grid.n
        cosz = cosd(positions.zenith[k])
        cosz > 0.02 || continue
        @test up.dni[k] * cosz + up.dhi[k] ≈ up.ghi[k] atol = 1e-9
    end
end

@testitem "Upsampling: the reconstructed shape tracks the true fine series" tags =
    [:unit, :fast] setup = [HourlySky] begin
    using Dates: DateTime
    using Statistics: mean

    # This is the point of going through the clearness index rather than interpolating W/m²:
    # the reconstruction should recover the sub-hourly shape, not just the hourly totals.
    src = HourlySky.hourly_from_fine(DateTime(2024, 6, 20), 3)
    site = HourlySky.site
    grid = TimeGrid(DateTime(2024, 6, 21), 96)
    truth = src.fine.ghi[97:192]

    up = upsample_irradiance(site, grid, src.times, src.ghi; dhi = src.dhi)

    @test maximum(up.ghi) ≈ maximum(truth) rtol = 0.01
    @test sum(abs, up.ghi .- truth) / sum(truth) < 0.02

    # Holding the hourly value flat instead is visibly worse on both counts.
    held = resample(StepHold(), src.times, src.ghi, grid)
    @test sum(abs, held .- truth) / sum(truth) > sum(abs, up.ghi .- truth) / sum(truth)
end

@testitem "Upsampling: a GHI-only source is split with Erbs" tags = [:unit, :fast] setup =
    [HourlySky] begin
    using Dates: DateTime
    using Statistics: mean

    src = HourlySky.hourly_from_fine(DateTime(2024, 6, 20), 3)
    site = HourlySky.site
    grid = TimeGrid(DateTime(2024, 6, 21), 96)

    up = upsample_irradiance(site, grid, src.times, src.ghi)

    for k = 0:23
        @test mean(up.ghi[(4k+1):(4k+4)]) ≈ src.ghi[24+k+1] atol = 1e-9
    end
    @test all(up.dhi .<= up.ghi .+ 1e-9)
    # A June day in the Netherlands is neither fully diffuse nor fully direct.
    @test 0.1 < sum(up.dhi) / sum(up.ghi) < 0.95
end

@testitem "Upsampling: an all-dark source stays dark" tags = [:unit, :fast] begin
    using Dates: DateTime, Hour

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 12, 21), 96)
    times = collect(DateTime(2024, 12, 21):Hour(1):DateTime(2024, 12, 21, 23))

    up = upsample_irradiance(site, grid, times, zeros(24))
    @test all(iszero, up.ghi)
    @test all(iszero, up.dni)
    @test all(iszero, up.dhi)
end
