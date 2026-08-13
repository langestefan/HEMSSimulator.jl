# Sizing a home battery

This walkthrough builds a Dutch home, simulates it, bills it under two regulatory regimes, and
sweeps battery sizes to find the one worth buying. It runs on synthetic weather and prices, so you
can execute it without any data files.

## The home

A home is a location, some PV arrays, and whatever the optimizer controls.

```@example tutorial
using BatteryBusinessCase
using Dates

site = Site(52.1, 5.18)                     # Utrecht
grid = TimeGrid(DateTime(2024, 3, 1), DateTime(2024, 4, 1))

home = HomeSystem(
    site = site,
    pv = [
        PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180),
    ],
)
```

Azimuth follows the solar convention used by
[SolarPosition.jl](https://github.com/JuliaAstro/SolarPosition.jl): 0° is north and angles increase
clockwise, so 180° is south. Several arrays are allowed and each is clipped at its own inverter
rating — which is why an east/west pair can beat a single south array on a small inverter.

## Inputs

Weather, base load and wholesale prices. The synthetic generators exist so that examples and tests
never need an external file; swap in measured data when you have it.

```@example tutorial
weather = synthetic_weather(grid, site)
load    = synthetic_load(grid; annual_kwh = 3500)
prices  = synthetic_prices(grid)

round(sum(weather.ghi) * hours(grid) / 1000, digits = 1)   # kWh/m² of irradiation this month
```

The contract turns wholesale prices into what the household actually pays and receives.

```@example tutorial
contract = Contract(
    grid;
    commodity = prices .+ 0.02,        # supplier markup, €/kWh
    feed_in = 0.04,                    # terugleververgoeding, €/kWh
    net_metering_fraction = 1.0,       # full salderen
)
nothing # hide
```

## Simulating

```@example tutorial
result = simulate(home, weather, load, contract)
```

`simulate` runs a receding horizon: each solve optimizes 48 hours with perfect foresight, keeps the
first 24, carries the asset states forward and advances. The overlap is what stops the optimizer
emptying storage at every boundary — and it is the structure a forecast model plugs into later,
because switching off perfect foresight means changing the data sliced into each window, not the
loop.

Every flow is in `result.frame`, one row per 15-minute interval:

```@example tutorial
using DataFrames
first(select(result.frame, :timestamp, :load_kw, :pv_available_kw, :import_kw, :export_kw), 4)
```

## Billing

Dispatch and settlement are deliberately separate. The optimizer sees a simple per-interval price;
the bill is computed afterwards from the flows, because annual netting couples the whole year and no
receding-horizon objective can represent it.

```@example tutorial
settle(result, contract)
```

Turning off net metering is a change to the contract, not to any code path:

```@example tutorial
without_netting = Contract(
    grid;
    commodity = prices .+ 0.02,
    feed_in = 0.04,
    net_metering_fraction = 0.0,
)
settle(simulate(home, weather, load, without_netting), without_netting)
```

The same parameter expresses a phase-out: `net_metering_fraction = 0.36` is a year in which just
over a third of exported energy is still netted.

## Sizing the battery

Sizing is done by simulating each candidate rather than by making capacity a decision variable.
That costs more solves, but every candidate is then judged under the real billing rules — including
the annual netting cap, which an investment LP cannot see.

```@example tutorial
candidates = [Battery(kwh, kwh / 2; degradation_cost = 0.05) for kwh in 2.5:2.5:15.0]

table = sweep(
    home, weather, load, without_netting, candidates;
    investment = b -> Investment(
        capex = 1000 + 450 * b.capacity_kwh,
        lifetime_years = 15,
        discount_rate = 0.04,
    ),
)
select(table, :capacity_kwh, :annual_savings, :npv, :payback_years, :cycles_per_year)
```

Over a full year with these assumptions the optimum lands around 5 kWh, at roughly a 9-year payback.
A month is not a year, so treat the numbers above as a demonstration of the mechanics.

`best` returns the winning row and warns when the optimum sits at the edge of the candidate range,
which usually means the range did not bracket it:

```@example tutorial
best(table).capacity_kwh
```

## Things worth knowing

**Negative prices break the linear program.** The LP avoids charging and discharging at once only
because wasting energy costs money. When prices go negative — routine on the Dutch market — burning
energy becomes profitable and the LP will cycle storage to dump kWh. `RunOptions(check_degeneracy =
true)` (the default) warns when this happens; `RunOptions(exclusive = true)` adds the binaries that
fix it, at the cost of a slower solve.

**Under full salderen a battery arbitrages the retail price, tax included.** That makes storage look
extremely attractive and drives very high cycle counts. Set `degradation_cost` on the battery to
make the optimizer trade cycling against margin, and check `cycles_per_year` against what the
warranty allows.

**Self-consumption is attributed per interval**, as `min(PV, on-site demand)`. Once a battery can
export energy it charged from the grid, total export stops being a proxy for un-consumed PV.
