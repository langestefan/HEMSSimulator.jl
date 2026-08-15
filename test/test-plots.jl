# The plotting *drawing* lives in the Makie extension and is deliberately untested (see CLAUDE.md).
# The window arithmetic does not — it is plain Julia, it is what the dashboard's sliders index with,
# and it is where the mistakes have actually been.

@testitem "interval_range accepts days, dates and exact intervals" tags = [:unit, :fast] begin
    using Dates: Date, DateTime

    grid = TimeGrid(DateTime(2025, 3, 10), 96 * 5)

    @test interval_range(grid, 1) == 1:96
    @test interval_range(grid, 3) == 193:288
    @test interval_range(grid, 2:3) == 97:288
    @test interval_range(grid, :) == 1:(96*5)
    @test interval_range(grid, Date(2025, 3, 12)) == 193:288
    @test interval_range(grid, Date(2025, 3, 11):Date(2025, 3, 12)) == 97:288

    # A whole-day selection cannot express the sub-day windows the dashboard's width slider offers,
    # which is the entire reason `Intervals` exists.
    @test interval_range(grid, Intervals(193:216)) == 193:216
    @test length(interval_range(grid, Intervals(193:216))) == 24   # six hours at 15 minutes

    @test_throws ArgumentError interval_range(grid, 0)
    @test_throws ArgumentError interval_range(grid, 6)
    @test_throws ArgumentError interval_range(grid, Intervals(400:500))
    @test_throws ArgumentError interval_range(grid, Intervals(5:4))
    # A function is a valid Julia value and an invalid window; the dashboard once passed `window`,
    # the exported grid-slicing function, instead of its own local of the same name.
    @test_throws ArgumentError interval_range(grid, window)
end

@testitem "time_ticks lands on midnight, not on the window's start" tags = [:unit, :fast] begin
    using Dates: DateTime

    # The whole point of aligning to the clock rather than to the data: the same hour of the day sits
    # at the same place in every figure, whatever time the window happens to open.
    positions, labels = time_ticks(DateTime(2025, 7, 10, 6, 0), 72)
    @test positions == [6.0, 18.0, 30.0, 42.0, 54.0, 66.0]
    @test labels[1] == "07-10 12:00"
    @test labels[2] == "07-11 00:00"
    @test all(l -> endswith(l, "00:00") || endswith(l, "12:00"), labels)

    aligned, _ = time_ticks(DateTime(2025, 7, 10), 72)
    @test aligned == collect(0.0:12.0:72.0)

    # An awkward start is still pulled onto the clock.
    odd, odd_labels = time_ticks(DateTime(2025, 1, 15, 13, 30), 72)
    @test first(odd) == 10.5
    @test first(odd_labels) == "01-16 00:00"
end

@testitem "time_ticks refuses to leave an axis unlabelled" tags = [:unit, :fast] begin
    using Dates: DateTime

    # 12 h is a request, not an instruction. A three-hour dashboard window would carry no tick at all
    # at that step, and a four-week one would carry fifty-six.
    short, _ = time_ticks(DateTime(2025, 7, 10, 4, 45), 3)
    @test length(short) >= 2
    @test all(≈(0.5), diff(short))

    long, _ = time_ticks(DateTime(2025, 7, 10), 672)
    @test 2 <= length(long) <= 12
    @test all(≈(168.0), diff(long))

    # Where 12 h does work it is used unchanged, including at the boundaries of the readable range.
    @test all(≈(12.0), diff(first(time_ticks(DateTime(2025, 7, 10), 24))))
    @test all(≈(12.0), diff(first(time_ticks(DateTime(2025, 7, 10), 132))))

    @test_throws ArgumentError time_ticks(DateTime(2025, 7, 10), -1)
    @test_throws ArgumentError time_ticks(DateTime(2025, 7, 10), 72; step_hours = 0)
end
