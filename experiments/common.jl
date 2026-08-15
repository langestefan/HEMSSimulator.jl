# Shared scaffolding for the studies in this directory. Deliberately thin: it makes directories and
# writes files, and leaves every modelling choice to the study itself.
#
# Data and figures live in separate directories on purpose. The simulation step writes only `data/`
# and the plotting step reads it and writes only `figures/`, so it is obvious at a glance which
# files cost half an hour of solver time and which can be regenerated in a minute.

using CSV: CSV
using DataFrames: DataFrame

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
