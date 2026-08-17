@testitem "the EV can be scheduled on the Dutch clock" tags = [:unit, :fast] begin
    using Dates
    grid = TimeGrid(DateTime(2025, 1, 1), DateTime(2026, 1, 1))
    utc = ev_schedule(grid; departure_hour = 7.5, return_hour = 17.5)
    nl = ev_schedule(grid; departure_hour = 7.5, return_hour = 17.5, clock = :dutch)
    stamps = timestamps(grid)

    # The default must stay UTC, because changing it would silently invalidate every cached
    # simulation in every study that has already run.
    @test utc.connected != nl.connected
    first_away(s, month) =
        stamps[findfirst(k -> !s.connected[k] && Dates.month(stamps[k]) == month, 1:grid.n)]
    # January is UTC+1, July is UTC+2, so the same wall-clock departure is a different UTC hour.
    @test Dates.hour(first_away(utc, 1)) == 7
    @test Dates.hour(first_away(nl, 1)) == 6
    @test Dates.hour(first_away(utc, 7)) == 7
    @test Dates.hour(first_away(nl, 7)) == 5
    # The car is away the same number of hours either way; only their placement moves.
    @test count(!, utc.connected) == count(!, nl.connected)
    # And it still never drives at a weekend, judged on the local calendar day.
    @test all(k -> utc.connected[k], findall(t -> Dates.dayofweek(t) in (6, 7), stamps))

    @test_throws ArgumentError ev_schedule(grid; clock = :paris)
end

@testitem "dutch_hours follows summer time" tags = [:unit, :fast] begin
    using Dates
    grid = TimeGrid(DateTime(2025, 1, 1), DateTime(2026, 1, 1))
    h = dutch_hours(grid)
    stamps = timestamps(grid)
    at(t) = h[findfirst(==(t), stamps)]
    @test at(DateTime(2025, 1, 15, 12)) == 13.0     # winter, UTC+1
    @test at(DateTime(2025, 7, 15, 12)) == 14.0     # summer, UTC+2
    @test at(DateTime(2025, 3, 30, 0)) == 1.0       # just before the spring switch
    @test at(DateTime(2025, 3, 30, 1)) == 3.0       # and just after
    @test at(DateTime(2025, 10, 26, 0)) == 2.0
    @test at(DateTime(2025, 10, 26, 1)) == 2.0      # the hour that happens twice
    @test all(0 .<= h .< 24)
end
