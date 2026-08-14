"""
    INPUT_COLUMNS

The CSV schema [`read_inputs`](@ref) accepts.

| Column      | Unit  | Required | Meaning                                                        |
|:------------|:------|:---------|:---------------------------------------------------------------|
| `timestamp` | UTC   | yes      | interval **beginning**, uniformly spaced                        |
| `ghi`       | W/m²  | yes      | global horizontal irradiance, mean over the interval            |
| `t_amb`     | °C    | yes      | ambient dry-bulb temperature, instantaneous                     |
| `load_kw`   | kW    | yes      | household base load, mean over the interval                     |
| `dhi`       | W/m²  | no       | diffuse horizontal irradiance; estimated with [`Erbs`](@ref) if absent |
| `wind`      | m/s   | no       | wind speed at 10 m; 1.0 m/s if absent                           |
| `price`     | €/kWh | no       | wholesale commodity price                                       |

`dni` is deliberately not read: it is re-derived from `ghi` and `dhi` so the three components close
at every interval. See [`upsample_irradiance`](@ref).
"""
const INPUT_COLUMNS =
    (required = (:timestamp, :ghi, :t_amb, :load_kw), optional = (:dhi, :wind, :price))

"""
    validate_inputs(table, grid::TimeGrid) -> Vector{String}

Check a loaded input table against `grid` and return every problem found, as human-readable
sentences. An empty vector means the table is usable.

Returning all the problems rather than throwing on the first one is deliberate: a hand-assembled
input file usually has several, and finding them one download-edit-rerun cycle at a time is the
slowest way to discover that the file is also in local time.
"""
function validate_inputs(table, grid::TimeGrid)
    problems = String[]
    for column in INPUT_COLUMNS.required
        hasproperty(table, column) ||
            push!(problems, "required column `$column` is missing")
    end
    isempty(problems) || return problems

    times = _input_timestamps(table.timestamp, problems)
    times === nothing && return problems

    try
        step = source_step(times)
        step >= grid.step || push!(
            problems,
            "the file is sampled every $step, finer than the $(grid.step) simulation grid; " *
            "aggregate it before loading",
        )
        covered = last(times) + step
        if times[1] > grid.start || covered < stop(grid)
            push!(
                problems,
                "the file covers [$(times[1]), $covered) but the grid needs " *
                "[$(grid.start), $(stop(grid)))",
            )
        end
    catch err
        err isa ArgumentError || rethrow()
        push!(problems, sprint(showerror, err))
    end

    for column in (INPUT_COLUMNS.required..., INPUT_COLUMNS.optional...)
        column === :timestamp && continue
        hasproperty(table, column) || continue
        values = getproperty(table, column)
        bad = count(v -> v === missing || !isfinite(v), values)
        bad == 0 ||
            push!(problems, "column `$column` has $bad missing or non-finite values")
        column in (:ghi, :dhi) &&
            any(v -> v !== missing && v < 0, values) &&
            push!(problems, "column `$column` has negative irradiance values")
    end
    return problems
end

function _input_timestamps(column, problems::Vector{String})
    eltype(column) <: DateTime && return collect(DateTime, column)
    try
        return [t isa DateTime ? t : DateTime(String(t)) for t in column]
    catch err
        push!(
            problems,
            "column `timestamp` could not be read as ISO-8601 UTC timestamps " *
            "($(sprint(showerror, err)))",
        )
        return nothing
    end
end

"""
    read_inputs(path, grid::TimeGrid, site::Site; kwargs...) -> (; weather, load_kw, prices)

Read a CSV of measured inputs and align every series to `grid`. See [`INPUT_COLUMNS`](@ref) for the
schema.

```julia
inputs = read_inputs("home.csv", grid, site)
result = simulate(home, inputs.weather, inputs.load_kw, contract)
```

The file is validated in full before anything is resampled, and a bad file raises one error listing
everything wrong with it ([`validate_inputs`](@ref)).

Series are resampled according to what they mean, not uniformly: irradiance through the clearness
index ([`upsample_irradiance`](@ref)), temperature and wind by linear interpolation, load and price
by holding each source interval flat. `prices` is `nothing` when the file has no `price` column —
useful when prices come from [`entsoe_prices`](@ref) instead.
"""
function read_inputs(path::AbstractString, grid::TimeGrid, site::Site; csv_kwargs...)
    table = CSV.read(path, DataFrame; csv_kwargs...)
    problems = validate_inputs(table, grid)
    isempty(problems) || throw(
        ArgumentError(
            "cannot use `$path` as simulation input:\n" *
            join(("  - " * p for p in problems), "\n"),
        ),
    )

    times = _input_timestamps(table.timestamp, String[])
    # `collect(Float64, ...)` narrows the `Union{Missing, Float64}` element type CSV.jl infers for
    # any column that merely *looks* like it might have gaps. Validation has already ruled that out.
    column(name) = collect(Float64, getproperty(table, name))
    dhi = hasproperty(table, :dhi) ? column(:dhi) : nothing
    irradiance = upsample_irradiance(site, grid, times, column(:ghi); dhi)
    wind = if hasproperty(table, :wind)
        resample(LinearInterp(), times, column(:wind), grid)
    else
        fill(1.0, grid.n)
    end

    weather = Weather(
        grid;
        ghi = irradiance.ghi,
        dni = irradiance.dni,
        dhi = irradiance.dhi,
        t_amb = resample(LinearInterp(), times, column(:t_amb), grid),
        wind = wind,
    )
    return (;
        weather,
        load_kw = resample(StepHold(), times, column(:load_kw), grid),
        prices = hasproperty(table, :price) ?
                 resample(StepHold(), times, column(:price), grid) : nothing,
    )
end
