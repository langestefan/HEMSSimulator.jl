"""
    WATER_KWH_PER_LITRE_K

Energy to raise one litre of water by one kelvin, kWh. `4.186 kJ/(kg·K)` in the units this package
works in.
"""
const WATER_KWH_PER_LITRE_K = 4.186 / 3600

"""
    dhw_draw(grid::TimeGrid; kwargs...) -> Vector{Float64}

A domestic hot water draw profile in kWh per interval, one element per interval of `grid`.

Hot water is drawn in short bursts around getting up and cooking, which is exactly when electricity
is dearest — so a tank is a small store facing a large daily price swing. The profile is two
Gaussian peaks plus a flat trickle, scaled so the day's volume is `litres_per_day` heated from
`cold_inlet_c` to `setpoint_c`.

# Keyword arguments

  - `litres_per_day`: 120 L is a common figure for a two-person Dutch household.
  - `morning_hour`, `evening_hour`, `spread_hours`: where the peaks sit and how wide they are, in
    local clock hours (UTC, like every timestamp here).
  - `morning_share`: fraction of the day's draw in the morning peak.
  - `setpoint_c`, `cold_inlet_c`: the temperature rise the draw has to be paid for.
"""
function dhw_draw(
    grid::TimeGrid;
    litres_per_day::Real = 120.0,
    morning_hour::Real = 7.0,
    evening_hour::Real = 19.0,
    spread_hours::Real = 1.0,
    morning_share::Real = 0.45,
    setpoint_c::Real = 60.0,
    cold_inlet_c::Real = 10.0,
)
    0 <= morning_share <= 1 ||
        throw(ArgumentError("morning_share must be in [0, 1], got $morning_share"))
    litres_per_day >= 0 || throw(ArgumentError("litres_per_day must be non-negative"))
    setpoint_c > cold_inlet_c ||
        throw(ArgumentError("setpoint_c must exceed cold_inlet_c"))

    times = timestamps(grid)
    shape = zeros(Float64, grid.n)
    for k = 1:grid.n
        hour = Dates.hour(times[k]) + Dates.minute(times[k]) / 60
        bump(centre) = exp(-((hour - centre)^2) / (2 * spread_hours^2))
        shape[k] =
            morning_share * bump(morning_hour) +
            (1 - morning_share) * bump(evening_hour) +
            0.02
    end

    # Normalise per day so a partial first or last day is not over- or under-served.
    energy_per_day = litres_per_day * WATER_KWH_PER_LITRE_K * (setpoint_c - cold_inlet_c)
    draw = zeros(Float64, grid.n)
    for day in unique(Date.(times))
        rows = findall(t -> Date(t) == day, times)
        total = sum(shape[rows])
        total > 0 || continue
        # A partial day at the edge of the horizon gets its pro-rata share, not a full day's.
        fraction = length(rows) / intervals_per_day(grid)
        draw[rows] .= shape[rows] .* (energy_per_day * fraction / total)
    end
    return draw
end

"""
    WaterTank(; draw_kwh, kwargs...)
    WaterTank(grid::TimeGrid; litres_per_day = 120.0, kwargs...)

A domestic hot water tank heated by a heat pump or an immersion element.

It is the smallest store in the house and the one with the least freedom — a few kWh, and it has to
be full twice a day at times set by human habit rather than by price. What makes it worth modelling
anyway is that its heat is expensive: reaching 60 °C rather than the 40 °C a radiator needs roughly
halves the COP, so every kWh shifted out of the evening peak is worth about twice what the same kWh
is worth to space heating.

The same type models a resistive immersion tank: pass
`cop_model = LinearCOP(reference = 1.0, slope = 0.0, cop_min = 1.0)`. Note the `cop_min` — the COP
models clamp to 1.5 by default, which is right for a heat pump and silently wrong for a resistive
element.

# Fields

  - `volume_litre::Float64`, `setpoint_c::Float64`, `cold_inlet_c::Float64`: the store. Usable
    capacity is `volume × (setpoint − inlet) × `[`WATER_KWH_PER_LITRE_K`](@ref).
  - `minimum_c::Float64`: temperature below which the household notices, °C. Enforced softly.
  - `max_power_kw::Float64`: electrical input limit.
  - `cop_model::AbstractCOPModel`: at the tank's supply temperature, not the space heating one.
  - `standing_loss_w_per_k::Float64`: tank losses to its surroundings, W/K. A modern 200 L tank is
    around 1.5 W/K, an old one several times that.
  - `ambient_c::Float64`: temperature of the space the tank stands in, °C.
  - `initial_fraction::Float64`: state of charge at the start, as a fraction of usable capacity.
  - `shortfall_penalty::Float64`: €/kWh charged for dipping below `minimum_c` — lukewarm water.
  - `unserved_penalty::Float64`: €/kWh charged for a draw the tank could not supply at all. An
    empty tank physically cannot deliver hot water, so without this the run would come back
    `INFEASIBLE` rather than telling you the household had a cold shower. Much larger than
    `shortfall_penalty`, because the two failures are not equally bad.
  - `draw_kwh::Vector{Float64}`: hot water drawn per interval of the **whole horizon**, kWh.
"""
Base.@kwdef struct WaterTank <: AbstractAsset
    volume_litre::Float64 = 200.0
    setpoint_c::Float64 = 60.0
    minimum_c::Float64 = 45.0
    cold_inlet_c::Float64 = 10.0
    max_power_kw::Float64 = 2.5
    cop_model::AbstractCOPModel = CarnotCOP(supply_temp = 60.0)
    standing_loss_w_per_k::Float64 = 1.5
    ambient_c::Float64 = 20.0
    initial_fraction::Float64 = 0.8
    shortfall_penalty::Float64 = 5.0
    unserved_penalty::Float64 = 50.0
    draw_kwh::Vector{Float64}

    function WaterTank(
        volume_litre,
        setpoint_c,
        minimum_c,
        cold_inlet_c,
        max_power_kw,
        cop_model,
        standing_loss_w_per_k,
        ambient_c,
        initial_fraction,
        shortfall_penalty,
        unserved_penalty,
        draw_kwh,
    )
        volume_litre > 0 || throw(ArgumentError("volume_litre must be positive"))
        max_power_kw > 0 || throw(ArgumentError("max_power_kw must be positive"))
        cold_inlet_c < minimum_c <= setpoint_c || throw(
            ArgumentError(
                "need cold_inlet_c < minimum_c <= setpoint_c, got $cold_inlet_c, " *
                "$minimum_c and $setpoint_c",
            ),
        )
        0 <= initial_fraction <= 1 ||
            throw(ArgumentError("initial_fraction must be in [0, 1]"))
        all(>=(0), draw_kwh) || throw(ArgumentError("draw_kwh has negative entries"))
        return new(
            volume_litre,
            setpoint_c,
            minimum_c,
            cold_inlet_c,
            max_power_kw,
            cop_model,
            standing_loss_w_per_k,
            ambient_c,
            initial_fraction,
            shortfall_penalty,
            unserved_penalty,
            collect(Float64, draw_kwh),
        )
    end
end

function WaterTank(grid::TimeGrid; litres_per_day::Real = 120.0, kwargs...)
    defaults = (; setpoint_c = 60.0, cold_inlet_c = 10.0)
    settings = merge(defaults, NamedTuple(kwargs))
    draw = dhw_draw(
        grid;
        litres_per_day,
        setpoint_c = settings.setpoint_c,
        cold_inlet_c = settings.cold_inlet_c,
    )
    return WaterTank(; draw_kwh = draw, kwargs...)
end

"""
    tank_capacity_kwh(tank::WaterTank) -> Float64

Usable energy in the tank between the cold inlet and the setpoint, kWh.
"""
tank_capacity_kwh(tank::WaterTank) =
    tank.volume_litre * WATER_KWH_PER_LITRE_K * (tank.setpoint_c - tank.cold_inlet_c)

"""
    tank_reserve_kwh(tank::WaterTank) -> Float64

Energy the tank must hold to stay at or above `minimum_c`, kWh.
"""
tank_reserve_kwh(tank::WaterTank) =
    tank.volume_litre * WATER_KWH_PER_LITRE_K * (tank.minimum_c - tank.cold_inlet_c)

initial_state(tank::WaterTank) = tank.initial_fraction * tank_capacity_kwh(tank)

function _tank_draw(tank::WaterTank, ctx::DispatchContext)
    last = ctx.offset + ctx.grid.n - 1
    last <= length(tank.draw_kwh) || throw(
        ArgumentError(
            "the tank's draw profile covers $(length(tank.draw_kwh)) intervals but the " *
            "simulation reached interval $last. Build it against the same TimeGrid as the run.",
        ),
    )
    return tank.draw_kwh[ctx.offset:last]
end

function add_variables!(model::Model, tank::WaterTank, ctx::DispatchContext)
    n = ctx.grid.n
    power = @variable(model, [1:n], lower_bound = 0, upper_bound = tank.max_power_kw)
    energy = @variable(
        model,
        [1:n],
        lower_bound = 0,
        upper_bound = tank_capacity_kwh(tank),
    )
    shortfall = @variable(model, [1:n], lower_bound = 0)
    draw = _tank_draw(tank, ctx)
    # Hot water the tank could not supply. An empty tank cannot deliver, so this has to be a
    # variable rather than a hard constraint or the whole window becomes infeasible.
    unserved = @variable(model, [k = 1:n], lower_bound = 0, upper_bound = draw[k])
    return (; power, energy, shortfall, unserved, draw)
end

function add_constraints!(model::Model, tank::WaterTank, ctx::DispatchContext, vars, state)
    n = ctx.grid.n
    dt = ctx.dt
    capacity = tank_capacity_kwh(tank)
    # Standing loss is proportional to the temperature above the surrounding air, and tank
    # temperature is affine in stored energy, so the whole thing stays linear. Evaluated on the
    # previous state, which at a 15-minute step is indistinguishable from the implicit form.
    loss_slope = tank.standing_loss_w_per_k / 1000 * (tank.setpoint_c - tank.cold_inlet_c) /
                 capacity
    loss_offset =
        tank.standing_loss_w_per_k / 1000 * (tank.cold_inlet_c - tank.ambient_c)
    gain(k) = dt * cop(tank.cop_model, ctx.inputs.t_amb[k]) * vars.power[k]
    decay(previous) = dt * (loss_slope * previous + loss_offset)

    served(k) = vars.draw[k] - vars.unserved[k]
    @constraint(model, vars.energy[1] == state + gain(1) - served(1) - decay(state))
    @constraint(
        model,
        [k = 2:n],
        vars.energy[k] ==
        vars.energy[k-1] + gain(k) - served(k) - decay(vars.energy[k-1])
    )
    reserve = tank_reserve_kwh(tank)
    @constraint(model, [k = 1:n], vars.energy[k] >= reserve - vars.shortfall[k])
    return nothing
end

power_terms(::WaterTank, vars) =
    (; consumption = vars.power, production = [AffExpr(0.0) for _ in vars.power])

function cost_terms(model::Model, tank::WaterTank, ctx::DispatchContext, vars)
    expr = AffExpr(0.0)
    for k = 1:ctx.grid.n
        add_to_expression!(expr, tank.shortfall_penalty, vars.shortfall[k])
        add_to_expression!(expr, tank.unserved_penalty, vars.unserved[k])
    end
    if ctx.options.terminal_value
        # Unlike a car, a tank has no deadline the window can see past its own end, and unlike a
        # house its state is not pinned by a band. Without valuing what is left it arrives at every
        # window boundary at the reserve, so the next window has to reheat at whatever the price is.
        lambda = median(ctx.inputs.price_buy) / cop(tank.cop_model, median(ctx.inputs.t_amb))
        add_to_expression!(expr, -lambda, vars.energy[ctx.grid.n])
    end
    return expr
end

carry_state(::WaterTank, vars, k::Integer) = value(vars.energy[k])

result_columns(::WaterTank, vars, k::Integer) = (;
    dhw_kw = value.(vars.power[1:k]),
    dhw_energy_kwh = value.(vars.energy[1:k]),
    dhw_shortfall_kwh = value.(vars.shortfall[1:k]),
    dhw_unserved_kwh = value.(vars.unserved[1:k]),
)

consumption_columns(::WaterTank) = [:dhw_kw]

"""
    dhw_energy_kwh(result::SimulationResult) -> Float64

Electrical energy the hot water tank consumed over the simulation, kWh.
"""
dhw_energy_kwh(result) = sum(result.frame.dhw_kw) * hours(result.grid)

"""
    dhw_shortfall_kwh(result::SimulationResult) -> Float64

Energy by which the tank fell below its minimum temperature, kWh summed over the run. Non-zero means
the element is undersized, the tank is too small, or the draw profile is heavier than it was sized
for.
"""
dhw_shortfall_kwh(result) = sum(result.frame.dhw_shortfall_kwh)

"""
    dhw_unserved_kwh(result::SimulationResult) -> Float64

Hot water the tank could not supply at all, kWh. Distinct from [`dhw_shortfall_kwh`](@ref): that is
water delivered below the minimum temperature, this is water not delivered. Any non-zero value here
is a cold shower, not a lukewarm one.
"""
dhw_unserved_kwh(result) = sum(result.frame.dhw_unserved_kwh)
