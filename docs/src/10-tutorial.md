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

## The four scenarios

A Dutch household faces two policy questions at once — whether annual netting still applies, and
whether transport is billed as a flat capacity charge or by time of use. [`scenarios`](@ref) builds
all four combinations from one set of prices:

```@example tutorial
regimes = scenarios(grid; commodity = prices .+ 0.02, feed_in = 0.04)
keys(regimes)
```

The defaults for tax, the tax credit and VAT come from [`NL_TARIFFS_2025`](@ref) — read its
docstring before quoting any of the numbers below, because two of those figures are representative
rather than published. The time-of-use tariff is [`peak_transport_tariff`](@ref), a two-block
weekday-evening peak whose levels are yours to set.

The axes are not two versions of the same lever. Netting absorbs the commodity price and the energy
tax; transport is charged on *physical* flow and is never netted. So a time-of-use tariff pays a
battery whether or not netting applies, while ending netting changes what an exported kWh is worth
at all.

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

## Sizing across all four scenarios

Pass the whole scenario set instead of one contract and the sweep stacks a block per regime. Each is
simulated independently, because the contract changes the price signal the controller sees and
therefore the flows — not just the bill computed from them.

```@example tutorial
across = sweep(
    home, weather, load, regimes,
    [Battery(kwh, kwh / 2; degradation_cost = 0.05) for kwh in 2.5:2.5:10.0];
    investment = b -> Investment(
        capex = 1000 + 450 * b.capacity_kwh,
        lifetime_years = 15,
        discount_rate = 0.04,
    ),
)
select(across, :scenario, :capacity_kwh, :annual_savings, :npv)
```

[`best_by_scenario`](@ref) picks the winner within each regime — use it rather than `best` on a
stacked table, which would return the single globally best row and say nothing about the others:

```@example tutorial
select(best_by_scenario(across), :scenario, :capacity_kwh, :annual_savings, :payback_years)
```

That table is the deliverable. What a battery is worth is not one number but four, and on the
package's own synthetic data they differ by more than any single modelling assumption in it.

## Adding a car

An EV is not a second battery. It is away when the sun is up on exactly the days its owner commutes,
it must be full enough to leave in the morning, and unless V2G is switched on the energy that goes
into it never comes back out to the house.

```@example tutorial
ev = ElectricVehicle(
    grid;
    capacity_kwh = 60.0,
    charge_power_kw = 11.0,
    km_per_day = 45,          # or kwh_per_day, or a function of the Date
    departure_hour = 7.5,
    return_hour = 17.5,
    target_soc = 0.8,         # required before each departure
)

with_car = HomeSystem(site = site, pv = home.pv, assets = [ev])
run = simulate(with_car, weather, load, without_netting)

(
    driven_kwh = round(sum(ev.trip_kwh), digits = 1),
    charged_kwh = round(ev_energy_kwh(run), digits = 1),
)
```

The charging is flexible; the departure is not. That is the whole reason to model a car rather than
adding its consumption to the base load — the optimizer moves the charging to the cheap hours, but
only within the window before each deadline.

```@example tutorial
using Statistics
paid = sum(run.frame.ev_charge_kw .* run.frame.price_buy) / sum(run.frame.ev_charge_kw)
(paid = round(paid, digits = 4), if_unmanaged = round(mean(run.frame.price_buy[ev.connected]), digits = 4))
```

Sizing a battery for this home keeps the car in both arms of the comparison, so what is reported is
what the battery adds on top of a car that was already shifting its own load:

```@example tutorial
select(
    sweep(
        with_car, weather, load, without_netting,
        [Battery(kwh, kwh / 2; degradation_cost = 0.05) for kwh in 2.5:2.5:15.0];
        investment = b -> Investment(capex = 1000 + 450 * b.capacity_kwh),
    ),
    :capacity_kwh, :annual_savings, :npv,
)
```

Compare that column of savings against the one without a car. On its own a battery saturates —
past a point there is no more PV surplus or price spread for extra capacity to capture. The car is a
large shiftable load that keeps the marginal kWh of storage earning, so the savings keep climbing.
Sizing for a household that is about to buy an EV, without modelling the EV, understates what the
larger battery would do.

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
