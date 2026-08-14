"""
    AbstractCOPModel

How the coefficient of performance is obtained from the outdoor temperature. Two are provided:
[`CarnotCOP`](@ref) and [`LinearCOP`](@ref).

The COP depends only on ambient temperature here, which is known data — that is what keeps
`q_heat = COP × p_electric` linear and the whole dispatch model an LP. Making it depend on the
supply temperature as well, as a real weather-compensated heat pump does, would make the product of
two decision variables and cost the linearity.
"""
abstract type AbstractCOPModel end

"""
    CarnotCOP(; efficiency = 0.45, supply_temp = 40.0, cop_min = 1.5, cop_max = 6.0)

A fraction of the Carnot limit between the outdoor temperature and a fixed supply temperature:

```
COP = efficiency × (T_supply + 273.15) / max(T_supply − T_amb, 1)
```

`efficiency` around 0.4–0.5 reproduces a modern air-source unit: about 4.3 at 7 °C and 3.1 at −5 °C
for a 40 °C supply. The shape matters more than the level — it is why a heat pump is expensive
exactly when heat is most needed, and therefore why pre-heating during mild hours pays.
"""
Base.@kwdef struct CarnotCOP <: AbstractCOPModel
    efficiency::Float64 = 0.45
    supply_temp::Float64 = 40.0
    cop_min::Float64 = 1.5
    cop_max::Float64 = 6.0
end

"""
    LinearCOP(; reference = 4.0, reference_temp = 7.0, slope = 0.10, cop_min = 1.5, cop_max = 6.0)

`COP = reference + slope × (T_amb − reference_temp)`, clamped. The simplest thing that captures the
right direction, and the easiest to fit to a manufacturer's two published operating points.
"""
Base.@kwdef struct LinearCOP <: AbstractCOPModel
    reference::Float64 = 4.0
    reference_temp::Float64 = 7.0
    slope::Float64 = 0.10
    cop_min::Float64 = 1.5
    cop_max::Float64 = 6.0
end

"""
    cop(model::AbstractCOPModel, t_amb) -> Float64

Coefficient of performance at an outdoor temperature of `t_amb` °C.
"""
function cop end

cop(model::CarnotCOP, t_amb::Real) = clamp(
    model.efficiency * (model.supply_temp + 273.15) /
    max(model.supply_temp - t_amb, 1.0),
    model.cop_min,
    model.cop_max,
)

cop(model::LinearCOP, t_amb::Real) = clamp(
    model.reference + model.slope * (t_amb - model.reference_temp),
    model.cop_min,
    model.cop_max,
)

"""
    HeatPump(; building, setpoint, kwargs...)
    HeatPump(grid::TimeGrid; building, setpoint = 20.0, kwargs...)

An air-source heat pump heating a building modelled as an RC network.

This is the asset that makes the receding horizon earn its keep. A battery stores kWh; a house
stores °C, and it does so for free in mass that is already there. Because the COP falls as it gets
colder and the price is highest in the evening, warming the fabric during a mild cheap afternoon and
coasting through the peak is often worth more than the same kWh in a battery — and the only way to
see that is to optimise the temperature trajectory rather than the power.

# Fields

  - `building::BuildingSpec`: the thermal network.
  - `max_power_kw::Float64`: electrical input limit, kW.
  - `cop_model::AbstractCOPModel`: see [`CarnotCOP`](@ref).
  - `setpoint::Vector{Float64}`: target indoor temperature per interval of the **whole horizon**,
    °C. A night or holiday setback is a change to this series.
  - `band::Float64`: half-width of the comfort band in K. The optimizer may let the temperature
    float anywhere within `setpoint ± band`, and that freedom is the entire flexibility.
  - `comfort_penalty::Float64`: €/K per hour charged for falling *below* the band. Soft on purpose:
    an undersized heat pump in a cold snap physically cannot hold the band, and a model that reports
    how many degree-hours it fell short is more useful than one that reports infeasible.
  - `overheat_penalty::Float64`: €/K per hour charged for rising *above* it. Deliberately an order
    of magnitude smaller, because the two are not the same thing. Being cold is discomfort; being
    warmer than a night setback is what a house does while it coasts down, and nobody minds. This
    penalty exists to stop the optimizer treating the building as an unbounded heat store, not to
    model an occupant — and at parity with `comfort_penalty` it would make pre-heating through the
    morning step-up cost as much as simply being cold, which is the wrong trade.
  - `control::Symbol`: `:optimized` for the flexibility above, or `:thermostat` to run the
    rule-based controller in [`thermostat_profile`](@ref) and simulate what it does. The comparison
    of the two is the value of smart control.
  - `initial_temperature::Float64`: every node starts here, °C.

# Examples

```jldoctest
julia> using Dates

julia> grid = TimeGrid(DateTime(2024, 1, 1), 96);

julia> hp = HeatPump(grid; building = BuildingSpec(120.0), setpoint = 20.0);

julia> round(BatteryBusinessCase.cop(hp.cop_model, 7.0), digits = 2)
4.27
```
"""
Base.@kwdef struct HeatPump <: AbstractAsset
    building::BuildingSpec
    max_power_kw::Float64 = 4.0
    cop_model::AbstractCOPModel = CarnotCOP()
    setpoint::Vector{Float64}
    band::Float64 = 1.0
    comfort_penalty::Float64 = 100.0
    overheat_penalty::Float64 = 10.0
    control::Symbol = :optimized
    initial_temperature::Float64 = 20.0

    function HeatPump(
        building,
        max_power_kw,
        cop_model,
        setpoint,
        band,
        comfort_penalty,
        overheat_penalty,
        control,
        initial_temperature,
    )
        control in (:optimized, :thermostat) ||
            throw(ArgumentError("control must be :optimized or :thermostat, got :$control"))
        band >= 0 || throw(ArgumentError("band must be non-negative, got $band"))
        max_power_kw > 0 || throw(ArgumentError("max_power_kw must be positive"))
        isempty(setpoint) && throw(ArgumentError("setpoint is empty"))
        return new(
            building,
            max_power_kw,
            cop_model,
            collect(Float64, setpoint),
            band,
            comfort_penalty,
            overheat_penalty,
            control,
            initial_temperature,
        )
    end
end

function HeatPump(grid::TimeGrid; setpoint = 20.0, kwargs...)
    series = setpoint isa Real ? fill(float(setpoint), grid.n) : collect(Float64, setpoint)
    checkseries(grid, series, "setpoint")
    return HeatPump(; setpoint = series, kwargs...)
end

initial_state(hp::HeatPump) =
    fill(hp.initial_temperature, nstates(hp.building))

# The setpoint spans the horizon; a window sees the slice starting at ctx.offset.
function _hp_setpoint(hp::HeatPump, ctx::DispatchContext)
    last = ctx.offset + ctx.grid.n - 1
    last <= length(hp.setpoint) || throw(
        ArgumentError(
            "the heat pump setpoint covers $(length(hp.setpoint)) intervals but the " *
            "simulation reached interval $last. Build it against the same TimeGrid as the run.",
        ),
    )
    return hp.setpoint[ctx.offset:last]
end

"""
    thermostat_profile(hp::HeatPump, state, t_amb, ghi, dt) -> Vector{Float64}

Electrical power a simple hysteresis thermostat would draw, kW per interval.

The controller switches full on below `setpoint − band/2` and full off above `setpoint + band/2`,
looking only at the indoor temperature it can currently see. It is the counterfactual the
`:optimized` mode is measured against: same building, same heat pump, no foresight and no price
signal.
"""
function thermostat_profile(
    hp::HeatPump,
    state::AbstractVector,
    setpoint::AbstractVector,
    t_amb::AbstractVector,
    ghi::AbstractVector,
    dt::Real,
)
    Ad, Bd = discretize(hp.building, dt)
    x = collect(Float64, state)
    power = zeros(Float64, length(setpoint))
    on = false
    for k in eachindex(setpoint)
        # The decision at k sees the state left by k-1, matching the dispatch model's convention.
        if x[1] < setpoint[k] - hp.band / 2
            on = true
        elseif x[1] > setpoint[k] + hp.band / 2
            on = false
        end
        power[k] = on ? hp.max_power_kw : 0.0
        heat = power[k] * cop(hp.cop_model, t_amb[k])
        x = Ad * x + Bd * [t_amb[k], heat, ghi[k], hp.building.q_int]
    end
    return power
end

function add_variables!(model::Model, hp::HeatPump, ctx::DispatchContext)
    n = ctx.grid.n
    nx = nstates(hp.building)
    setpoint = _hp_setpoint(hp, ctx)
    power = @variable(model, [1:n], lower_bound = 0, upper_bound = hp.max_power_kw)
    temperature = @variable(model, [1:nx, 1:n])
    # Slack on both sides of the comfort band, priced in the objective. Without it a cold snap that
    # simply exceeds the heat pump's capacity comes back as "infeasible" rather than as a number of
    # degree-hours short.
    too_cold = @variable(model, [1:n], lower_bound = 0)
    too_warm = @variable(model, [1:n], lower_bound = 0)
    return (; power, temperature, too_cold, too_warm, setpoint)
end

function add_constraints!(model::Model, hp::HeatPump, ctx::DispatchContext, vars, state)
    n = ctx.grid.n
    nx = nstates(hp.building)
    Ad, Bd = discretize(hp.building, ctx.dt)
    t_amb = ctx.inputs.t_amb
    ghi = ctx.inputs.ghi
    q_int = hp.building.q_int
    x = vars.temperature

    # Heat delivered is COP times electrical power. The COP is data, so this stays affine.
    heat(k) = cop(hp.cop_model, t_amb[k]) * vars.power[k]
    exogenous(i, k) = Bd[i, 1] * t_amb[k] + Bd[i, 3] * ghi[k] + Bd[i, 4] * q_int

    @constraint(
        model,
        [i = 1:nx],
        x[i, 1] ==
        sum(Ad[i, j] * state[j] for j = 1:nx) + Bd[i, 2] * heat(1) + exogenous(i, 1)
    )
    @constraint(
        model,
        [i = 1:nx, k = 2:n],
        x[i, k] ==
        sum(Ad[i, j] * x[j, k-1] for j = 1:nx) + Bd[i, 2] * heat(k) + exogenous(i, k)
    )

    @constraint(
        model,
        [k = 1:n],
        x[1, k] >= vars.setpoint[k] - hp.band - vars.too_cold[k]
    )
    @constraint(
        model,
        [k = 1:n],
        x[1, k] <= vars.setpoint[k] + hp.band + vars.too_warm[k]
    )

    if hp.control === :thermostat
        profile = thermostat_profile(hp, state, vars.setpoint, t_amb, ghi, ctx.dt)
        @constraint(model, [k = 1:n], vars.power[k] == profile[k])
    end
    return nothing
end

power_terms(::HeatPump, vars) =
    (; consumption = vars.power, production = [AffExpr(0.0) for _ in vars.power])

function cost_terms(model::Model, hp::HeatPump, ctx::DispatchContext, vars)
    expr = AffExpr(0.0)
    for k = 1:ctx.grid.n
        add_to_expression!(expr, ctx.dt * hp.comfort_penalty, vars.too_cold[k])
        add_to_expression!(expr, ctx.dt * hp.overheat_penalty, vars.too_warm[k])
    end
    # No terminal value. The comfort band already pins the temperature at the end of every window,
    # so unlike a battery there is nothing for the optimizer to drain, and unlike a car the state
    # is bounded on both sides.
    return expr
end

carry_state(hp::HeatPump, vars, k::Integer) =
    [value(vars.temperature[i, k]) for i = 1:nstates(hp.building)]

function result_columns(hp::HeatPump, vars, k::Integer)
    columns = (;
        heatpump_kw = value.(vars.power[1:k]),
        indoor_temp = [value(vars.temperature[1, j]) for j = 1:k],
        too_cold_k = [value(vars.too_cold[j]) for j = 1:k],
        too_warm_k = [value(vars.too_warm[j]) for j = 1:k],
    )
    hp.building.rc.emitter || return columns
    row = nstates(hp.building)
    return merge(
        columns,
        (; emitter_temp = [value(vars.temperature[row, j]) for j = 1:k]),
    )
end

consumption_columns(::HeatPump) = [:heatpump_kw]

"""
    heat_demand_kwh(result::SimulationResult) -> Float64

Electrical energy the heat pump consumed over the simulation, kWh.
"""
heat_demand_kwh(result) = sum(result.frame.heatpump_kw) * hours(result.grid)

"""
    discomfort_kh(result::SimulationResult; side = :both) -> Float64

Degree-hours spent outside the comfort band. `side` selects `:cold`, `:warm`, or `:both`.

The two sides do not mean the same thing, which is why they can be asked for separately. Cold
degree-hours are a fault: the heat pump is undersized, or the band is too narrow to hold. Warm
degree-hours are usually not — a night setback necessarily produces them, because a house at 20 °C
cannot fall to a 17 °C band the instant the setpoint drops, and no occupant is uncomfortable while
it coasts down. They still carry their penalty in the objective, which is what stops the optimizer
pre-heating into a setback it can see coming.
"""
function discomfort_kh(result; side::Symbol = :both)
    dt = hours(result.grid)
    side === :cold && return sum(result.frame.too_cold_k) * dt
    side === :warm && return sum(result.frame.too_warm_k) * dt
    side === :both ||
        throw(ArgumentError("side must be :cold, :warm or :both, got :$side"))
    return (sum(result.frame.too_cold_k) + sum(result.frame.too_warm_k)) * dt
end
