@testitem "TimeGrid geometry" tags = [:unit, :fast] begin
    using Dates: DateTime, Minute

    grid = TimeGrid(DateTime(2024, 1, 1), 96)
    @test length(grid) == 96
    @test hours(grid) == 0.25
    @test intervals_per_day(grid) == 96
    @test timestamp(grid, 1) == DateTime(2024, 1, 1)
    @test timestamp(grid, 96) == DateTime(2024, 1, 1, 23, 45)
    @test length(timestamps(grid)) == 96

    year = TimeGrid(DateTime(2024, 1, 1), DateTime(2025, 1, 1))
    @test length(year) == 366 * 96  # 2024 is a leap year
end

@testitem "TimeGrid windowing" tags = [:unit, :fast] begin
    using Dates: DateTime

    grid = TimeGrid(DateTime(2024, 1, 1), 100)
    w = window(grid, 10, 20)
    @test length(w) == 20
    @test w.start == timestamp(grid, 10)

    # A window running past the end is clipped rather than throwing, so the final window of a
    # horizon is simply shorter.
    @test length(window(grid, 95, 20)) == 6
end

@testitem "TimeGrid rejects malformed input" tags = [:unit, :fast] begin
    using Dates: DateTime, Minute

    @test_throws ArgumentError TimeGrid(DateTime(2024, 1, 1), Minute(0), 10)
    @test_throws ArgumentError TimeGrid(DateTime(2024, 1, 1), Minute(15), 0)
    @test_throws ArgumentError TimeGrid(DateTime(2024, 1, 1), DateTime(2023, 1, 1))
    # Ten minutes past midnight is not a whole number of quarter hours.
    @test_throws ArgumentError TimeGrid(DateTime(2024, 1, 1), DateTime(2024, 1, 1, 0, 10))
end
