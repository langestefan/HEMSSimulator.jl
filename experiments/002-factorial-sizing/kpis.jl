# Turning one finished simulation into one row of the results table.
#
# Kept out of `run.jl` so it can be exercised without launching 400 annual simulations, and so
# anything reading the study back has the definitions in front of it.
#
# Everything here is derived from the *result frame*, through the same `consumption_columns` /
# `production_columns` declarations the meter balance uses, so a new asset shows up in the
# attribution without a change to this file and the shares cannot disagree with the accounting.
#
# Shares are fractions in [0, 1], never percentages — `self_consumption` and `self_sufficiency` are
# fractions, and one table with two conventions in it is a trap.

function attribution(result)
    flows = energy_flows(result)
    by_pair = Dict((row.source, row.sink) => row.kwh for row in eachrow(flows))
    per_sink =
        Dict(sink => sum(flows.kwh[flows.sink .== sink]) for sink in unique(flows.sink))
    at(source, sink) = get(by_pair, (source, sink), 0.0)
    # Where a sink's energy came from. NaN, not zero, when the sink took nothing at all: a car that
    # never charged has no mix, and calling that "0% solar" would drag an average down with a
    # household that charged badly.
    share(source, sink) =
        (total = get(per_sink, sink, 0.0); total > 0 ? at(source, sink) / total : NaN)
    into(sink) = get(per_sink, sink, 0.0)
    return (; at, share, into)
end

# The sinks that are actually *final demand*. Export leaves the house, and battery charge is storage
# rather than consumption — the energy comes back out again as battery discharge and would be counted
# twice. So the house consumes exactly these two things.
const FINAL_DEMAND = ("base load", "ev charge")

function metrics(config, result, bill, baseline_bill)
    dt = hours(result.grid)
    frame = result.frame
    a = attribution(result)

    total(column) = hasproperty(frame, column) ? sum(frame[!, column]) * dt : 0.0
    available = total(:pv_available_kw)
    # Measured against what the array *could* have made, not what it made: a home that curtails a
    # third of its panels is not using its solar well, and a ratio over production hides that.
    of_solar(sink) = available > 0 ? a.at("PV", sink) / available : NaN

    # Self-sufficiency counting the car. The package's `self_sufficiency` measures the *base load*
    # alone, so at a given array every scenario here reports the identical number — the car is not
    # "household consumption" to it. That is defensible as a house metric and useless as a household
    # one: a 20 kWh/day commute changes what this home buys from the grid enormously and would not
    # move that column at all. These three put the car back in, over final demand only.
    demand = sum(a.into(sink) for sink in FINAL_DEMAND)
    of_demand(source) =
        demand > 0 ? sum(a.at(source, sink) for sink in FINAL_DEMAND) / demand : NaN

    capacity = config.kwh
    economics = if capacity > 0
        investment = INVESTMENT(capacity)
        k = kpis(baseline_bill, bill, investment; result)
        (;
            capex = investment.capex,
            annual_savings = k.annual_savings,
            npv = k.npv,
            irr = k.irr,
            payback_years = k.payback_years,
            lifetime_years = k.lifetime_years,
            cycles_per_year = k.cycles_per_year,
        )
    else
        (;
            capex = 0.0,
            annual_savings = 0.0,
            npv = NaN,
            irr = NaN,
            payback_years = NaN,
            lifetime_years = NaN,
            cycles_per_year = NaN,
        )
    end

    return merge(
        (;
            name = config.name,
            scenario = config.scenario.name,
            pv_kwp = config.kwp,
            battery_kwh = capacity,
            battery_kw = capacity / config.scenario.battery_hours,
            household_kwh = config.scenario.household_kwh,
            orientation = String(config.scenario.orientation),
            tilt = config.scenario.tilt,
            degradation = config.scenario.degradation,
            ev_weekdays_only = config.scenario.ev_weekdays_only,
            has_ev = config.scenario.has_ev,
            heat_pump_kw = config.scenario.heat_pump_kw,
            ev_kwh_per_day = config.scenario.ev_kwh_per_day,
            ev_charge_kw = config.scenario.ev_charge_kw,
            connection_kw = config.scenario.connection_kw,
            battery_efficiency = config.scenario.battery_efficiency,
            ev_efficiency = config.scenario.ev_efficiency,
            battery_hours = config.scenario.battery_hours,
            battery_soc_min = config.scenario.battery_soc_min,
            v2g_kw = config.scenario.v2g_kw,
            ev_capacity_kwh = config.scenario.ev_capacity_kwh,
            ev_departure = config.scenario.ev_departure,
            ev_return = config.scenario.ev_return,
            tariff = String(config.scenario.tariff),
            net_metering = config.scenario.net_metering,
            transport = String(config.scenario.transport),

            # Energy, kWh over the year
            annual_bill = annualise(bill),
            imported_kwh = bill.imported_kwh,
            exported_kwh = bill.exported_kwh,
            solar_available_kwh = available,
            solar_curtailed_kwh = total(:curtail_kw),
            base_load_kwh = total(:load_kw),
            ev_charge_kwh = total(:ev_charge_kw),
            battery_charge_kwh = total(:battery_charge_kw),
            battery_discharge_kwh = total(:battery_discharge_kw),

            # Peaks, kW. The connection scenarios exist to make these bind; this is where to look.
            peak_import_kw = maximum(frame.import_kw; init = 0.0),
            peak_export_kw = maximum(frame.export_kw; init = 0.0),

            # What became of the solar, as fractions of what the array could have produced.
            # These five sum to 1.
            solar_curtailed_share = available > 0 ? total(:curtail_kw) / available : NaN,
            solar_to_load_share = of_solar("base load"),
            solar_to_export_share = of_solar("export"),
            solar_to_battery_share = of_solar("battery charge"),
            solar_to_ev_share = of_solar("ev charge"),

            # Where each sink's energy came from. Each triple sums to 1.
            ev_from_solar_share = a.share("PV", "ev charge"),
            ev_from_grid_share = a.share("grid", "ev charge"),
            ev_from_battery_share = a.share("battery discharge", "ev charge"),
            load_from_solar_share = a.share("PV", "base load"),
            load_from_grid_share = a.share("grid", "base load"),
            load_from_battery_share = a.share("battery discharge", "base load"),
            battery_from_solar_share = a.share("PV", "battery charge"),
            battery_from_grid_share = a.share("grid", "battery charge"),

            # Final demand — the base load plus the car, which is what the household actually
            # consumes. These three sum to 1 and are the household-level counterpart to
            # `self_sufficiency` below.
            demand_kwh = demand,
            demand_from_solar_share = of_demand("PV"),
            demand_from_grid_share = of_demand("grid"),
            demand_from_battery_share = of_demand("battery discharge"),
            self_consumption = self_consumption(result),
            # The package's definition: the base load alone, so this moves with the array and not
            # with the car. Read `demand_from_grid_share` for the household.
            self_sufficiency = self_sufficiency(result),
        ),
        economics,
    )
end
