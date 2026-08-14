"""
    AbstractResampler

How a timestamped source series is mapped onto a [`TimeGrid`](@ref). Every external data source in
this package arrives on its own clock — Open-Meteo publishes hourly, ENTSO-E publishes hourly or
quarter-hourly depending on the market time unit, a CSV file publishes whatever the user has — and
all of it has to land on the simulation grid before anything else happens.

The choice is not cosmetic. It encodes what a number *means*:

  - [`StepHold`](@ref) for quantities that are constant over their own interval — prices above all.
    Interpolating a price invents trades at prices that were never quoted.
  - [`LinearInterp`](@ref) for quantities sampled instantaneously and varying smoothly between
    samples — ambient temperature, wind speed.

Irradiance is neither, and has its own routine: see [`upsample_irradiance`](@ref).
"""
abstract type AbstractResampler end

"""
    StepHold()

The sample stamped at `t` applies unchanged over `[t, t + step)`. Use for prices, and for any
quantity reported as a per-interval average that must not be smoothed.
"""
struct StepHold <: AbstractResampler end

"""
    LinearInterp()

Linear interpolation between samples, evaluated at the **midpoint** of each target interval — which
is the mean of a linearly-varying quantity over that interval, and matches the convention
[`solar_positions`](@ref) uses. Within the final half source-step the value is held flat rather than
extrapolated.
"""
struct LinearInterp <: AbstractResampler end

"""
    source_step(times::AbstractVector{DateTime}) -> Millisecond

Infer the sampling step of `times`, throwing a descriptive `ArgumentError` if the series is not
strictly increasing or not uniformly spaced.

Uniformity is required rather than repaired. A gap in a weather download or a daylight-saving jump
in a CSV written in local time is a data problem, and silently interpolating across it would hide a
missing day inside an annual energy figure that still looks plausible.
"""
function source_step(times::AbstractVector{DateTime})
    length(times) >= 2 || throw(
        ArgumentError("need at least two timestamps to infer a step, got $(length(times))"),
    )
    step = times[2] - times[1]
    step > Millisecond(0) || throw(
        ArgumentError(
            "timestamps must be strictly increasing, but times[1] = $(times[1]) and " *
            "times[2] = $(times[2])",
        ),
    )
    for i = 3:length(times)
        times[i] - times[i-1] == step && continue
        throw(
            ArgumentError(
                "timestamps are not uniformly spaced: the series steps by $step up to index " *
                "$(i - 1), but times[$(i - 1)] = $(times[i - 1]) and times[$i] = $(times[i]) " *
                "are $(times[i] - times[i - 1]) apart. Repair the gap (or convert local time " *
                "to UTC) before resampling.",
            ),
        )
    end
    return Millisecond(step)
end

"""
    stop(grid::TimeGrid) -> DateTime

Timestamp one step past the last interval, i.e. the exclusive end of the horizon `[start, stop)`.
"""
stop(grid::TimeGrid) = grid.start + grid.step * grid.n

# The source is required to cover the horizon in the step-hold sense: its first sample must start no
# later than the grid, and its last sample must still be in force at the end of the grid. Linear
# interpolation then holds flat inside the trailing half-step rather than extrapolating, which is
# what lets an hourly series ending at 23:00 cover a grid ending at midnight.
function _check_coverage(
    times::AbstractVector{DateTime},
    step::Millisecond,
    grid::TimeGrid,
    what::AbstractString,
)
    grid_stop = stop(grid)
    covered_stop = last(times) + step
    if times[1] > grid.start || covered_stop < grid_stop
        throw(
            ArgumentError(
                "$what covers [$(times[1]), $covered_stop) but the time grid needs " *
                "[$(grid.start), $grid_stop). Request a wider period from the data source.",
            ),
        )
    end
    return nothing
end

"""
    resample(method, times, values, grid::TimeGrid) -> Vector{Float64}

Map the series `values`, sampled at `times`, onto `grid` using `method` — a [`StepHold`](@ref) or a
[`LinearInterp`](@ref).

`times` must be uniformly spaced (see [`source_step`](@ref)) and must cover the whole grid; both are
checked up front so a short download is reported against the download rather than surfacing as a
strange dispatch result. Timestamps follow the package convention: interval-beginning, UTC.

# Examples

```jldoctest
julia> using Dates

julia> grid = TimeGrid(DateTime(2024, 1, 1), 4);

julia> times = [DateTime(2024, 1, 1), DateTime(2024, 1, 1, 1)];

julia> resample(StepHold(), times, [10.0, 20.0], grid)
4-element Vector{Float64}:
 10.0
 10.0
 10.0
 10.0
```
"""
function resample end

function resample(
    ::StepHold,
    times::AbstractVector{DateTime},
    values::AbstractVector{<:Real},
    grid::TimeGrid,
)
    length(times) == length(values) ||
        throw(ArgumentError("got $(length(times)) timestamps but $(length(values)) values"))
    step = source_step(times)
    _check_coverage(times, step, grid, "the source series")
    step_ms = step.value
    origin = times[1]
    out = Vector{Float64}(undef, grid.n)
    for k = 1:grid.n
        offset = Millisecond(timestamp(grid, k) - origin).value
        out[k] = values[fld(offset, step_ms)+1]
    end
    return out
end

function resample(
    ::LinearInterp,
    times::AbstractVector{DateTime},
    values::AbstractVector{<:Real},
    grid::TimeGrid,
)
    length(times) == length(values) ||
        throw(ArgumentError("got $(length(times)) timestamps but $(length(values)) values"))
    step = source_step(times)
    _check_coverage(times, step, grid, "the source series")
    step_ms = step.value
    origin = times[1]
    half = Millisecond(grid.step).value / 2
    last_i = length(values) - 1
    out = Vector{Float64}(undef, grid.n)
    for k = 1:grid.n
        # Evaluate at the interval midpoint: for a linearly varying quantity that equals its mean
        # over the interval.
        x = (Millisecond(timestamp(grid, k) - origin).value + half) / step_ms
        i = clamp(floor(Int, x) + 1, 1, last_i)
        f = clamp(x - (i - 1), 0.0, 1.0)
        out[k] = (1 - f) * values[i] + f * values[i+1]
    end
    return out
end

"""
    group_indices(times, step, grid::TimeGrid) -> Vector{Int}

For each interval of `grid`, the index of the source sample whose interval contains it. Used by
routines that have to conserve energy per source interval, such as [`upsample_irradiance`](@ref).
"""
function group_indices(times::AbstractVector{DateTime}, step::Millisecond, grid::TimeGrid)
    step_ms = step.value
    origin = times[1]
    return [
        Int(fld(Millisecond(timestamp(grid, k) - origin).value, step_ms)) + 1 for
        k = 1:grid.n
    ]
end
