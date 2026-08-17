# The forecast *methods*. The types themselves live in `core/forecast.jl`, because `RunOptions`
# carries a forecast and is declared before `SimulationInputs` exists — and every method here needs
# that type in its signature.

forecast_window(::PerfectForecast, truth::SimulationInputs, first::Integer, len::Integer) =
    window(truth, first, len)

# The error shape, drawn once per horizon and memoized on (forecast, length, dt). Two candidate
# batteries in the same sweep must face the same weather surprise, or the sweep is comparing luck.
const _NOISE_CACHE = Dict{Tuple{NoisyForecast,Int,Float64,Symbol},Vector{Float64}}()
const _NOISE_LOCK = ReentrantLock()

function _noise(f::NoisyForecast, n::Integer, dt::Real, which::Symbol)
    key = (f, Int(n), float(dt), which)
    Base.@lock _NOISE_LOCK begin
        haskey(_NOISE_CACHE, key) && return _NOISE_CACHE[key]
        # An AR(1) walk with the requested correlation time, scaled to unit variance so `pv_sigma`
        # means what it says regardless of the timescale chosen.
        rho = exp(-dt / f.correlation_hours)
        rng = MersenneTwister(hash((f.seed, which)))
        z = zeros(Float64, n)
        z[1] = randn(rng)
        for k = 2:n
            z[k] = rho * z[k-1] + sqrt(1 - rho^2) * randn(rng)
        end
        _NOISE_CACHE[key] = z
        return z
    end
end

function forecast_window(
    f::NoisyForecast,
    truth::SimulationInputs,
    first::Integer,
    len::Integer,
)
    slice = window(truth, first, len)
    dt = hours(truth.grid)
    pv_z = _noise(f, length(truth), dt, :pv)
    load_z = _noise(f, length(truth), dt, :load)
    price_z = _noise(f, length(truth), dt, :price)
    # Lead time is measured from the start of the window: interval 1 is happening now and is
    # therefore known, interval `len` is `len - 1` steps away and is the least certain.
    ramp(k) = 1 - exp(-((k - 1) * dt) / f.horizon_hours)
    rows = first:(first+len-1)
    pv = [
        max(0.0, slice.pv_kw[k] * (1 + f.pv_sigma * ramp(k) * pv_z[rows[k]])) for k = 1:len
    ]
    load = [
        max(0.0, slice.load_kw[k] * (1 + f.load_sigma * ramp(k) * load_z[rows[k]])) for
        k = 1:len
    ]
    # Both prices move together: they are the same spot series with different additive terms, so an
    # error in the market is common to them and must not open a spread that does not exist.
    shift(series) =
        f.price_sigma == 0 ? series :
        [series[k] * (1 + f.price_sigma * ramp(k) * price_z[rows[k]]) for k = 1:len]
    return SimulationInputs(
        slice.grid,
        pv,
        load,
        shift(slice.price_buy),
        shift(slice.price_sell),
        slice.t_amb,
        slice.ghi,
    )
end

# Dutch local time from UTC: +1 in winter, +2 between the last Sunday of March and the last Sunday of
# October, both switching at 01:00 UTC. A time-of-day study must be read on the clock the household
# lives by, or every block is smeared by an hour for half the year.
function _local_hours(grid::TimeGrid)
    last_sunday(year, month) = (
        day = Date(year, month, Dates.daysinmonth(Date(year, month)));
        day - Dates.Day(mod(Dates.dayofweek(day), 7))
    )
    stamps = timestamps(grid)
    year = Dates.year(first(stamps))
    from = DateTime(last_sunday(year, 3)) + Hour(1)
    to = DateTime(last_sunday(year, 10)) + Hour(1)
    return [Dates.hour(t + Hour(from <= t < to ? 2 : 1)) for t in stamps]
end

function forecast_window(
    f::BlockBias,
    truth::SimulationInputs,
    first::Integer,
    len::Integer,
)
    slice = window(truth, first, len)
    dt = hours(truth.grid)
    local_hour = _local_hours(truth.grid)
    ramp(k) = 1 - exp(-((k - 1) * dt) / f.horizon_hours)
    rows = first:(first+len-1)
    hit(k) = local_hour[rows[k]] in f.hours
    bend(series, bias) =
        [hit(k) ? max(0.0, series[k] * (1 + bias * ramp(k))) : series[k] for k = 1:len]
    # The absolute offset is spread evenly across the block's hours, as a power.
    per_kw = f.load_kwh / max(length(f.hours), 1)
    shift(series) =
        f.load_kwh == 0 ? series :
        [hit(k) ? max(0.0, series[k] + per_kw * ramp(k)) : series[k] for k = 1:len]
    return SimulationInputs(
        slice.grid,
        bend(slice.pv_kw, f.pv_bias),
        shift(bend(slice.load_kw, f.load_bias)),
        slice.price_buy,
        slice.price_sell,
        slice.t_amb,
        slice.ghi,
    )
end

function forecast_window(
    f::HiddenLoad,
    truth::SimulationInputs,
    first::Integer,
    len::Integer,
)
    slice = window(truth, first, len)
    dt = hours(truth.grid)
    ramp(k) = 1 - exp(-((k - 1) * dt) / f.horizon_hours)
    rows = first:(first+len-1)
    load = [max(0.0, slice.load_kw[k] - f.profile_kw[rows[k]] * ramp(k)) for k = 1:len]
    return SimulationInputs(
        slice.grid,
        slice.pv_kw,
        load,
        slice.price_buy,
        slice.price_sell,
        slice.t_amb,
        slice.ghi,
    )
end
