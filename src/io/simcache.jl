"""
    simulation_key(system, inputs, options, forecast = PerfectForecast()) -> String

The cache key for one simulation: a SHA-256 digest of everything [`simulate`](@ref) reads.

That is `system`, `inputs`, `options` and the forecast — the contract is deliberately absent, because
`simulate` never sees it. Settlement happens afterwards from the flows, so two contracts that produce
the same dispatch price signal share a cached result and two that do not have different `inputs`.

The digest walks the structs by *reflection*, not through `show`: this package's `show` methods are
readable summaries, and a summary that omits a field would let a changed input hit a stale entry.

**A [`PerfectForecast`](@ref) contributes nothing to the digest**, so every key predating forecasts is
unchanged and stays valid. That is not a cosmetic choice: reflection over a struct means *adding a
field to `RunOptions` invalidates every entry in the cache*, and this package now has studies with
thousands of cached annual simulations behind them. A new option that leaves behaviour untouched at
its default should leave the keys untouched too — so put it here, next to the forecast, rather than
in `RunOptions`.
"""
function simulation_key(
    system::HomeSystem,
    inputs::SimulationInputs,
    options::RunOptions,
    forecast::AbstractForecast = PerfectForecast(),
)
    ctx = IOBuffer()
    # A version tag, so a change to what a `SimulationResult` contains invalidates every entry
    # rather than loading a frame that no longer has the columns the caller expects.
    write(ctx, "hems-simcache-v1")
    _digest!(ctx, system)
    _digest!(ctx, inputs)
    _digest!(ctx, options)
    forecast isa PerfectForecast || _digest!(ctx, forecast)
    return bytes2hex(sha256(take!(ctx)))
end

# Depth-first over the fields, writing something type-distinguishing for each. Anything this does not
# know how to reduce is an error rather than a silent `hash`: a wrong key is worse than no cache.
function _digest!(io::IO, x)
    if x isa Union{Bool,Integer,AbstractFloat}
        write(io, string(typeof(x)), '=', string(x), ';')
    elseif x isa Union{AbstractString,Symbol,DateTime,Date,Period}
        write(io, string(typeof(x)), '=', string(x), ';')
    elseif x isa Type
        write(io, "Type=", string(x), ';')
    elseif x isa AbstractArray
        write(io, "Array[", string(length(x)), ']')
        foreach(v -> _digest!(io, v), x)
        write(io, ';')
    elseif x isa Union{Tuple,NamedTuple}
        write(io, "Tuple(")
        foreach(v -> _digest!(io, v), x)
        write(io, ");")
    elseif x isa Nothing
        write(io, "nothing;")
    elseif isstructtype(typeof(x))
        write(io, string(nameof(typeof(x))), '{')
        for field in fieldnames(typeof(x))
            write(io, string(field), ':')
            _digest!(io, getfield(x, field))
        end
        write(io, "};")
    else
        throw(
            ArgumentError(
                "simulation_key cannot digest a $(typeof(x)); add a branch to `_digest!` " *
                "rather than letting it fall back to `hash`, which is not stable across sessions",
            ),
        )
    end
    return io
end

"""
    simulation_cache_dir() -> String

Where cached [`SimulationResult`](@ref)s are written. `ENV["HEMS_SIMCACHE_DIR"]` if set, otherwise a
Julia scratch space the depot garbage-collects with the package.

Kept apart from the response cache ([`get_cache`](@ref)): responses are small and worth committing
with a study, whereas a year of 15-minute flows is a few megabytes per candidate and belongs in a
scratch space, not in a repository.
"""
function simulation_cache_dir()
    dir = get(ENV, "HEMS_SIMCACHE_DIR", "")
    return isempty(dir) ? Scratch.get_scratch!(@__MODULE__, "simulations") : dir
end

"""
    clear_simulation_cache!()

Delete every cached simulation. The next run re-solves.
"""
function clear_simulation_cache!()
    dir = simulation_cache_dir()
    isdir(dir) && rm(dir; recursive = true)
    mkpath(dir)
    return dir
end

_frame_path(key) = joinpath(simulation_cache_dir(), key * ".csv")
_meta_path(key) = joinpath(simulation_cache_dir(), key * ".json")

# Everything about a result that is not the frame and not already in the caller's hands. `system` and
# `grid` are not stored: the caller passed them in to build the key, so storing them would only give
# them a second chance to disagree.
function _store_simulation(key::AbstractString, result::SimulationResult)
    dir = simulation_cache_dir()
    mkpath(dir)
    meta = Dict(
        "windows" => result.windows,
        "solve_time" => result.solve_time,
        "asset_columns" => [
            Dict(string(k) => string(v) for (k, v) in d) for d in result.asset_columns
        ],
    )
    # Write beside the target and rename, so a reader never sees half a file and two threads racing
    # on the same key leave one intact entry rather than a torn one.
    frame_tmp = _frame_path(key) * ".$(getpid()).tmp"
    meta_tmp = _meta_path(key) * ".$(getpid()).tmp"
    try
        CSV.write(frame_tmp, result.frame)
        open(io -> JSON.print(io, meta), meta_tmp, "w")
        mv(frame_tmp, _frame_path(key); force = true)
        mv(meta_tmp, _meta_path(key); force = true)
    catch
        foreach(p -> isfile(p) && rm(p; force = true), (frame_tmp, meta_tmp))
        rethrow()
    end
    return key
end

function _load_simulation(key::AbstractString, system::HomeSystem, grid::TimeGrid)
    frame_path, meta_path = _frame_path(key), _meta_path(key)
    (isfile(frame_path) && isfile(meta_path)) || return nothing
    frame = DataFrame(CSV.File(frame_path))
    # A truncated write, or a grid that somehow disagrees, is a miss rather than a wrong answer.
    nrow(frame) == grid.n || return nothing
    meta = JSON.parsefile(meta_path)
    asset_columns =
        [Dict(Symbol(k) => Symbol(v) for (k, v) in d) for d in meta["asset_columns"]]
    length(asset_columns) == length(system.assets) || return nothing
    return SimulationResult(
        grid,
        frame,
        system,
        Int(meta["windows"]),
        Float64(meta["solve_time"]),
        asset_columns,
    )
end
