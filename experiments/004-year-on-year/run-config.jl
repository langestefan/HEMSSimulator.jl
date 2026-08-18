# Experiment 004: do the 2025 findings survive 2026?
#
# Every number in experiments 002 and 003 rests on a single year of weather and prices. That is the
# largest untested assumption in the whole set, and it cannot be argued away — only measured against
# another year.
#
# **The window is the same calendar span in both years**, 1 January to 15 August. Comparing a full
# 2025 against a part 2026 would confound the year with the season, and the season is the stronger
# effect: a window ending in August is solar-heavy and misses the winter tail entirely. So neither
# year's numbers here are annual figures, and they are not comparable with 002's. They are
# comparable with *each other*, which is the whole point.

using HEMSSimulator
using Dates
using Printf: @sprintf

include(joinpath(@__DIR__, "..", "tibber.jl"))

const SITE = Site(52.1, 5.18)
const YEARS = [2025, 2026]
# ERA5 reanalysis lags real time by a day or two, so the window ends comfortably inside what
# Open-Meteo will serve rather than at today's date.
window_for(year) = TimeGrid(DateTime(year, 1, 1), DateTime(year, 8, 15))

const HOUSEHOLD_KWH = 3500.0
const EV_KWH_PER_WORKDAY = 10.0
const PV_KWP = [0.0, 3.0, 6.0, 9.0, 12.0]
const BATTERY_KWH = [0.0, 2.5, 5.0, 7.5, 10.0, 12.5, 15.0, 20.0, 25.0, 30.0]
const INVERTER_RATIO = 0.9
const DEGRADATION = 0.02
const FIXED_CAPEX = 400.0
const RESULTS_PER_KWH = 400.0
const DISCOUNT_RATE = 0.0
const LIFETIME_YEARS = 15
const RATED_CYCLES = 6000.0
const INVESTMENT =
    capacity -> Investment(
        capex = FIXED_CAPEX + RESULTS_PER_KWH * capacity,
        lifetime_years = LIFETIME_YEARS,
        rated_cycles = RATED_CYCLES,
        discount_rate = DISCOUNT_RATE,
    )

# The scenarios carried over from 002. Not all 44 — the point is whether the *findings* hold, so
# this is the set each headline finding rests on, priced in both years.
const BASE_CASE = (;
    orientation = :south,
    tilt = 35,
    household_kwh = HOUSEHOLD_KWH,
    ev_kwh_per_day = EV_KWH_PER_WORKDAY,
    has_ev = true,
    battery_efficiency = 0.95,
    ev_efficiency = 0.92,
    battery_hours = 2.0,
    degradation = DEGRADATION,
    tariff = :dynamic,
    net_metering = 0.0,
    transport = :fixed,
)
scenario(name; kwargs...) = merge((; name = name), BASE_CASE, NamedTuple(kwargs))

const SCENARIOS = [
    scenario("base"),
    scenario("east-west"; orientation = :east_west),
    scenario("lossy"; battery_efficiency = 0.90, ev_efficiency = 0.85),
    scenario("efficient"; battery_efficiency = 0.975, ev_efficiency = 0.95),
    scenario("high-mileage"; ev_kwh_per_day = 20.0),
    scenario("no-ev"; has_ev = false),
    scenario("large-household"; household_kwh = 5000.0),
    scenario("net-metering"; net_metering = 1.0),
    scenario("tou-transport"; transport = :time_of_use),
    scenario("flat-tariff"; tariff = :flat),
    scenario("costly-wear"; degradation = 0.05),
    scenario("cheap-wear"; degradation = 0.005),
]

const OPTIONS = RunOptions(
    window_hours = 24,
    step_hours = 0.25,
    terminal_value = false,
    strategy = EconomicStrategy(),
)

const PEAK_TRANSPORT = 0.06
const OFFPEAK_TRANSPORT = 0.01

function contract_for(s, grid::TimeGrid, prices::AbstractVector)
    spot =
        s.tariff === :flat ? fill(sum(prices) / length(prices), length(prices)) :
        collect(Float64, prices)
    transport = if s.transport === :fixed
        FixedCapacityTariff()
    else
        # Peak read on the Dutch clock, as in 002.
        peak = [16 <= h < 21 for h in dutch_hours(grid)]
        weekday = [!isweekend(t) for t in timestamps(grid)]
        TimeVaryingGridTariff(;
            import_eur_per_kwh = [
                (p && w) ? PEAK_TRANSPORT : OFFPEAK_TRANSPORT for
                (p, w) in zip(peak, weekday)
            ],
            annual_eur = NL_TARIFFS_2025.capacity_tariff / 2,
        )
    end
    return Contract(
        grid;
        commodity = spot .+ MARKUP,
        feed_in = feed_in_price(spot),
        energy_tax = ENERGY_TAX,
        net_metering_fraction = s.net_metering,
        grid = transport,
    )
end
contract_key(s) = (s.tariff, s.net_metering, s.transport)

arrays(kwp, orientation, tilt) =
    kwp <= 0 ? PVArray[] :
    orientation === :south ?
    [PVArray(
        dc_capacity_kwp = kwp,
        ac_capacity_kw = kwp * INVERTER_RATIO,
        tilt = tilt,
        azimuth = 180,
    )] :
    [
        PVArray(
            dc_capacity_kwp = kwp / 2,
            ac_capacity_kw = kwp / 2 * INVERTER_RATIO,
            tilt = tilt,
            azimuth = az,
        ) for az in (90, 270)
    ]

function home(s, kwp::Real, grid::TimeGrid)
    assets = AbstractAsset[]
    s.has_ev && push!(
        assets,
        ElectricVehicle(
            grid;
            capacity_kwh = 60.0,
            charge_power_kw = 12.0,
            kwh_per_day = s.ev_kwh_per_day,
            weekdays_only = true,
            charge_efficiency = s.ev_efficiency,
            discharge_efficiency = s.ev_efficiency,
        ),
    )
    return HomeSystem(
        site = SITE,
        pv = arrays(kwp, s.orientation, s.tilt),
        assets = assets,
        connection_kw = 17.25,
    )
end

battery(s, kwh::Real) = Battery(
    kwh,
    kwh / s.battery_hours;
    charge_efficiency = s.battery_efficiency,
    discharge_efficiency = s.battery_efficiency,
    degradation_cost = s.degradation,
)

config_name(year, s, kwp, kwh) = string(
    year,
    "|",
    s.name,
    "|pv=",
    @sprintf("%04.1f", kwp),
    "|bat=",
    @sprintf("%04.1f", kwh),
)
