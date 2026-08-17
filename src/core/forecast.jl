"""
    AbstractForecast

What the controller *believes* the next window holds, as distinct from what actually happens.

Every simulation in this package until now has optimized against the truth. That is the right
default — it measures what the assets are physically worth — but it is an upper bound, and the gap
between it and a real controller is the value of a forecast. This type is how that gap is measured.

The receding horizon was built for exactly this: the controller re-plans every step, so a forecast
error is not a mistake it is stuck with, only one it acts on for a single interval before seeing more
of the truth. What survives that correction is the real cost of not knowing.

# The contract

A forecast implements one method:

    forecast_window(f, truth::SimulationInputs, first::Integer, len::Integer) -> SimulationInputs

returning what the controller believes about intervals `first : first+len-1`. It must return a
`SimulationInputs` on the same grid slice as `window(truth, first, len)`; only the *values* differ.

It is a value rather than a function so that it can be digested into the simulation cache key: two
runs differing only in their forecast are different simulations, and a cache that could not tell them
apart would answer the wrong one.

# What is worth perturbing, and what is not

**Day-ahead prices are not a forecast in this market.** The Dutch day-ahead auction clears around
midday for every hour of the following day, so at any moment prices are *known* between 12 and 36
hours ahead — longer than the 24 h window this study optimizes over. Perturbing them would measure
the value of information the controller already has. Weather and household load are the genuinely
unknown quantities, and they are what [`NoisyForecast`](@ref) moves.
"""
abstract type AbstractForecast end

"""
    PerfectForecast()

The controller knows exactly what happens. This is the default and reproduces the behaviour of every
simulation written before forecasts existed, bit for bit.
"""
struct PerfectForecast <: AbstractForecast end

"""
    NoisyForecast(; pv_sigma = 0.15, load_sigma = 0.30, horizon_hours = 1.5,
                  correlation_hours = 6.0, seed = 1)

A forecast whose error grows with lead time and is **correlated in time**.

# Why correlated

White noise is the wrong model and would flatter the controller badly. An optimizer facing
independent per-interval errors simply averages them out — the plan it makes is close to the plan it
would have made knowing the truth, because the errors cancel within any few hours. Real forecasts do
not fail that way. They fail by getting *the shape of the day* wrong: an afternoon forecast sunny
turns out cloudy, and every interval in it is wrong in the same direction at once. That is the error
a battery actually pays for, so it is the error modelled here.

The error series is an Ornstein-Uhlenbeck-style random walk with a `correlation_hours` timescale,
drawn once for the whole horizon and indexed by *target* time. A given interval therefore has a
consistent bias whichever window looks at it, and the bias shrinks as the interval approaches:

    believed(target) = truth(target) * (1 + sigma * ramp(lead) * z(target))

with `ramp(lead) = 1 - exp(-lead / horizon_hours)`, which is zero at zero lead and saturates at one.
The interval being implemented right now is therefore known exactly, which is correct — a controller
acting on the current quarter-hour is metering it, not predicting it.

# Keyword arguments

  - `pv_sigma`, `load_sigma`: relative error at saturation, as a fraction. Defaults are broadly a
    day-ahead irradiance forecast and a single household's load, which is far noisier than a
    substation's because there is no aggregation to smooth it.
  - `horizon_hours`: lead time at which the error reaches `1 - 1/e` of its saturation value.
    **This is the parameter that decides the answer, and it is easy to set far too high.** An early
    version of this used 12 h, which gives the controller a 2.8% view of one hour ahead — nothing
    about a single household's 15-minute load is that predictable. It made imperfect foresight look
    almost free, and it was an artefact: near-term accuracy is exactly what protects the evening
    discharge decision, where the controller judges how much charge tonight needs before selling the
    rest. Measured at 6 kWp with a 10 kWh battery, moving from a 12 h ramp to a 0.5 h one raised the
    annual cost of the same saturation error from EUR 3.06 to EUR 13.05, and the battery sold 34 kWh
    a year more than it should have — energy then bought back across a 13.3 ct/kWh spread. The
    default of 1.5 h puts roughly a fifth of the saturation error one hour out, which is the right
    order for a household.
  - `correlation_hours`: how long an error persists. Short values approach white noise and will
    understate the cost of forecasting badly.
  - `seed`: the draw is deterministic given the seed, so a study is reproducible and two candidate
    batteries face *the same weather surprise* rather than being scored against different luck.

Prices are deliberately untouched; see [`AbstractForecast`](@ref).
"""
struct NoisyForecast <: AbstractForecast
    pv_sigma::Float64
    load_sigma::Float64
    horizon_hours::Float64
    correlation_hours::Float64
    seed::Int
end

function NoisyForecast(;
    pv_sigma::Real = 0.15,
    load_sigma::Real = 0.30,
    horizon_hours::Real = 1.5,
    correlation_hours::Real = 6.0,
    seed::Integer = 1,
)
    pv_sigma >= 0 || throw(ArgumentError("pv_sigma must be non-negative; got $pv_sigma"))
    load_sigma >= 0 ||
        throw(ArgumentError("load_sigma must be non-negative; got $load_sigma"))
    horizon_hours > 0 ||
        throw(ArgumentError("horizon_hours must be positive; got $horizon_hours"))
    correlation_hours > 0 || throw(
        ArgumentError("correlation_hours must be positive; got $correlation_hours"),
    )
    return NoisyForecast(
        float(pv_sigma),
        float(load_sigma),
        float(horizon_hours),
        float(correlation_hours),
        Int(seed),
    )
end
