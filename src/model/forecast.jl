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
    return SimulationInputs(
        slice.grid,
        pv,
        load,
        slice.price_buy,
        slice.price_sell,
        slice.t_amb,
        slice.ghi,
    )
end
