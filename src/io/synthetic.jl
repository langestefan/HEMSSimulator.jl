const HOURS_IN_DAY = 24

# Hours since midnight as a real number, which every shape in this file is a function of.
_hour_of_day(t::DateTime) = Dates.hour(t) + Dates.minute(t) / 60

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
        hour = _hour_of_day(t)
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
        hour = _hour_of_day(t)
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

# Distance between two hours-of-day, the short way round the clock, so 23:45 sits next to 00:00
# instead of 24 hours away from it.
_clock_distance(hour::Real, centre::Real) =
    (d = abs(hour - centre); min(d, HOURS_IN_DAY - d))

# Roughly flat, with an evening peak and a small-hours trough. A pure function of time of day, which
# is what makes the daily mean exactly normalisable below.
_baseload_shape(hour::Real) =
    1.0 + 0.40 * exp(-_clock_distance(hour, 19.5)^2 / 6.0) -
    0.25 * exp(-_clock_distance(hour, 3.5)^2 / 8.0)

"""
    baseload(grid::TimeGrid; average_kw = 0.3, jitter = 0.12, seed = 4) -> Vector{Float64}

Generate an always-on household consumption in kW, one element per interval, whose mean over any
whole day is `average_kw`.

The shape is nearly flat — an evening peak around 19:30 and a shallow trough in the small hours, a
1.9:1 swing between them — because this is the standing draw of a house (fridge, ventilation, router,
standby), not its activity profile. Multiplicative noise of ±`jitter` keeps consecutive intervals
from being identical; it is zero-mean, so a day still averages `average_kw` to within a percent or so
rather than exactly.

There is deliberately **no seasonal or weekday variation**: the contract of this function is that
`average_kw` is what any day draws, so a fortnight in January and a fortnight in July are comparable.
Use [`synthetic_load`](@ref) instead when you want a household profile with pronounced morning and
evening peaks, scaled to an annual energy rather than a mean power.

The two are alternatives, not layers. Adding `baseload` on top of `synthetic_load` gives a house
that consumes the sum of both, which is almost never what is meant — 0.3 kW is 2 628 kWh a year, a
whole household, not a trickle on top of one.

The step must divide a day evenly, which is what makes "the mean over a day" well defined.

# Examples

```jldoctest
julia> using Statistics: mean

julia> grid = TimeGrid(DateTime(2025, 1, 1), 96 * 7);

julia> series = baseload(grid; average_kw = 0.3);

julia> round(mean(series); digits = 3)
0.301

julia> round(maximum(series) / minimum(series); digits = 1)
2.4
```
"""
function baseload(
    grid::TimeGrid;
    average_kw::Real = 0.3,
    jitter::Real = 0.12,
    seed::Integer = 4,
)
    average_kw >= 0 ||
        throw(ArgumentError("average_kw must be non-negative; got $average_kw"))
    0 <= jitter < 1 || throw(ArgumentError("jitter must be in [0, 1); got $jitter"))
    per_day = intervals_per_day(grid)

    # The shape repeats every day, so the mean over one day's worth of sample offsets *is* its mean
    # over the whole horizon. Normalising by it makes `average_kw` exact before the noise goes on —
    # and the offsets come from the grid's start and step, not from `grid.n`, so a horizon shorter
    # than a day is scaled by the same factor as a year.
    step = hours(grid)
    origin = _hour_of_day(grid.start)
    offsets = [mod(origin + (i - 1) * step, HOURS_IN_DAY) for i = 1:per_day]
    normaliser = sum(_baseload_shape, offsets) / per_day

    rng = MersenneTwister(seed)
    scale = average_kw / normaliser
    return [
        scale * _baseload_shape(_hour_of_day(t)) * (1 + jitter * (2 * rand(rng) - 1)) for
        t in timestamps(grid)
    ]
end

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
        hour = _hour_of_day(t)
        shape =
            1 + 0.55 * exp(-((hour - 8.0)^2) / 3.0) + 0.85 * exp(-((hour - 18.5)^2) / 5.0) -
            0.95 * exp(-((hour - 13.0)^2) / 6.0)
        prices[k] = level[Date(t)] * shape + 0.01 * (rand(rng) - 0.5)
    end
    return prices
end
