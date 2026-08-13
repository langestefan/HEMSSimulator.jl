"""
    clearsky_ghi(zenith) -> Float64

Haurwitz clear-sky global horizontal irradiance, W/m². A one-parameter model — accurate enough to
generate plausible test data, not accurate enough to size a real system against.
"""
function clearsky_ghi(zenith::Real)
    cosz = cosd(zenith)
    cosz <= COS_ZENITH_MIN && return 0.0
    return 1098 * cosz * exp(-0.059 / cosz)
end

"""
    synthetic_weather(grid::TimeGrid, site::Site; seed = 1, clear_fraction = 0.34) -> Weather

Generate a plausible Dutch weather year: clear-sky irradiance modulated by a daily cloudiness
factor, split into direct and diffuse with [`Erbs`](@ref), plus a temperature series with a seasonal
and a diurnal swing.

The point of this is that every test, docstring and example in the package runs without an external
data file. It is not a substitute for measured weather.

Cloudiness is drawn per day from a *bimodal* distribution — `clear_fraction` of days are bright and
the rest are overcast — rather than from a single average. That matters more than it looks: a
constant middling clearness index puts the Erbs correlation permanently in its high-diffuse regime,
which produces a sky that is 85% diffuse and an array tilt that barely changes the yield. Real skies
alternate, and the resulting diffuse fraction lands near the Dutch value of just over half.
"""
function synthetic_weather(
    grid::TimeGrid,
    site::Site;
    seed::Integer = 1,
    clear_fraction::Real = 0.34,
)
    rng = MersenneTwister(seed)
    times = timestamps(grid)
    positions = solar_positions(site, grid)

    # One cloudiness draw per day, so consecutive intervals are correlated the way real weather is.
    days = unique(Date.(times))
    cloud = Dict{Date,Float64}()
    for day in days
        seasonal = 0.05 * sin(2π * (dayofyear(day) - 172) / 365)
        base =
            rand(rng) < clear_fraction ? 0.88 + 0.12 * rand(rng) : 0.16 + 0.42 * rand(rng)
        cloud[day] = clamp(base + seasonal, 0.06, 1.0)
    end

    ghi = zeros(Float64, grid.n)
    t_amb = zeros(Float64, grid.n)
    wind = zeros(Float64, grid.n)
    for k = 1:grid.n
        t = times[k]
        ghi[k] = clearsky_ghi(positions.zenith[k]) * cloud[Date(t)]
        hour = Dates.hour(t) + Dates.minute(t) / 60
        seasonal = 9.5 * sin(2π * (dayofyear(t) - 110) / 365)
        diurnal = 4.0 * sin(2π * (hour - 15) / 24)
        t_amb[k] = 10.5 + seasonal + diurnal + 1.5 * (rand(rng) - 0.5)
        wind[k] = 2.0 + 1.5 * rand(rng)
    end

    dni, dhi = decompose(Erbs(), ghi, positions.zenith, times)
    return Weather(grid; ghi, dni, dhi, t_amb, wind)
end

"""
    synthetic_load(grid::TimeGrid; annual_kwh = 3000.0, seed = 2) -> Vector{Float64}

Generate a household base load in kW, one element per interval, scaled so the series integrates to
`annual_kwh` per year. The shape is a flat base with a morning and an evening peak, mildly higher in
winter and at weekends — enough structure that self-consumption and peak-shaving behave sensibly.
"""
function synthetic_load(grid::TimeGrid; annual_kwh::Real = 3000.0, seed::Integer = 2)
    rng = MersenneTwister(seed)
    times = timestamps(grid)
    shape = zeros(Float64, grid.n)
    for k = 1:grid.n
        t = times[k]
        hour = Dates.hour(t) + Dates.minute(t) / 60
        morning = 0.9 * exp(-((hour - 7.5)^2) / 2.0)
        evening = 1.6 * exp(-((hour - 19.0)^2) / 4.0)
        winter = 1 + 0.18 * cos(2π * (dayofyear(t) - 15) / 365)
        weekend = isweekend(t) ? 1.15 : 1.0
        shape[k] = (0.22 + morning + evening) * winter * weekend * (0.85 + 0.3 * rand(rng))
    end
    years = grid.n * hours(grid) / 8760
    scale = annual_kwh * years / (sum(shape) * hours(grid))
    return shape .* scale
end

isweekend(t::DateTime) = dayofweek(t) in (6, 7)

"""
    synthetic_prices(grid::TimeGrid; mean_eur = 0.09, seed = 3) -> Vector{Float64}

Generate a day-ahead-like wholesale price series in €/kWh: a diurnal shape with a morning and
evening peak, a midday solar-driven dip that occasionally goes negative, and day-to-day variation.

Negative prices are included on purpose. They are common on the Dutch market and they are the case
that breaks the linear-programming assumption that wasting energy costs money — see the note on
[`solve_window`](@ref).
"""
function synthetic_prices(grid::TimeGrid; mean_eur::Real = 0.09, seed::Integer = 3)
    rng = MersenneTwister(seed)
    times = timestamps(grid)
    days = unique(Date.(times))
    level = Dict(day => mean_eur * (0.55 + 0.9 * rand(rng)) for day in days)
    prices = zeros(Float64, grid.n)
    for k = 1:grid.n
        t = times[k]
        hour = Dates.hour(t) + Dates.minute(t) / 60
        shape =
            1 + 0.55 * exp(-((hour - 8.0)^2) / 3.0) + 0.85 * exp(-((hour - 18.5)^2) / 5.0) -
            0.95 * exp(-((hour - 13.0)^2) / 6.0)
        prices[k] = level[Date(t)] * shape + 0.01 * (rand(rng) - 0.5)
    end
    return prices
end
