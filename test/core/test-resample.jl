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
    groups = BatteryBusinessCase.group_indices(times, Millisecond(Hour(1)), grid)
    @test groups == repeat(1:3; inner = 4)
end
