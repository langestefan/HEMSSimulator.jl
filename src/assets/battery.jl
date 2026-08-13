"""
    Battery(; capacity_kwh, charge_power_kw, discharge_power_kw, kwargs...)
    Battery(capacity_kwh, power_kw; kwargs...)

A home battery. The second form gives a symmetric charge and discharge rating, which is how battery
products are normally specified.

# Fields

  - `capacity_kwh::Float64`: nameplate usable-plus-reserve energy capacity, kWh.
  - `charge_power_kw::Float64`, `discharge_power_kw::Float64`: AC power limits, kW.
  - `charge_efficiency::Float64`, `discharge_efficiency::Float64`: one-way efficiencies. Their
    product is the round-trip efficiency.
  - `soc_min::Float64`, `soc_max::Float64`: state-of-charge limits as a fraction of capacity.
  - `soc_initial::Float64`: state of charge at the start of the simulation, as a fraction.
  - `self_discharge::Float64`: fraction of capacity lost per hour.
  - `degradation_cost::Float64`: €/kWh of throughput charged to the objective. Zero by default;
    set it to make the optimizer trade cycling against arbitrage margin.

# Examples

```jldoctest
julia> battery = Battery(10.0, 5.0);

julia> battery.capacity_kwh, battery.discharge_power_kw
(10.0, 5.0)
```
"""
Base.@kwdef struct Battery <: AbstractAsset
    capacity_kwh::Float64
    charge_power_kw::Float64
    discharge_power_kw::Float64
    charge_efficiency::Float64 = 0.95
    discharge_efficiency::Float64 = 0.95
    soc_min::Float64 = 0.05
    soc_max::Float64 = 1.0
    soc_initial::Float64 = 0.5
    self_discharge::Float64 = 0.0
    degradation_cost::Float64 = 0.0
end

function Battery(capacity_kwh::Real, power_kw::Real; kwargs...)
    return Battery(;
        capacity_kwh = float(capacity_kwh),
        charge_power_kw = float(power_kw),
        discharge_power_kw = float(power_kw),
        kwargs...,
    )
end

supports_binary(::Battery) = true

initial_state(battery::Battery) = battery.soc_initial * battery.capacity_kwh

function add_variables!(model::Model, battery::Battery, ctx::DispatchContext)
    n = ctx.grid.n
    charge = @variable(model, [1:n], lower_bound = 0, upper_bound = battery.charge_power_kw)
    discharge =
        @variable(model, [1:n], lower_bound = 0, upper_bound = battery.discharge_power_kw)
    energy = @variable(
        model,
        [1:n],
        lower_bound = battery.soc_min * battery.capacity_kwh,
        upper_bound = battery.soc_max * battery.capacity_kwh,
    )
    vars = (; charge, discharge, energy)
    if ctx.options.exclusive
        mode = @variable(model, [1:n], binary = true)
        @constraint(model, [k = 1:n], charge[k] <= battery.charge_power_kw * mode[k])
        @constraint(
            model,
            [k = 1:n],
            discharge[k] <= battery.discharge_power_kw * (1 - mode[k])
        )
        vars = (; charge, discharge, energy, mode)
    end
    return vars
end

function add_constraints!(model::Model, battery::Battery, ctx::DispatchContext, vars, state)
    n = ctx.grid.n
    dt = ctx.dt
    loss = dt * battery.self_discharge * battery.capacity_kwh
    gain(k) =
        dt * (
            battery.charge_efficiency * vars.charge[k] -
            vars.discharge[k] / battery.discharge_efficiency
        )
    @constraint(model, vars.energy[1] == state + gain(1) - loss)
    @constraint(model, [k = 2:n], vars.energy[k] == vars.energy[k-1] + gain(k) - loss)
    return nothing
end

power_terms(::Battery, vars) = (; consumption = vars.charge, production = vars.discharge)

function cost_terms(model::Model, battery::Battery, ctx::DispatchContext, vars)
    n = ctx.grid.n
    expr = AffExpr(0.0)
    if battery.degradation_cost > 0
        for k = 1:n
            add_to_expression!(
                expr,
                ctx.dt * battery.degradation_cost,
                vars.charge[k] + vars.discharge[k],
            )
        end
    end
    if ctx.options.terminal_value
        # Energy left in the battery at the end of a window is worth what it displaces later. Without
        # this the receding horizon empties the battery at every window boundary. Valuing it at the
        # window's median buy price is deliberately conservative: it never pays to store energy the
        # optimizer could not plausibly recover.
        lambda = median(ctx.inputs.price_buy) * battery.discharge_efficiency
        add_to_expression!(expr, -lambda, vars.energy[n])
    end
    return expr
end

carry_state(::Battery, vars, k::Integer) = value(vars.energy[k])

result_columns(::Battery, vars, k::Integer) = (;
    battery_charge_kw = value.(vars.charge[1:k]),
    battery_discharge_kw = value.(vars.discharge[1:k]),
    battery_soc_kwh = value.(vars.energy[1:k]),
)

"""
    throughput(result::SimulationResult) -> Float64

Total battery discharge energy over the simulation, kWh. Divided by capacity this is the equivalent
full cycle count, the number that drives warranty and degradation assumptions.
"""
throughput(result) = sum(result.frame.battery_discharge_kw) * hours(result.grid)
