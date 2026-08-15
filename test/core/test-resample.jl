@testitem "Resample: step hold" tags = [:unit, :fast] begin
    using Dates: DateTime, Hour, Minute

    times = collect(DateTime(2024, 1, 1):Hour(1):DateTime(2024, 1, 1, 3))
    values = [10.0, 20.0, 30.0, 40.0]
    grid = TimeGrid(DateTime(2024, 1, 1), 12)

    held = resample(StepHold(), times, values, grid)
    @test length(held) == 12
    @test held[1:4] == fill(10.0, 4)
    @test held[5:8] == fill(20.0, 4)
    @test held[9:12] == fill(30.0, 4)

    # A grid at the source resolution reproduces the source exactly.
    same = TimeGrid(DateTime(2024, 1, 1), Minute(60), 4)
    @test resample(StepHold(), times, values, same) == values
end

@testitem "Resample: linear interpolation at interval midpoints" tags = [:unit, :fast] begin
    using Dates: DateTime, Hour

    times = collect(DateTime(2024, 1, 1):Hour(1):DateTime(2024, 1, 1, 2))
    values = [0.0, 4.0, 8.0]
    grid = TimeGrid(DateTime(2024, 1, 1), 8)

    interpolated = resample(LinearInterp(), times, values, grid)
    # Midpoints of the first four intervals sit at 1/8, 3/8, 5/8, 7/8 of the first source hour.
    @test interpolated[1:4] ≈ [0.5, 1.5, 2.5, 3.5]
    @test interpolated[5:8] ≈ [4.5, 5.5, 6.5, 7.5]

    # A linear function is reproduced exactly, so the mean over each source interval is preserved.
    @test sum(interpolated[1:4]) / 4 ≈ values[1] + 2
end

@testitem "Resample: the trailing half-step is held, not extrapolated" tags = [:unit, :fast] begin
    using Dates: DateTime, Hour

    # An hourly series ending at 23:00 has to cover a grid ending at midnight. Linear
    # extrapolation there would invent a value beyond the last sample; holding flat does not.
    times = collect(DateTime(2024, 1, 1):Hour(1):DateTime(2024, 1, 1, 23))
    values = collect(0.0:23.0)
    grid = TimeGrid(DateTime(2024, 1, 1), 96)

    interpolated = resample(LinearInterp(), times, values, grid)
    @test length(interpolated) == 96
    @test interpolated[end] == 23.0
    @test interpolated[end-1] == 23.0
    @test maximum(interpolated) == 23.0
end

@testitem "Resample: bad input is reported against the input" tags = [:unit, :fast] begin
    using Dates: DateTime, Hour, Minute

    grid = TimeGrid(DateTime(2024, 1, 1), 96)
    good = collect(DateTime(2024, 1, 1):Hour(1):DateTime(2024, 1, 1, 23))

    @test_throws ArgumentError resample(StepHold(), good, collect(0.0:22.0), grid)
    @test_throws ArgumentError resample(StepHold(), good[1:1], [1.0], grid)

    # A missing hour is a gap, not something to interpolate across.
    gappy = vcat(good[1:5], good[7:end])
    err = try
        source_step(gappy)
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("not uniformly spaced", err.msg)

    # A source that stops before the grid does.
    @test_throws ArgumentError resample(StepHold(), good[1:12], collect(0.0:11.0), grid)
    # ... or starts after it.
    @test_throws ArgumentError resample(StepHold(), good[2:end], collect(1.0:23.0), grid)
end

@testitem "Resample: group indices map fine intervals to source intervals" tags =
    [:unit, :fast] begin
    using Dates: DateTime, Hour, Millisecond

    times = collect(DateTime(2024, 1, 1):Hour(1):DateTime(2024, 1, 1, 3))
    grid = TimeGrid(DateTime(2024, 1, 1), 12)
    groups = HEMSSimulator.group_indices(times, Millisecond(Hour(1)), grid)
    @test groups == repeat(1:3; inner = 4)
end

@testitem "Step hold does not need a uniformly sampled source" tags = [:unit, :fast] begin
    using Dates: DateTime, Hour, Minute

    # The Dutch day-ahead market moved from an hourly to a quarter-hourly market time unit during
    # 2025, so a single year of prices comes back with both resolutions in it. Step hold does not
    # need uniformity — each sample holds until the next — and requiring it made a real year
    # unloadable.
    times = vcat(
        DateTime(2024, 1, 1):Hour(1):DateTime(2024, 1, 1, 2),        # 00:00, 01:00, 02:00
        DateTime(2024, 1, 1, 3):Minute(15):DateTime(2024, 1, 1, 3, 45),
    )
    values = [10.0, 20.0, 30.0, 41.0, 42.0, 43.0, 44.0]
    grid = TimeGrid(DateTime(2024, 1, 1), 16)                        # four hours at 15 minutes

    held = resample(StepHold(), times, values, grid)
    @test held[1:4] == fill(10.0, 4)      # inside the first hourly sample
    @test held[5:8] == fill(20.0, 4)
    @test held[9:12] == fill(30.0, 4)
    @test held[13:16] == [41.0, 42.0, 43.0, 44.0]   # the quarter-hourly tail, one each

    # The reverse order too: fine steps first, then coarse.
    reversed_times = vcat(
        DateTime(2024, 1, 1):Minute(15):DateTime(2024, 1, 1, 0, 45),
        DateTime(2024, 1, 1, 1):Hour(1):DateTime(2024, 1, 1, 3),
    )
    reversed = resample(StepHold(), reversed_times, values, grid)
    @test reversed[1:4] == [10.0, 20.0, 30.0, 41.0]
    @test reversed[5:8] == fill(42.0, 4)

    # Coverage is still checked; the final sample is assumed to last as long as the one before it.
    @test_throws ArgumentError resample(StepHold(), times[1:3], values[1:3], grid)
    # And a non-monotone series is still a data error, not something to sort silently.
    @test_throws ArgumentError resample(
        StepHold(),
        [DateTime(2024, 1, 1), DateTime(2024, 1, 1)],
        [1.0, 2.0],
        TimeGrid(DateTime(2024, 1, 1), 1),
    )

    # Linear interpolation still demands uniformity, because its midpoint arithmetic assumes it.
    @test_throws ArgumentError resample(LinearInterp(), times, values, grid)
end

@testitem "The rolling horizon accepts a sub-hourly step" tags = [:unit, :fast] begin
    using Dates: DateTime

    # A real controller re-optimizes every interval, not every day. That needs a fractional step.
    options = RunOptions(window_hours = 24, step_hours = 0.25)
    @test options.window_hours == 24.0
    @test options.step_hours == 0.25

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 4, 1), 96)
    weather = synthetic_weather(grid, site; seed = 5)
    load = synthetic_load(grid; annual_kwh = 3000)
    contract = Contract(grid; commodity = synthetic_prices(grid), feed_in = 0.04)
    home = HomeSystem(
        site = site,
        pv = [
            PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180),
        ],
        assets = [Battery(5.0, 2.5)],
    )

    result = simulate(home, weather, load, contract; options)
    # One solve per interval, each looking a day ahead but implementing only its own interval.
    @test result.windows == grid.n
    @test maximum(abs, balance_residual(result)) < 1e-9
    @test_throws ArgumentError simulate(
        home,
        weather,
        load,
        contract;
        options = RunOptions(window_hours = 1, step_hours = 2),
    )
end
