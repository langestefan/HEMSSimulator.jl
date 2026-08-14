@testmodule OpenMeteoFixture begin
    using HEMSSimulator
    using Dates: Date, DateTime

    const path = joinpath(@__DIR__, "..", "fixtures", "openmeteo-utrecht-2023-06-20.json")
    const site = Site(52.1, 5.18)

    "The recorded archive response: Utrecht, 2023-06-20 to 2023-06-22, hourly, UTC."
    body() = read(path, String)
    hourly() = openmeteo_parse(body())
end

@testitem "Open-Meteo: the request URL is stable and complete" tags = [:unit, :fast] begin
    using Dates: Date

    site = Site(52.1, 5.18)
    url = openmeteo_url(site, Date(2023, 6, 20), Date(2023, 6, 22))

    @test startswith(url, HEMSSimulator.OPENMETEO_ARCHIVE_URL * "?")
    @test occursin("latitude=52.1", url)
    @test occursin("longitude=5.18", url)
    @test occursin("start_date=2023-06-20", url)
    @test occursin("end_date=2023-06-22", url)
    @test occursin("timezone=UTC", url)
    # Open-Meteo defaults to km/h; a silent 3.6x error in wind speed would only show up as a
    # slightly cooler PV cell.
    @test occursin("wind_speed_unit=ms", url)
    for variable in HEMSSimulator.OPENMETEO_HOURLY
        @test occursin(variable, url)
    end

    # The URL doubles as the cache key, so it must not depend on hash ordering.
    @test url == openmeteo_url(site, Date(2023, 6, 20), Date(2023, 6, 22))
    @test occursin(
        "elevation=12.0",
        openmeteo_url(
            Site(52.1, 5.18; altitude = 12.0),
            Date(2023, 6, 20),
            Date(2023, 6, 22),
        ),
    )
    @test_throws ArgumentError openmeteo_url(site, Date(2023, 6, 22), Date(2023, 6, 20))
end

@testitem "Open-Meteo: a recorded response parses into hourly UTC series" tags =
    [:unit, :fast] setup = [OpenMeteoFixture] begin
    using Dates: DateTime, Hour

    hourly = OpenMeteoFixture.hourly()

    @test length(hourly.times) == 72
    @test first(hourly.times) == DateTime(2023, 6, 20, 0)
    @test last(hourly.times) == DateTime(2023, 6, 22, 23)
    @test HEMSSimulator.source_step(hourly.times) == Hour(1)
    for column in (:ghi, :dni, :dhi, :t_amb, :wind)
        @test length(getproperty(hourly, column)) == 72
        @test all(isfinite, getproperty(hourly, column))
    end
    @test all(>=(0), hourly.ghi)
    @test all(>=(0), hourly.wind)
    # A Dutch June: warm, and the sun gets high enough for a real peak.
    @test 5 < minimum(hourly.t_amb) < 25
    @test 500 < maximum(hourly.ghi) < 1100
end

@testitem "Open-Meteo: radiation is stamped at the END of its hour" tags = [:unit, :fast] setup =
    [OpenMeteoFixture] begin
    using Dates: Dates, DateTime, Date, Hour, Minute

    # Open-Meteo reports radiation as the mean over the *preceding* hour, so its timestamps trail
    # the interval they describe. If that lag is not undone, everything solar in this package sits
    # an hour late. Measured here as the irradiance-weighted centre of the day, compared against
    # the clear-sky centre of the same day: the correct convention is the one that lines them up.
    hourly = OpenMeteoFixture.hourly()
    site = OpenMeteoFixture.site
    day = findall(t -> Date(t) == Date(2023, 6, 21), hourly.times)
    minutes(t) = Dates.value(Minute(t - DateTime(2023, 6, 21)))

    function offset(lag)
        midpoints = hourly.times[day] .- lag .+ Minute(30)
        zenith =
            HEMSSimulator.solar_position(HEMSSimulator.observer(site), midpoints).zenith
        clear = HEMSSimulator.clearsky_ghi.(zenith)
        measured = hourly.ghi[day]
        return sum(measured .* minutes.(midpoints)) / sum(measured) -
               sum(clear .* minutes.(midpoints)) / sum(clear)
    end

    @test abs(offset(HEMSSimulator.OPENMETEO_RADIATION_LAG)) < 15
    @test offset(Hour(0)) > 45
end

@testitem "Open-Meteo: a recorded response aligns onto the simulation grid" tags =
    [:unit, :fast] setup = [OpenMeteoFixture] begin
    using Dates: Dates, DateTime, Hour, Minute
    using Statistics: mean

    hourly = OpenMeteoFixture.hourly()
    site = OpenMeteoFixture.site
    grid = TimeGrid(DateTime(2023, 6, 21), 96)

    weather = resample_weather(site, grid, hourly)

    @test weather.grid === grid
    @test length(weather) == 96
    @test all(isfinite, weather.ghi)
    @test all(weather.dhi .<= weather.ghi .+ 1e-9)

    # Hourly energy survives the refinement. Grid interval 1 is source hour 25, whose value is
    # stamped 01:00 once the lag is undone.
    for k = 0:23
        @test mean(weather.ghi[(4k+1):(4k+4)]) ≈ hourly.ghi[24+k+1+1] atol = 1e-9
    end

    # The refined peak falls inside the source's own brightest hour. Asserting it lands on solar
    # noon instead would be testing the weather: on this day the sky dimmed after 12:00 UTC, so
    # the true maximum sits before noon and the reconstruction is right to put it there.
    peak = timestamp(grid, argmax(weather.ghi))
    brightest = hourly.times[argmax(hourly.ghi)] - HEMSSimulator.OPENMETEO_RADIATION_LAG
    @test brightest <= peak < brightest + Hour(1)
    # It exceeds the hourly mean it came from, but not by a wild factor.
    @test maximum(hourly.ghi) <= maximum(weather.ghi) <= 1.3 * maximum(hourly.ghi)

    # Temperature is instantaneous: the source value reappears at its own timestamp, give or take
    # the half-interval the midpoint convention shifts it by.
    @test weather.t_amb[1] ≈ hourly.t_amb[25] rtol = 0.05
end

@testitem "Open-Meteo: missing values are filled and reported" tags = [:unit, :fast] begin
    body = """
    {"hourly_units":{},"hourly":{
      "time":["2024-01-01T00:00","2024-01-01T01:00","2024-01-01T02:00"],
      "shortwave_radiation":[0.0,null,10.0],
      "direct_normal_irradiance":[0.0,0.0,0.0],
      "diffuse_radiation":[0.0,0.0,10.0],
      "temperature_2m":[null,4.0,5.0],
      "wind_speed_10m":[2.0,2.0,null]}}
    """
    hourly = @test_logs (:warn,) (:warn,) (:warn,) openmeteo_parse(body)
    @test hourly.ghi == [0.0, 0.0, 10.0]     # forward-filled
    @test hourly.t_amb == [4.0, 4.0, 5.0]    # back-filled, there is no earlier value
    @test hourly.wind == [2.0, 2.0, 2.0]

    @test_throws ErrorException openmeteo_parse("not json at all")
    @test_throws ErrorException openmeteo_parse("""{"error":true,"reason":"nope"}""")
end

@testitem "Open-Meteo: downloading a real year" tags = [:integration, :network] begin
    using Dates: Date, DateTime

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2023, 1, 1), DateTime(2024, 1, 1))
    weather = openmeteo_weather(site, grid)

    @test length(weather) == 35_040

    # Annual global irradiation. Open-Meteo returned 1083-1208 kWh/m² for Utrecht over 2019-2024,
    # which tracks KNMI's measured annual totals for De Bilt; the older "about 1000 kWh/m²" rule of
    # thumb is a long-term average that Dutch years have run above for over a decade.
    annual = sum(weather.ghi) * hours(grid) / 1000
    @test 950 < annual < 1250

    # A south-facing 35 degree array. This lands near the top of the usual 900-1000 kWh/kWp quoted
    # for Dutch installations, because ERA5's diffuse fraction here is about 0.41 against the ~0.55
    # of ground measurements, and a more direct sky rewards tilt more.
    array = PVArray(dc_capacity_kwp = 1.0, ac_capacity_kw = 1.0, tilt = 35, azimuth = 180)
    @test 850 < annual_yield(array, site, weather) < 1150

    # The re-derived direct normal component reproduces the one Open-Meteo reports. That is the
    # check that matters for the closure equation: their three components agree with each other to
    # 0.1%, so ours must not drift from theirs.
    hourly = openmeteo_parse(
        HEMSSimulator.openmeteo_fetch(
            openmeteo_url(site, Date(2023, 1, 1), Date(2024, 1, 1)),
        ),
    )
    @test sum(weather.dni) * hours(grid) ≈ sum(hourly.dni[2:8761]) rtol = 0.02
end
