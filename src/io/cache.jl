"""
    CacheConfig

Where and whether downloaded responses are cached on disk. Read it with [`get_cache`](@ref), change
it with [`set_cache`](@ref).

A cache is not a convenience here, it is what makes a sizing study reproducible. A sweep re-runs the
same year of weather and prices for every candidate battery, and Open-Meteo's archive is revised as
ERA5 is reanalysed, so an uncached study can silently change its inputs between two runs of the same
script.

# Fields

  - `dir::String`: directory holding the cached response bodies. Defaults to `ENV["HEMS_CACHE_DIR"]`
    if set, otherwise a Julia scratch space that the depot garbage-collects with the package.
  - `enabled::Bool`: when `false`, every request goes to the network and nothing is written.
"""
mutable struct CacheConfig
    dir::String
    enabled::Bool
end

const _CACHE = Ref{Union{Nothing,CacheConfig}}(nothing)

function _default_cache_dir()
    dir = get(ENV, "HEMS_CACHE_DIR", "")
    return isempty(dir) ? Scratch.get_scratch!(@__MODULE__, "responses") : dir
end

"""
    get_cache() -> CacheConfig

The current response-cache configuration, initialising it on first use.
"""
function get_cache()
    cfg = _CACHE[]
    cfg === nothing || return cfg
    cfg = CacheConfig(_default_cache_dir(), true)
    _CACHE[] = cfg
    return cfg
end

"""
    set_cache(; dir = nothing, enabled = nothing) -> CacheConfig

Update the response cache. Keywords left as `nothing` keep their current value.

```julia
HEMSSimulator.set_cache(; dir = "data/responses")   # commit the responses with the study
HEMSSimulator.set_cache(; enabled = false)          # always hit the network
```
"""
function set_cache(;
    dir::Union{Nothing,AbstractString} = nothing,
    enabled::Union{Nothing,Bool} = nothing,
)
    cfg = get_cache()
    dir === nothing || (cfg.dir = String(dir))
    enabled === nothing || (cfg.enabled = enabled)
    return cfg
end

"""
    cache_path(key::AbstractString; tag = "response", ext = ".txt") -> String

Path a response with cache key `key` is stored at. The key is hashed, so it may be any string that
uniquely identifies the request — a full request URL is the usual choice. `tag` is a readable prefix
so the directory can be inspected by hand.
"""
function cache_path(key::AbstractString; tag::AbstractString = "response", ext = ".txt")
    digest = bytes2hex(sha256(key))[1:24]
    return joinpath(get_cache().dir, string(tag, "-", digest, ext))
end

"""
    clear_cache!() -> Int

Delete every cached response and return how many files were removed.
"""
function clear_cache!()
    dir = get_cache().dir
    isdir(dir) || return 0
    files = readdir(dir; join = true)
    foreach(rm, files)
    return length(files)
end

"""
    cached(fetch, key; tag = "response", ext = ".txt", refresh = false) -> String

Return the cached body for `key`, calling `fetch()` and storing its result if there is no hit. Pass
`refresh = true` to re-fetch and overwrite. With the cache disabled ([`set_cache`](@ref)) this is
just `fetch()`.

The write goes to a temporary file that is then moved into place, so an interrupted download cannot
leave a truncated body behind that later runs would happily read.
"""
function cached(
    fetch::Function,
    key::AbstractString;
    tag::AbstractString = "response",
    ext = ".txt",
    refresh::Bool = false,
)
    cfg = get_cache()
    cfg.enabled || return String(fetch())
    path = cache_path(key; tag, ext)
    if !refresh && isfile(path)
        return read(path, String)
    end
    body = String(fetch())
    mkpath(dirname(path))
    tmp = tempname(dirname(path); cleanup = false)
    write(tmp, body)
    mv(tmp, path; force = true)
    return body
end
