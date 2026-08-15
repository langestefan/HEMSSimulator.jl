@testitem "baseload averages the power it was asked for" tags = [:unit, :fast] begin
    using Dates: DateTime, Minute
    using Statistics: mean

    grid = TimeGrid(DateTime(2025, 1, 1), 96 * 7)
    series = baseload(grid; average_kw = 0.3)

    @test length(series) == grid.n
    @test all(>(0), series)
    @test mean(series) ≈ 0.3 rtol = 0.01

    # The contract is per *day*, not just over the whole horizon — a January day and a July day draw
    # the same, which is what makes two short simulations in different seasons comparable.
    daily = [mean(series[(d*96+1):(d*96+96)]) for d = 0:6]
    @test all(≈(0.3; rtol = 0.03), daily)
    @test mean(baseload(TimeGrid(DateTime(2025, 7, 3), 96 * 14))) ≈ 0.3 rtol = 0.01

    # Scaling is exactly linear in the requested power, and zero is a legal request.
    @test baseload(grid; average_kw = 0.6) ≈ 2 .* series
    @test all(iszero, baseload(grid; average_kw = 0.0))
end

@testitem "baseload peaks in the evening and dips at night" tags = [:unit, :fast] begin
    using Dates: DateTime
    using Statistics: mean

    # Averaged over a week the noise washes out and the shape is what is left.
    series = baseload(TimeGrid(DateTime(2025, 2, 3), 96 * 7); average_kw = 0.3)
    profile = [mean(series[k:96:end]) for k = 1:96]   # k-th quarter-hour of each day

    evening = argmax(profile) * 0.25 - 0.125         # interval centre, hours since midnight
    @test 18.0 <= evening <= 21.0
    @test 2.0 <= (argmin(profile) * 0.25 - 0.125) <= 5.0
    # "Fluctuates a bit", not a household activity profile with a 5:1 morning-to-night swing.
    @test 1.5 <= maximum(profile) / minimum(profile) <= 2.5
end

@testitem "baseload is defined off midnight, on any step that divides a day" tags =
    [:unit, :fast] begin
    using Dates: DateTime, Minute
    using Statistics: mean

    # The normaliser comes from the grid's start and step, not from its length, so none of these
    # shift the mean.
    @test mean(baseload(TimeGrid(DateTime(2025, 3, 1), Minute(60), 24 * 5))) ≈ 0.3 rtol =
        0.02
    @test mean(baseload(TimeGrid(DateTime(2025, 3, 1), Minute(5), 288 * 3))) ≈ 0.3 rtol =
        0.01
    @test mean(baseload(TimeGrid(DateTime(2025, 3, 1, 13, 30), 96 * 3))) ≈ 0.3 rtol = 0.02

    # A step that does not divide a day leaves "the mean over a day" undefined, so it is refused
    # rather than silently normalised against a partial cycle.
    @test_throws ArgumentError baseload(TimeGrid(DateTime(2025, 3, 1), Minute(7), 100))
    @test_throws ArgumentError baseload(
        TimeGrid(DateTime(2025, 3, 1), 96);
        average_kw = -0.1,
    )
    @test_throws ArgumentError baseload(TimeGrid(DateTime(2025, 3, 1), 96); jitter = 1.0)
end
