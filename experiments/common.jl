# Shared scaffolding for the studies in this directory. Deliberately thin: it makes directories and
# writes files, and leaves every modelling choice to the study itself.

using CSV: CSV
using DataFrames: DataFrame

"""
    results_dir(script) -> String

The `results/` directory beside the calling script, created if needed.
"""
function results_dir(script::AbstractString)
    path = joinpath(dirname(abspath(script)), "results")
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
    save_figure(dir, name, figure) -> String

Write a Makie figure as PNG and return the path.
"""
function save_figure(dir::AbstractString, name::AbstractString, figure)
    path = joinpath(dir, name * ".png")
    save(path, figure)
    println("  wrote ", relpath(path))
    return path
end
