"""
    TimeGrid(start, step, n)

A uniform simulation time grid. All simulations in this package run on one of these, and every
exogenous series is expected to have exactly `n` elements aligned to it.

# Fields

  - `start::DateTime`: timestamp of the first interval (interval-beginning convention, UTC).
  - `step::Minute`: interval length. The package is designed around `Minute(15)`.
  - `n::Int`: number of intervals.

# Examples

```jldoctest
julia> using Dates

julia> grid = TimeGrid(DateTime(2024, 1, 1), Minute(15), 96);

julia> hours(grid)
0.25

julia> last(timestamps(grid))
2024-01-01T23:45:00
```
"""
struct TimeGrid
    start::DateTime
    step::Minute
    n::Int

    function TimeGrid(start::DateTime, step::Minute, n::Integer)
        step > Minute(0) || throw(ArgumentError("step must be positive, got $step"))
        n > 0 || throw(ArgumentError("n must be positive, got $n"))
        return new(start, step, Int(n))
    end
end

"""
    TimeGrid(start::DateTime, n::Integer)

Construct a 15-minute grid of `n` intervals, the resolution this package is built around.
"""
TimeGrid(start::DateTime, n::Integer) = TimeGrid(start, Minute(15), n)

"""
    TimeGrid(start::DateTime, stop::DateTime; step = Minute(15))

Construct a grid covering `[start, stop)`.
"""
function TimeGrid(start::DateTime, stop::DateTime; step::Minute = Minute(15))
    stop > start || throw(ArgumentError("stop must be after start"))
    total = Millisecond(stop - start).value
    unit = Millisecond(step).value
    total % unit == 0 || throw(
        ArgumentError("span from $start to $stop is not a whole number of $step intervals"),
    )
    return TimeGrid(start, step, total ÷ unit)
end

Base.length(grid::TimeGrid) = grid.n

"""
    hours(grid::TimeGrid) -> Float64

Interval length in hours. This is the factor converting a power in kW to an energy in kWh.
"""
hours(grid::TimeGrid) = Millisecond(grid.step).value / 3_600_000

"""
    timestamps(grid::TimeGrid) -> Vector{DateTime}

Interval-beginning timestamps, one per interval.
"""
timestamps(grid::TimeGrid) = collect(grid.start:grid.step:(grid.start+grid.step*(grid.n-1)))

"""
    timestamp(grid::TimeGrid, k::Integer) -> DateTime

Interval-beginning timestamp of interval `k`.
"""
timestamp(grid::TimeGrid, k::Integer) = grid.start + grid.step * (k - 1)

"""
    window(grid::TimeGrid, first::Integer, len::Integer) -> TimeGrid

The sub-grid of `len` intervals starting at interval `first`. Used by the rolling-horizon driver to
slice a window out of the simulation horizon; `len` is clipped at the end of `grid`.
"""
function window(grid::TimeGrid, first::Integer, len::Integer)
    1 <= first <= grid.n || throw(BoundsError(grid, first))
    return TimeGrid(timestamp(grid, first), grid.step, min(len, grid.n - first + 1))
end

"""
    intervals_per_day(grid::TimeGrid) -> Int

Number of intervals in 24 hours. Throws if the step does not divide a day evenly.
"""
function intervals_per_day(grid::TimeGrid)
    per_day = 86_400_000 ÷ Millisecond(grid.step).value
    86_400_000 % Millisecond(grid.step).value == 0 ||
        throw(ArgumentError("step $(grid.step) does not divide a day evenly"))
    return Int(per_day)
end

"""
    checkseries(grid::TimeGrid, series, name::AbstractString)

Throw a descriptive `ArgumentError` unless `series` has one element per interval of `grid`. Used at
the boundary of every model builder so that a length mismatch is reported against the input that
caused it rather than surfacing as an opaque failure inside JuMP.
"""
function checkseries(grid::TimeGrid, series::AbstractVector, name::AbstractString)
    length(series) == grid.n || throw(
        ArgumentError(
            "$name has $(length(series)) elements but the time grid has $(grid.n) intervals",
        ),
    )
    return nothing
end

"""
    isweekend(t::DateTime) -> Bool

Whether `t` falls on a Saturday or Sunday. Used by load profiles and by time-of-use tariffs, which
in the Netherlands are usually defined on working days only.
"""
isweekend(t::DateTime) = dayofweek(t) in (6, 7)
