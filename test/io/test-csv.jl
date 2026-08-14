@testmodule CsvFixture begin
    using HEMSSimulator
    using CSV: CSV
    using DataFrames: DataFrame
    using Dates: DateTime, Hour
    using Statistics: mean

    const site = Site(52.1, 5.18)

    "An hourly input file covering `hours` hours from `start`, written to a temporary path."
    function write_hourly(path; start = DateTime(2024, 4, 1), n = 30, price = true)
        fine = synthetic_weather(TimeGrid(start, 4n), site; seed = 21)
        load = synthetic_load(TimeGrid(start, 4n); annual_kwh = 3500)
        prices = synthetic_prices(TimeGrid(start, 4n))
        hourly(v) = [mean(v[(4i+1):(4i+4)]) for i = 0:(n-1)]
        frame = DataFrame(
            timestamp = collect(start:Hour(1):(start+Hour(n-1))),
            ghi = hourly(fine.ghi),
            dhi = hourly(fine.dhi),
            t_amb = [fine.t_amb[4i+1] for i = 0:(n-1)],
            wind = [fine.wind[4i+1] for i = 0:(n-1)],
            load_kw = hourly(load),
        )
        price && (frame.price = hourly(prices))
        CSV.write(path, frame)
        return frame
    end
end

@testitem "CSV: an hourly file round-trips onto the 15-minute grid" tags = [:unit, :fast] setup =
    [CsvFixture] begin
    using Dates: DateTime
    using Statistics: mean

    mktempdir() do dir
        path = joinpath(dir, "home.csv")
        source = CsvFixture.write_hourly(path)
        grid = TimeGrid(DateTime(2024, 4, 1), 96)

        inputs = read_inputs(path, grid, CsvFixture.site)

        @test inputs.weather isa Weather
        @test length(inputs.weather) == 96
        @test length(inputs.load_kw) == 96
        @test length(inputs.prices) == 96

        # Irradiance is refined but its hourly energy is preserved exactly.
        for k = 0:23
            @test mean(inputs.weather.ghi[(4k+1):(4k+4)]) ≈ source.ghi[k+1] atol = 1e-9
            @test mean(inputs.weather.dhi[(4k+1):(4k+4)]) ≈ source.dhi[k+1] atol = 1e-9
        end
        @test all(inputs.weather.dhi .<= inputs.weather.ghi .+ 1e-9)

        # Load and price are interval averages: held flat, never smoothed.
        for k = 0:23
            @test allequal(inputs.load_kw[(4k+1):(4k+4)])
            @test inputs.load_kw[4k+1] == source.load_kw[k+1]
            @test inputs.prices[4k+1] == source.price[k+1]
        end

        # Temperature is an instantaneous sample, so it is interpolated.
        @test !allequal(inputs.weather.t_amb[1:4])
        @test minimum(source.t_amb) - 1 < minimum(inputs.weather.t_amb)
        @test maximum(inputs.weather.t_amb) < maximum(source.t_amb) + 1
    end
end

@testitem "CSV: optional columns fall back to sensible defaults" tags = [:unit, :fast] setup =
    [CsvFixture] begin
    using CSV: CSV
    using DataFrames: DataFrame, select!, Not
    using Dates: DateTime

    mktempdir() do dir
        path = joinpath(dir, "home.csv")
        frame = CsvFixture.write_hourly(path; price = false)
        select!(frame, Not([:dhi, :wind]))
        CSV.write(path, frame)
        grid = TimeGrid(DateTime(2024, 4, 1), 96)

        inputs = read_inputs(path, grid, CsvFixture.site)

        @test inputs.prices === nothing
        @test all(==(1.0), inputs.weather.wind)
        # No `dhi` column, so the split comes from Erbs rather than from the file.
        @test 0.0 < sum(inputs.weather.dhi) < sum(inputs.weather.ghi)
    end
end

@testitem "CSV: a bad file reports every problem at once" tags = [:unit, :fast] setup =
    [CsvFixture] begin
    using CSV: CSV
    using DataFrames: DataFrame, select!, Not
    using Dates: DateTime, Hour

    grid = TimeGrid(DateTime(2024, 4, 1), 96)
    site = CsvFixture.site

    mktempdir() do dir
        path = joinpath(dir, "home.csv")

        # Missing required columns.
        frame = CsvFixture.write_hourly(path)
        select!(frame, Not([:ghi, :load_kw]))
        CSV.write(path, frame)
        problems = validate_inputs(CSV.read(path, DataFrame), grid)
        @test length(problems) == 2
        @test any(p -> occursin("`ghi`", p), problems)
        @test any(p -> occursin("`load_kw`", p), problems)
        @test_throws ArgumentError read_inputs(path, grid, site)

        # Too short to cover the grid.
        CsvFixture.write_hourly(path; n = 6)
        problems = validate_inputs(CSV.read(path, DataFrame), grid)
        @test any(p -> occursin("covers", p), problems)

        # A gap where an hour should be.
        frame = CsvFixture.write_hourly(path)
        deleteat!(frame, 5)
        CSV.write(path, frame)
        problems = validate_inputs(CSV.read(path, DataFrame), grid)
        @test any(p -> occursin("not uniformly spaced", p), problems)

        # Negative irradiance and a hole in the load.
        frame = CsvFixture.write_hourly(path)
        frame.ghi[3] = -5.0
        frame.load_kw = convert(Vector{Union{Missing,Float64}}, frame.load_kw)
        frame.load_kw[7] = missing
        CSV.write(path, frame)
        problems = validate_inputs(CSV.read(path, DataFrame), grid)
        @test any(p -> occursin("negative irradiance", p), problems)
        @test any(p -> occursin("missing or non-finite", p), problems)
    end
end

@testitem "CSV: a file finer than the grid is refused" tags = [:unit, :fast] setup =
    [CsvFixture] begin
    using CSV: CSV
    using DataFrames: DataFrame
    using Dates: DateTime, Minute

    mktempdir() do dir
        path = joinpath(dir, "home.csv")
        CsvFixture.write_hourly(path)
        # An hourly file against an hourly grid is fine; against a two-hourly grid it is not,
        # because aggregating is a different operation from refining.
        coarse = TimeGrid(DateTime(2024, 4, 1), Minute(120), 12)
        problems = validate_inputs(CSV.read(path, DataFrame), coarse)
        @test any(p -> occursin("finer than", p), problems)
    end
end
