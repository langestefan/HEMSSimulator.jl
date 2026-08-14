# CHANGELOG

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog],
and this project adheres to [Semantic Versioning].

## [Unreleased]

### Added

- Home energy management simulator on JuMP: 15-minute resolution, receding horizon (48 h window,
  24 h step) with perfect foresight inside each window.
- PV modelling from GHI/DNI/DHI: solar geometry via SolarPosition.jl, Erbs decomposition,
  isotropic / Hay-Davies / Perez transposition, NOCT cell temperature, per-array inverter clipping,
  multiple arrays per home.
- `Battery` asset with efficiencies, self-discharge, optional throughput degradation cost and an
  optional binary charge/discharge exclusivity formulation.
- `AbstractAsset` contract so assets attach their own variables, constraints and objective terms to
  one shared model.
- Dutch settlement engine: annual netting (*salderen*) as a `net_metering_fraction` parameter,
  feed-in compensation, energy tax and tax credit, VAT, fixed capacity or time-varying transport
  tariffs, all prorated to the simulated period.
- Business case layer: `Investment`, NPV / IRR / payback, and a `sweep` over candidate battery sizes
  producing a KPI table.
- Synthetic weather, load and price generators so examples and tests run without external data.
- Degeneracy detection for the cases where the linear program cannot represent reality (negative
  prices, equal buy and sell prices under full netting).
- Measured inputs: ERA5 reanalysis weather from the Open-Meteo archive (`openmeteo_weather`),
  day-ahead wholesale prices from ENTSO-E through ENTSOE.jl (`entsoe_prices`), and a validated CSV
  schema (`read_inputs`, `validate_inputs`).
- Resampling layer aligning any source series to the simulation grid: `StepHold` for prices,
  `LinearInterp` for instantaneous samples, and `upsample_irradiance`, which refines hourly
  irradiance through the clearness index and conserves each source interval's energy exactly.
- On-disk response cache keyed by the request (`set_cache`, `get_cache`, `clear_cache!`), so a
  sizing sweep downloads a year once and re-runs against unchanged inputs.
- The four headline regulatory scenarios as values: `scenarios` builds netting on/off ×
  fixed/time-varying transport from one set of prices, `peak_transport_tariff` and `peak_intervals`
  express a time-of-use network tariff, and `sweep` accepts the whole set to produce a scenario ×
  size table that `best_by_scenario` reduces to one winner per regime.
- `NL_TARIFFS_2025`, a named and dated set of Dutch tariff defaults, replacing the literals
  previously scattered through the contract and tariff definitions.

### Changed

- Default `energy_tax` is now the 2025 *energiebelasting* rate of 0.10154 €/kWh; it was the 2024
  rate of 0.10880 €/kWh.

<!-- Links -->

[keep a changelog]: https://keepachangelog.com/en/1.1.0/
[semantic versioning]: https://semver.org/spec/v2.0.0.html

<!-- Versions -->

[unreleased]: https://github.com/langestefan/BatteryBusinessCase.jl/compare/v0.1.0...HEAD
