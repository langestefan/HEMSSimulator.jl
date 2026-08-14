# Real data

The tutorial runs on synthetic inputs so that it needs no files and no credentials. This page
replaces them with measured ones: reanalysis weather from Open-Meteo, day-ahead prices from
ENTSO-E, and anything else from a CSV.

Everything lands on the same [`TimeGrid`](@ref) the simulation runs on, and every timestamp in this
package is **UTC** and marks the **beginning** of its interval. Those two conventions are the whole
job of this layer.

## Weather

```julia
using BatteryBusinessCase, Dates

site = Site(52.1, 5.18)                                       # Utrecht
grid = TimeGrid(DateTime(2023, 1, 1), DateTime(2024, 1, 1))   # a full year at 15 minutes

weather = openmeteo_weather(site, grid)
```

[`openmeteo_weather`](@ref) calls the Open-Meteo [Historical Weather
API](https://open-meteo.com/en/docs/historical-weather-api), which serves ERA5 reanalysis and needs
no API key for non-commercial use. It publishes hourly; the loader refines that to 15 minutes.

Two details in that response are easy to get wrong, so the package handles both explicitly:

- **Radiation is stamped at the end of its hour.** Open-Meteo reports irradiance as the mean over
    the *preceding* hour, while temperature at the same stamp is instantaneous. Radiation
    timestamps are therefore shifted back by [`BatteryBusinessCase.OPENMETEO_RADIATION_LAG`](@ref)
    before anything else happens. Skipping that step puts the modelled solar day an hour late,
    which quietly shifts every overlap between production and evening load.
- **Wind is requested in m/s.** The API defaults to km/h, and a 3.6× error there shows up only as
    a slightly cooler PV cell — plausible enough to survive review.

The archive lags real time by about five days; hours with no data yet come back as `null`, are
filled from their neighbours, and are reported with a warning.

Two things are worth knowing before quoting a yield from this data. Annual global irradiation for
Utrecht comes back between 1083 and 1208 kWh/m² over 2019–2024, which tracks KNMI's measured
totals — the familiar "about 1000 kWh/m²" figure is a long-term average that Dutch years have run
above for over a decade. But the reanalysis puts the diffuse fraction near 0.41 where ground
measurements suggest closer to 0.55, and a more direct sky rewards array tilt more. A south-facing
35° array therefore models at roughly 1090 kWh/kWp here, at the top of the 900–1000 kWh/kWp usually
quoted for Dutch installations. The three components are mutually consistent to 0.1%, so this is a
property of the reanalysis, not of the loader — treat it as an optimistic case and size against a
range.

## Prices

```julia
prices = entsoe_prices(grid)      # EUR/kWh, token from ENV["ENTSOE_API_TOKEN"]

contract = Contract(grid; commodity = prices .+ 0.02, feed_in = 0.04)
```

[`entsoe_prices`](@ref) wraps [ENTSOE.jl](https://github.com/langestefan/EntsoE.jl). It needs a
Transparency Platform security token — a UUID you request from `transparency@entsoe.eu` — which it
picks up from `ENV["ENTSOE_API_TOKEN"]`, from `ENTSOE.set_config(; token = …)`, or from the `token`
keyword.

What comes back is the **wholesale** price in €/MWh; the loader converts it to €/kWh. It is not what
the household pays: add the supplier markup to get the commodity price, and let [`settle`](@ref)
apply energy tax and VAT on top.

## From a file

```julia
inputs = read_inputs("home.csv", grid, site)
result = simulate(home, inputs.weather, inputs.load_kw, contract)
```

[`read_inputs`](@ref) reads the schema documented at [`INPUT_COLUMNS`](@ref) — `timestamp`, `ghi`,
`t_amb` and `load_kw` are required, `dhi`, `wind` and `price` are optional. The file is checked in
full before anything is resampled, and a bad one raises a single error listing every problem
[`validate_inputs`](@ref) found, rather than surfacing the first one and hiding the rest.

## Caching

Every download goes through an on-disk cache keyed by the request itself:

```julia
BatteryBusinessCase.set_cache(; dir = "data/responses")   # keep the responses with the study
BatteryBusinessCase.set_cache(; enabled = false)          # always hit the network
BatteryBusinessCase.clear_cache!()
```

The default location is a Julia scratch space, or `ENV["BBC_CACHE_DIR"]` if that is set.

This matters beyond speed. A sizing sweep re-simulates the same year for every candidate battery,
and ERA5 is revised as it is reanalysed — so without a cache the same script can quietly compare
candidates against slightly different weather.

## Resampling, and why it is not one function

An hourly series can be put on a 15-minute grid in more than one way, and the right choice depends
on what the number means.

Prices are held flat across their market time unit ([`StepHold`](@ref)). A quarter-hour inside an
hourly-settled period cleared at that hour's price; interpolating would hand the optimizer a ramp
to trade against that never existed. Temperature and wind are instantaneous samples of something
smooth, so they are interpolated ([`LinearInterp`](@ref)) at each interval's midpoint.

Irradiance is neither, and gets its own routine. Holding it flat gives a sunrise that switches on in
one step; interpolating it smears the ramps and misplaces the peak. What actually varies slowly is
the *sky*, so [`upsample_irradiance`](@ref) works on the clearness index instead — divide out a
clear-sky reference, interpolate that, and multiply back at each fine interval's real solar
position, then rescale so each source hour's energy is preserved exactly.

```@example data
using BatteryBusinessCase, Dates, Statistics

site = Site(52.1, 5.18)
fine = TimeGrid(DateTime(2024, 6, 21), 96)

# Pretend an hourly source by averaging a synthetic 15-minute day.
truth = synthetic_weather(fine, site; seed = 5)
times = collect(DateTime(2024, 6, 21):Hour(1):DateTime(2024, 6, 21, 23))
hourly = [mean(truth.ghi[(4i+1):(4i+4)]) for i = 0:23]

refined = upsample_irradiance(site, fine, times, hourly)
held = resample(StepHold(), times, hourly, fine)

(
    clearness_error = sum(abs, refined.ghi - truth.ghi) / sum(truth.ghi),
    step_hold_error = sum(abs, held - truth.ghi) / sum(truth.ghi),
)
```

Energy conservation is the invariant that makes this safe to trust: each source interval's mean
survives the refinement exactly, so an annual yield computed from refined data equals the one
computed from the hourly data it came from.

```@example data
maximum(abs(mean(refined.ghi[(4k+1):(4k+4)]) - hourly[k+1]) for k = 0:23)
```

Direct normal irradiance is never interpolated. It is re-derived from the refined global and
diffuse components as `DNI = (GHI − DHI) / cos z`, so the three stay mutually consistent at every
interval — which is what the transposition models in [`poa`](@ref) assume.
