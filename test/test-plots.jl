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
