"""
    ev_schedule(grid::TimeGrid; kwargs...) -> (; connected, trip_kwh, target_soc)

Expand a commuting pattern into the three per-interval series an [`ElectricVehicle`](@ref) needs:
whether the car is plugged in, how much energy each interval of driving consumes, and the state of
charge required before each departure.

The car leaves at `departure_hour` and returns at `return_hour` on driving days, and the day's
energy is spread evenly across the intervals it is away — the SoC then falls through the day rather
than dropping in one step, which is both more realistic and easier to read in a result frame.

The target applies to the **last connected interval before each departure**, so it is a deadline the
optimizer can plan towards rather than a floor it must hold all night. That is the whole point of
modelling an EV: the charging is flexible, the departure is not.

# Keyword arguments

  - `departure_hour`, `return_hour`: clock hours, UTC like every timestamp here. Overnight trips are
    not supported — `departure_hour` must be before `return_hour`.
  - `kwh_per_day`: energy per driving day. A number, or a function of the `Date` for a variable
    pattern. Defaults to 8 kWh if neither this nor `km_per_day` is given.
  - `km_per_day`, `kwh_per_km`: the same thing expressed as distance × efficiency. Give one or the
    other, not both.
  - `weekdays_only`: whether the car also drives at weekends.
  - `target_soc`: fraction of capacity required at departure.
"""
function ev_schedule(
    grid::TimeGrid;
    departure_hour::Real = 7.5,
    return_hour::Real = 17.5,
    kwh_per_day = nothing,
    km_per_day = nothing,
    kwh_per_km::Real = 0.18,
    weekdays_only::Bool = true,
    target_soc::Real = 0.8,
)
    0 <= departure_hour < return_hour <= 24 || throw(
        ArgumentError(
            "need 0 <= departure_hour < return_hour <= 24, got $departure_hour and " *
            "$return_hour. Trips spanning midnight are not supported; build the " *
            "`connected` and `trip_kwh` series yourself for those.",
        ),
    )
    0 <= target_soc <= 1 ||
        throw(ArgumentError("target_soc must be in [0, 1], got $target_soc"))
    kwh_per_day === nothing ||
        km_per_day === nothing ||
        throw(ArgumentError("give `kwh_per_day` or `km_per_day`, not both"))

    per_day = if km_per_day !== nothing
        km = km_per_day isa Real ? Returns(float(km_per_day)) : km_per_day
        day -> km(day) * kwh_per_km
    elseif kwh_per_day isa Real
        Returns(float(kwh_per_day))
    elseif kwh_per_day === nothing
        Returns(8.0)
    else
        kwh_per_day
    end

    times = timestamps(grid)
    connected = trues(grid.n)
    trip_kwh = zeros(Float64, grid.n)
    target = zeros(Float64, grid.n)

    away = Dict{Date,Vector{Int}}()
    for k = 1:grid.n
        t = times[k]
        (weekdays_only && isweekend(t)) && continue
        hour = Dates.hour(t) + Dates.minute(t) / 60
        departure_hour <= hour < return_hour || continue
        connected[k] = false
        push!(get!(Vector{Int}, away, Date(t)), k)
    end

    for (day, intervals) in away
        energy = float(per_day(day)) / length(intervals)
        energy >= 0 || throw(ArgumentError("trip energy on $day is negative"))
        trip_kwh[intervals] .= energy
        # The requirement lands on the interval before the car leaves. When the horizon starts with
        # the car already gone there is no such interval and nothing to require.
        first_away = minimum(intervals)
        first_away > 1 && (target[first_away-1] = float(target_soc))
    end

    return (; connected, trip_kwh, target_soc = target)
end

"""
    ElectricVehicle(; capacity_kwh, charge_power_kw, connected, trip_kwh, target_kwh, kwargs...)
    ElectricVehicle(grid::TimeGrid; capacity_kwh, charge_power_kw, kwargs...)

A car that charges at home. The second form builds the schedule from a commuting pattern with
[`ev_schedule`](@ref); the first takes the three series directly, for a measured or irregular one.

An EV is not a second battery. It is away when the sun is up on exactly the days its owner commutes,
it must be full enough to leave in the morning, and — unless V2G is switched on — energy that goes
into it never comes back out to the house. Those three facts are what make it reshape the evening
load a home battery is being bought to cover, which is why sizing a battery without one is
optimistic.

# Fields

  - `capacity_kwh::Float64`: usable battery capacity, kWh.
  - `charge_power_kw::Float64`: AC charge-point rating, kW.
  - `discharge_power_kw::Float64`: V2G discharge rating. Zero by default, which disables V2G.
  - `charge_efficiency::Float64`, `discharge_efficiency::Float64`: one-way efficiencies.
  - `soc_min::Float64`, `soc_max::Float64`: state-of-charge limits as a fraction of capacity. The
    floor binds only while the car is plugged in — it is a charging policy, not a physical limit,
    and enforcing it on the road would make an otherwise reasonable trip infeasible.
  - `soc_initial::Float64`: state of charge at the start of the simulation, as a fraction.
  - `degradation_cost::Float64`: €/kWh of throughput charged to the objective. Only meaningful with
    V2G, where the optimizer would otherwise cycle someone else's car for free.
  - `connected::BitVector`, `trip_kwh::Vector{Float64}`, `target_kwh::Vector{Float64}`: the schedule,
    one element per interval of the **whole horizon**, not of a window.

# Examples

```jldoctest
julia> using Dates

julia> grid = TimeGrid(DateTime(2024, 4, 1), 96 * 7);

julia> ev = ElectricVehicle(grid; capacity_kwh = 60.0, charge_power_kw = 11.0, km_per_day = 45);

julia> round(sum(ev.trip_kwh), digits = 1)      # five commuting days
40.5
```
"""
Base.@kwdef struct ElectricVehicle <: AbstractAsset
    capacity_kwh::Float64
    charge_power_kw::Float64
    discharge_power_kw::Float64 = 0.0
    charge_efficiency::Float64 = 0.92
    discharge_efficiency::Float64 = 0.92
    soc_min::Float64 = 0.1
    soc_max::Float64 = 1.0
    soc_initial::Float64 = 0.6
    degradation_cost::Float64 = 0.0
    connected::BitVector
    trip_kwh::Vector{Float64}
    target_kwh::Vector{Float64}

    function ElectricVehicle(
        capacity_kwh,
        charge_power_kw,
        discharge_power_kw,
        charge_efficiency,
        discharge_efficiency,
        soc_min,
        soc_max,
        soc_initial,
        degradation_cost,
        connected,
        trip_kwh,
        target_kwh,
    )
        n = length(connected)
        length(trip_kwh) == n && length(target_kwh) == n || throw(
            ArgumentError(
                "connected, trip_kwh and target_kwh must be the same length, got " *
                "$n, $(length(trip_kwh)) and $(length(target_kwh))",
            ),
        )
        any(connected) ||
            throw(ArgumentError("the car is never connected, so it can never charge"))
        all(>=(0), trip_kwh) || throw(ArgumentError("trip_kwh has negative entries"))
        all(iszero, trip_kwh[connected]) || throw(
            ArgumentError(
                "trip_kwh is non-zero in an interval where the car is connected; a car " *
                "cannot be driving and plugged in at once",
            ),
        )
        ceiling = soc_max * capacity_kwh
        maximum(target_kwh; init = 0.0) <= ceiling || throw(
            ArgumentError(
                "a departure target of $(maximum(target_kwh)) kWh exceeds the usable " *
                "capacity of $ceiling kWh",
            ),
        )
        return new(
            capacity_kwh,
            charge_power_kw,
            discharge_power_kw,
            charge_efficiency,
            discharge_efficiency,
            soc_min,
            soc_max,
            soc_initial,
            degradation_cost,
            connected,
            trip_kwh,
            target_kwh,
        )
    end
end

function ElectricVehicle(
    grid::TimeGrid;
    capacity_kwh::Real,
    charge_power_kw::Real,
    departure_hour::Real = 7.5,
    return_hour::Real = 17.5,
    kwh_per_day = nothing,
    km_per_day = nothing,
    kwh_per_km::Real = 0.18,
    weekdays_only::Bool = true,
    target_soc::Real = 0.8,
    kwargs...,
)
    schedule = ev_schedule(
        grid;
        departure_hour,
        return_hour,
        kwh_per_day,
        km_per_day,
        kwh_per_km,
        weekdays_only,
        target_soc,
    )
    return ElectricVehicle(;
        capacity_kwh = float(capacity_kwh),
        charge_power_kw = float(charge_power_kw),
        connected = schedule.connected,
        trip_kwh = schedule.trip_kwh,
        target_kwh = schedule.target_soc .* float(capacity_kwh),
        kwargs...,
    )
end

supports_v2g(ev::ElectricVehicle) = ev.discharge_power_kw > 0
supports_binary(ev::ElectricVehicle) = supports_v2g(ev)

initial_state(ev::ElectricVehicle) = ev.soc_initial * ev.capacity_kwh

# The schedule is indexed over the whole horizon; a window sees the slice starting at ctx.offset.
function _ev_window(ev::ElectricVehicle, ctx::DispatchContext)
    last = ctx.offset + ctx.grid.n - 1
    last <= length(ev.connected) || throw(
        ArgumentError(
            "the EV schedule covers $(length(ev.connected)) intervals but the simulation " *
            "reached interval $last. Build the vehicle against the same TimeGrid as the run.",
        ),
    )
    range = ctx.offset:last
    return (
        connected = ev.connected[range],
        trip_kwh = ev.trip_kwh[range],
        target_kwh = ev.target_kwh[range],
    )
end

function add_variables!(model::Model, ev::ElectricVehicle, ctx::DispatchContext)
    n = ctx.grid.n
    schedule = _ev_window(ev, ctx)
    charge = @variable(
        model,
        [k = 1:n],
        lower_bound = 0,
        upper_bound = schedule.connected[k] ? ev.charge_power_kw : 0.0,
    )
    discharge = @variable(
        model,
        [k = 1:n],
        lower_bound = 0,
        upper_bound = schedule.connected[k] ? ev.discharge_power_kw : 0.0,
    )
    # The floor is applied as a constraint on connected intervals only, so the variable itself is
    # free to fall towards empty while the car is out driving.
    energy = @variable(
        model,
        [1:n],
        lower_bound = 0,
        upper_bound = ev.soc_max * ev.capacity_kwh,
    )
    vars = (; charge, discharge, energy, schedule)
    if ctx.options.exclusive && supports_v2g(ev)
        mode = @variable(model, [1:n], binary = true)
        @constraint(model, [k = 1:n], charge[k] <= ev.charge_power_kw * mode[k])
        @constraint(model, [k = 1:n], discharge[k] <= ev.discharge_power_kw * (1 - mode[k]))
        vars = (; charge, discharge, energy, schedule, mode)
    end
    return vars
end

function add_constraints!(
    model::Model,
    ev::ElectricVehicle,
    ctx::DispatchContext,
    vars,
    state,
)
    n = ctx.grid.n
    dt = ctx.dt
    schedule = vars.schedule
    gain(k) =
        dt * (
            ev.charge_efficiency * vars.charge[k] -
            vars.discharge[k] / ev.discharge_efficiency
        ) - schedule.trip_kwh[k]
    @constraint(model, vars.energy[1] == state + gain(1))
    @constraint(model, [k = 2:n], vars.energy[k] == vars.energy[k-1] + gain(k))

    floor_kwh = ev.soc_min * ev.capacity_kwh
    for k = 1:n
        schedule.connected[k] &&
            floor_kwh > 0 &&
            @constraint(model, vars.energy[k] >= floor_kwh)
        schedule.target_kwh[k] > 0 &&
            @constraint(model, vars.energy[k] >= schedule.target_kwh[k])
    end
    return nothing
end

power_terms(::ElectricVehicle, vars) =
    (; consumption = vars.charge, production = vars.discharge)

function cost_terms(model::Model, ev::ElectricVehicle, ctx::DispatchContext, vars)
    n = ctx.grid.n
    expr = AffExpr(0.0)
    if ev.degradation_cost > 0
        for k = 1:n
            add_to_expression!(
                expr,
                ctx.dt * ev.degradation_cost,
                vars.charge[k] + vars.discharge[k],
            )
        end
    end
    # Terminal value applies only with V2G, and the reason is worth stating because the symmetry
    # with `Battery` is tempting. A home battery needs it: nothing else stops the receding horizon
    # emptying it at every boundary. A car does not — its departure targets already anchor the
    # trajectory, and the 48 h window always sees the next one. Crediting stored charge as well
    # makes it profitable to fill 60 kWh of car whenever the price dips below the window median,
    # which on a synthetic week inflated charging by 26 kWh of energy the household never used.
    # With V2G the charge really can come back out, so it is worth what a battery's is.
    if ctx.options.terminal_value && supports_v2g(ev)
        lambda = median(ctx.inputs.price_buy) * ev.discharge_efficiency
        add_to_expression!(expr, -lambda, vars.energy[n])
    end
    return expr
end

carry_state(::ElectricVehicle, vars, k::Integer) = value(vars.energy[k])

result_columns(::ElectricVehicle, vars, k::Integer) = (;
    ev_charge_kw = value.(vars.charge[1:k]),
    ev_discharge_kw = value.(vars.discharge[1:k]),
    ev_soc_kwh = value.(vars.energy[1:k]),
    ev_connected = vars.schedule.connected[1:k],
)

consumption_columns(::ElectricVehicle) = [:ev_charge_kw]
production_columns(::ElectricVehicle) = [:ev_discharge_kw]

"""
    ev_energy_kwh(result::SimulationResult) -> Float64

Total energy delivered to the car over the simulation, kWh at the meter. Compare it against the
driving energy the schedule demanded: the gap is charging losses.
"""
ev_energy_kwh(result) = sum(result.frame.ev_charge_kw) * hours(result.grid)
