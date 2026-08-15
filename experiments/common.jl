# Shared scaffolding for the studies in this directory. Deliberately thin: it makes directories and
# writes files, and leaves every modelling choice to the study itself.
#
# Data and figures live in separate directories on purpose. The simulation step writes only `data/`
# and the plotting step reads it and writes only `figures/`, so it is obvious at a glance which
# files cost half an hour of solver time and which can be regenerated in a minute.

using CSV: CSV
using DataFrames: DataFrame
using Dates: Dates, Minute
using HEMSSimulator: TimeGrid, Weather, timestamps

"""
    data_dir(script) -> String

The `data/` directory beside the calling script, created if needed. Written by the simulation step,
read by everything else.
"""
function data_dir(script::AbstractString)
    path = joinpath(dirname(abspath(script)), "data")
    mkpath(path)
    return path
end

"""
    figures_dir(script) -> String

The `figures/` directory beside the calling script, created if needed. Written by the plotting step
alone; nothing reads it back.
"""
function figures_dir(script::AbstractString)
    path = joinpath(dirname(abspath(script)), "figures")
    mkpath(path)
    return path
end

"""
    save_table(dir, name, table) -> String

Write `table` as CSV and return the path, announcing it so a run's output lists what it produced.
"""
function save_table(dir::AbstractString, name::AbstractString, table::DataFrame)
    path = joinpath(dir, name * ".csv")
    CSV.write(path, table)
    println("  wrote ", relpath(path))
    return path
end

"""
    read_table(dir, name) -> DataFrame

Read back a CSV written by [`save_table`](@ref).
"""
read_table(dir::AbstractString, name::AbstractString) =
    CSV.read(joinpath(dir, name * ".csv"), DataFrame)

"""
    save_figure(dir, name, figure) -> String

Write a Makie figure as PNG and return the path.
"""
function save_figure(dir::AbstractString, name::AbstractString, figure)
    path = joinpath(dir, name * ".png")
    save(path, figure)
    println("  wrote ", relpath(path))
    return path
end

"""
    save_inputs(dir, grid, weather, prices, load) -> String

Write every exogenous series a study consumed to `inputs.csv`, in full.

"In full" is the point. A study's other scripts must be able to rebuild the *exact* run without a
network or an API token — so this saves all five weather columns, not the two that happen to be
interesting to look at. Saving GHI alone makes the file readable and the run irreproducible.
"""
save_inputs(dir::AbstractString, grid, weather, prices, load) = save_table(
    dir,
    "inputs",
    DataFrame(
        timestamp = timestamps(grid),
        day_ahead_eur_kwh = prices,
        load_kw = load,
        ghi_w_m2 = weather.ghi,
        dni_w_m2 = weather.dni,
        dhi_w_m2 = weather.dhi,
        t_amb_c = weather.t_amb,
        wind_m_s = weather.wind,
    ),
)

"""
    load_inputs(dir) -> (; grid, weather, prices, load)

Rebuild what [`save_inputs`](@ref) wrote. No network, no credentials — everything a plotting or
exploration script needs is already on disk.
"""
function load_inputs(dir::AbstractString)
    table = read_table(dir, "inputs")
    stamps = table.timestamp
    grid = TimeGrid(
        first(stamps),
        Minute(Dates.value(Minute(stamps[2] - stamps[1]))),
        length(stamps),
    )
    weather = Weather(
        grid;
        ghi = table.ghi_w_m2,
        dni = table.dni_w_m2,
        dhi = table.dhi_w_m2,
        t_amb = table.t_amb_c,
        wind = table.wind_m_s,
    )
    return (;
        grid,
        weather,
        prices = collect(Float64, table.day_ahead_eur_kwh),
        load = collect(Float64, table.load_kw),
    )
end
