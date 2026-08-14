"""
    OPENMETEO_ARCHIVE_URL

Endpoint of the Open-Meteo Historical Weather API, `https://archive-api.open-meteo.com/v1/archive`.
It serves ERA5 reanalysis and needs no API key for non-commercial use. Data lags real time by about
five days.
"""
const OPENMETEO_ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"

"""
    OPENMETEO_HOURLY

The hourly variables this package requests: global horizontal, direct normal and diffuse horizontal
irradiance in W/m², 2 m air temperature in °C, and 10 m wind speed.
"""
const OPENMETEO_HOURLY = [
    "shortwave_radiation",
    "direct_normal_irradiance",
    "diffuse_radiation",
    "temperature_2m",
    "wind_speed_10m",
]

"""
    OPENMETEO_RADIATION_LAG

How far a radiation timestamp trails the interval it describes. Open-Meteo reports radiation as the
**mean over the preceding hour**, so the value stamped `12:00` is the average over `11:00`–`12:00`,
while temperature and wind at the same stamp are instantaneous.

This package stamps every interval with its *beginning*, so radiation timestamps are shifted back by
this amount before resampling. Getting it wrong moves the modelled solar peak an hour off solar
noon and quietly biases every self-consumption figure downstream, which is why it is a named
constant with a test behind it rather than an inline `Hour(1)`.
"""
const OPENMETEO_RADIATION_LAG = Hour(1)

"""
    openmeteo_url(site::Site, start_date::Date, end_date::Date; base_url, variables) -> String

The archive request URL for `site` over `[start_date, end_date]` inclusive, in UTC. Both dates are
inclusive on Open-Meteo's side, so the last day contributes hours `00:00` through `23:00`.

The query is assembled in a fixed order because the URL doubles as the cache key (see
[`cached`](@ref)); a `Dict` would reorder it and defeat the cache between sessions.
"""
function openmeteo_url(
    site::Site,
    start_date::Date,
    end_date::Date;
    base_url::AbstractString = OPENMETEO_ARCHIVE_URL,
    variables::AbstractVector{<:AbstractString} = OPENMETEO_HOURLY,
)
    end_date >= start_date ||
        throw(ArgumentError("end_date $end_date is before start_date $start_date"))
    query = [
        "latitude" => string(site.latitude),
        "longitude" => string(site.longitude),
        "start_date" => string(start_date),
        "end_date" => string(end_date),
        "hourly" => join(variables, ","),
        "wind_speed_unit" => "ms",
        "timezone" => "UTC",
    ]
    # Left at Open-Meteo's own 90 m digital elevation model unless the site says otherwise.
    site.altitude == 0 || push!(query, "elevation" => string(site.altitude))
    return string(base_url, "?", join(("$k=$(HTTP.escapeuri(v))" for (k, v) in query), "&"))
end

"""
    openmeteo_fetch(url; refresh = false, timeout = 60) -> String

Download `url` and return the response body, going through the on-disk cache. Open-Meteo reports
errors as JSON with a `reason` field rather than as a plain status line, so that reason is unwrapped
into the exception message.
"""
function openmeteo_fetch(url::AbstractString; refresh::Bool = false, timeout::Real = 60)
    return cached(url; tag = "openmeteo", ext = ".json", refresh) do
        response = HTTP.get(
            url;
            status_exception = false,
            connect_timeout = timeout,
            # HTTP 2 renames this to `request_timeout`; the package is pinned to HTTP 1 because
            # ENTSOE.jl's cassette-driven tests cannot run above 1.11.
            readtimeout = timeout,
        )
        body = String(response.body)
        response.status == 200 && return body
        reason = try
            get(JSON.parse(body), "reason", body)
        catch
            body
        end
        error("Open-Meteo returned HTTP $(response.status): $reason\nrequest: $url")
    end
end

"""
    openmeteo_parse(body::AbstractString) -> NamedTuple

Turn an Open-Meteo archive response into `(; times, ghi, dni, dhi, t_amb, wind)`, all hourly, all
UTC, with the timestamps exactly as the API stamped them — no lag correction is applied here. See
[`resample_weather`](@ref) for that step.

Gaps (JSON `null`, which the archive returns for the most recent few days) are filled from the
neighbouring value and reported with a warning, because a silent zero in an irradiance column is
indistinguishable from a genuinely dark hour.
"""
function openmeteo_parse(body::AbstractString)
    doc = try
        JSON.parse(body)
    catch err
        error("Open-Meteo response is not valid JSON ($err): $(first(body, 200))")
    end
    haskey(doc, "hourly") ||
        error("Open-Meteo response has no `hourly` block: $(first(body, 200))")
    hourly = doc["hourly"]
    times = DateTime.(String.(hourly["time"]))
    return (;
        times,
        ghi = _openmeteo_column(hourly, "shortwave_radiation"),
        dni = _openmeteo_column(hourly, "direct_normal_irradiance"),
        dhi = _openmeteo_column(hourly, "diffuse_radiation"),
        t_amb = _openmeteo_column(hourly, "temperature_2m"),
        wind = _openmeteo_column(hourly, "wind_speed_10m"),
    )
end

function _openmeteo_column(hourly, name::AbstractString)
    haskey(hourly, name) || error(
        "Open-Meteo response has no `$name` column; it returned " *
        "$(join(sort(collect(keys(hourly))), ", "))",
    )
    raw = hourly[name]
    out = fill(NaN, length(raw))
    for i in eachindex(raw)
        raw[i] === nothing || (out[i] = Float64(raw[i]))
    end
    gaps = count(isnan, out)
    gaps == length(out) && error("Open-Meteo returned no data at all for `$name`")
    if gaps > 0
        @warn "Open-Meteo returned $gaps missing values for `$name`; filling from neighbours. \
               The archive lags real time by about five days."
        for i = 2:length(out)
            isnan(out[i]) && (out[i] = out[i-1])
        end
        for i = (length(out)-1):-1:1
            isnan(out[i]) && (out[i] = out[i+1])
        end
    end
    return out
end

"""
    resample_weather(site, grid, hourly; radiation_lag = OPENMETEO_RADIATION_LAG) -> Weather

Align an hourly source — the NamedTuple returned by [`openmeteo_parse`](@ref) — onto `grid`.

Irradiance goes through [`upsample_irradiance`](@ref) after its timestamps are shifted back by
`radiation_lag` to the interval-beginning convention. Temperature and wind are instantaneous
samples and are interpolated linearly. Open-Meteo's own direct-normal column is *not* used: DNI is
re-derived from the upsampled GHI and DHI so the three components close at every interval.

This is the seam the loader is tested through: it takes data, not a network connection.
"""
function resample_weather(
    site::Site,
    grid::TimeGrid,
    hourly::NamedTuple;
    radiation_lag::Period = OPENMETEO_RADIATION_LAG,
)
    irradiance = upsample_irradiance(
        site,
        grid,
        hourly.times .- radiation_lag,
        hourly.ghi;
        dhi = hourly.dhi,
    )
    return Weather(
        grid;
        ghi = irradiance.ghi,
        dni = irradiance.dni,
        dhi = irradiance.dhi,
        t_amb = resample(LinearInterp(), hourly.times, hourly.t_amb, grid),
        wind = resample(LinearInterp(), hourly.times, hourly.wind, grid),
    )
end

"""
    openmeteo_weather(site::Site, grid::TimeGrid; kwargs...) -> Weather

Download ERA5 reanalysis weather for `site` and return it aligned to `grid` — the measured
counterpart of [`synthetic_weather`](@ref).

```julia
site = Site(52.1, 5.18)
grid = TimeGrid(DateTime(2023, 1, 1), DateTime(2024, 1, 1))
weather = openmeteo_weather(site, grid)
```

Whole UTC days are requested so that a partial grid still gets the surrounding hours it needs, and
the response is cached on disk (see [`set_cache`](@ref)) — a sizing sweep re-uses one download for
every candidate battery.

# Keyword arguments

  - `base_url`: override the endpoint, e.g. to point at a self-hosted Open-Meteo instance.
  - `refresh`: re-download even if the response is already cached.
  - `timeout`: seconds allowed for connecting and for reading, each.
  - `radiation_lag`: see [`OPENMETEO_RADIATION_LAG`](@ref).
"""
function openmeteo_weather(
    site::Site,
    grid::TimeGrid;
    base_url::AbstractString = OPENMETEO_ARCHIVE_URL,
    refresh::Bool = false,
    timeout::Real = 60,
    radiation_lag::Period = OPENMETEO_RADIATION_LAG,
)
    url = openmeteo_url(site, Date(grid.start), Date(stop(grid)); base_url)
    hourly = openmeteo_parse(openmeteo_fetch(url; refresh, timeout))
    return resample_weather(site, grid, hourly; radiation_lag)
end
