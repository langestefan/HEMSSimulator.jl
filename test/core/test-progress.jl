@testitem "ProgressBar counts what it is told" tags = [:unit, :fast] begin
    io = IOBuffer()
    bar = ProgressBar(10; label = "work", every = 0.0, io = io)
    for _ = 1:10
        step!(bar)
    end
    @test bar.done[] == 10

    text = String(take!(io))
    @test occursin("work", text)
    @test occursin("100%", text)
    @test endswith(text, "\n")           # the finished bar leaves the cursor on a fresh line

    # The absolute form is what `simulate`'s `progress(done, total)` hook feeds it, and it must not
    # leave the counter behind — a later `step!` would then go backwards.
    other = ProgressBar(100; every = 0.0, io = IOBuffer())
    other(60)
    @test other.done[] == 60
    step!(other)
    @test other.done[] == 61

    @test_throws ArgumentError ProgressBar(0)
    @test_throws ArgumentError ProgressBar(10; width = 0)
end

@testitem "ProgressBar totals work across threads" tags = [:unit, :fast] begin
    # The point of the atomic: several simulations report into one bar, and what it shows is the sum
    # of their windows rather than whichever thread wrote last.
    bar = ProgressBar(4000; every = 0.0, io = IOBuffer())
    Threads.@threads for _ = 1:40
        for _ = 1:100
            step!(bar)
        end
    end
    @test bar.done[] == 4000
end

@testitem "ProgressBar throttles its redraws" tags = [:unit, :fast] begin
    # A year calls back 35 040 times. Drawing every one would make the terminal the bottleneck, so
    # only the first and the last should get through a wide throttle.
    io = IOBuffer()
    bar = ProgressBar(500; every = 3600.0, io = io)
    for _ = 1:500
        step!(bar)
    end
    @test bar.done[] == 500
    @test count(==('\r'), String(take!(io))) <= 2
end

@testitem "simulate reports progress once per window" tags = [:unit, :fast] begin
    using Dates: DateTime

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 2)
    weather = synthetic_weather(grid, site; seed = 5)
    load = synthetic_load(grid; annual_kwh = 3000)
    contract = Contract(grid; commodity = synthetic_prices(grid), feed_in = 0.04)
    home = HomeSystem(
        site = site,
        pv = [PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180)],
        assets = [Battery(10.0, 5.0)],
    )
    options = RunOptions(window_hours = 24, step_hours = 6, terminal_value = false)

    seen = Tuple{Int,Int}[]
    result = simulate(home, weather, load, contract; options, progress = (d, t) -> push!(seen, (d, t)))

    # One call per window, counting up, and the total it advertises is the total it reaches — a bar
    # that never arrives at 100% reads as a hang.
    @test length(seen) == result.windows
    @test first.(seen) == 1:result.windows
    @test all(==(result.windows), last.(seen))

    # And the hook changes nothing about the answer.
    plain = simulate(home, weather, load, contract; options)
    @test result.frame.import_kw == plain.frame.import_kw
end
