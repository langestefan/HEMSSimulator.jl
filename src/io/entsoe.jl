"""
    EUR_PER_MWH_TO_KWH

ENTSO-E publishes clearing prices in €/MWh; every price in this package is in €/kWh.
"""
const EUR_PER_MWH_TO_KWH = 1e-3

"""
    entsoe_xml(area, period_start, period_end; client, refresh = false, tag) -> String

Fetch one raw ENTSO-E day-ahead price document and return it, going through the on-disk cache.

`ENTSOE.day_ahead_prices` will split a long period into one-year windows on its own, but it joins
the raw bodies with a comment sentinel that is no longer a parseable XML document. So this package
does its own splitting (see [`entsoe_prices`](@ref)) and asks for one document at a time, which is
also what makes each response individually cacheable and individually usable as a test fixture.
"""
function entsoe_xml(
    area::AbstractString,
    period_start::DateTime,
    period_end::DateTime;
    client,
    refresh::Bool = false,
)
    key = "entsoe|day_ahead|$area|$period_start|$period_end|$(client.base_url)"
    return cached(key; tag = "entsoe", ext = ".xml", refresh) do
        ENTSOE.day_ahead_prices(
            client,
            area,
            period_start,
            period_end,
            ENTSOE.Raw();
            # Splitting is this package's job, so make ENTSOE's own splitter a no-op.
            window = Dates.Year(100),
        )
    end
end

"""
    parse_entsoe_prices(xml::AbstractString) -> (; times, prices)

Parse an ENTSO-E day-ahead price document into UTC interval-beginning timestamps and prices in
**€/kWh**. This is the seam the loader is tested through — it takes a document, not a connection.

Duplicate timestamps are dropped. They appear when a bidding zone publishes the same period at two
market time unit resolutions, as the Dutch zone did around its move from hourly to quarter-hourly
settlement; if the two resolutions actually disagree on their grid, the mismatch surfaces from
[`source_step`](@ref) when the series is resampled.
"""
function parse_entsoe_prices(xml::AbstractString)
    series = ENTSOE.parse_timeseries(xml)
    isempty(series) && error(
        "the ENTSO-E document contains no time series. This usually means the request was " *
        "acknowledged with \"no matching data\" — check the area code and the period.",
    )
    return _sorted_unique(series.time, series.value .* EUR_PER_MWH_TO_KWH)
end

# Sort by timestamp and keep the first value at each one.
function _sorted_unique(time::AbstractVector{DateTime}, value::AbstractVector{<:Real})
    times = DateTime[]
    prices = Float64[]
    for i in sortperm(time)
        isempty(times) || times[end] != time[i] || continue
        push!(times, time[i])
        push!(prices, value[i])
    end
    return (; times, prices)
end

"""
    entsoe_prices(grid::TimeGrid; kwargs...) -> Vector{Float64}

Download ENTSO-E day-ahead clearing prices and return them in €/kWh, one value per interval of
`grid` — the measured counterpart of [`synthetic_prices`](@ref).

```julia
grid   = TimeGrid(DateTime(2023, 1, 1), DateTime(2024, 1, 1))
prices = entsoe_prices(grid)                        # token from ENV["ENTSOE_API_TOKEN"]
contract = Contract(grid; commodity = prices .+ 0.02, feed_in = 0.04)
```

This is the *wholesale* price. It is what a dynamic supplier's tariff is built from, not what the
household pays: add the supplier markup, and let [`settle`](@ref) apply energy tax and VAT.

Prices are held flat across each market time unit rather than interpolated — a quarter-hour inside
an hourly-settled period was cleared at that hour's price, and smoothing it would let the optimizer
trade on a ramp that never existed.

# Keyword arguments

  - `area`: ENTSO-E EIC code, `ENTSOE.EIC.NL` by default.
  - `client`: an `ENTSOE.Client`. Built from `ENTSOE.get_config()` / `ENV["ENTSOE_API_TOKEN"]` when
    omitted; pass `token` instead to supply the key directly.
  - `token`: API key, if you would rather not configure it globally.
  - `window`: how much of the period to request per document. ENTSO-E caps most time-series
    endpoints at one year.
  - `refresh`: re-download even when the response is already cached.
"""
function entsoe_prices(
    grid::TimeGrid;
    area::AbstractString = ENTSOE.EIC.NL,
    client = nothing,
    token::Union{Nothing,AbstractString} = nothing,
    window::Period = Dates.Year(1),
    refresh::Bool = false,
)
    resolved = if client !== nothing
        client
    elseif token !== nothing
        ENTSOE.ENTSOEClient(token)
    else
        ENTSOE.ENTSOEClient()
    end
    chunks = ENTSOE.split_period(grid.start, stop(grid); window)
    times = DateTime[]
    prices = Float64[]
    for (chunk_start, chunk_stop) in chunks
        part = parse_entsoe_prices(
            entsoe_xml(area, chunk_start, chunk_stop; client = resolved, refresh),
        )
        append!(times, part.times)
        append!(prices, part.prices)
    end
    # Consecutive windows can repeat the timestamp they share.
    joined = _sorted_unique(times, prices)
    return resample(StepHold(), joined.times, joined.prices, grid)
end
