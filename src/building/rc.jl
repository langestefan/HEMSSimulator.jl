"""
    RCSpec(; envelope = true, emitter = true)

Which nodes the thermal network has, following the grey-box vocabulary of Bacher & Madsen (2011).

  - `envelope`: a separate envelope mass `Te` between indoor air and ambient. Without it the house
    has no slow thermal inertia, and pre-heating against tomorrow's prices buys nothing.
  - `emitter`: a radiator or floor mass `Th` that the heat pump warms and which warms the air in
    turn. Without it heat appears in the air instantly, which overstates how quickly a setback can
    be recovered.

The default `Ti + Te + Th` is three states — enough to represent both lags, small enough to stay
cheap at 192 intervals per window.
"""
Base.@kwdef struct RCSpec
    envelope::Bool = true
    emitter::Bool = true
end

"""
    BuildingSpec(; C_i, C_e, C_h, R_ia, R_ie, R_ea, R_ih, kwargs...)
    BuildingSpec(floor_area_m2; heat_loss_kw, kwargs...)

A lumped-capacity thermal model of a dwelling. Capacities are in kWh/K and resistances in K/kW, so
that a heat flow in kW and a temperature in °C combine without any unit bookkeeping.

The second form derives the parameters from headline figures a homeowner actually knows — floor area
and heat loss at the design outdoor temperature. Those are **rules of thumb**, not a fitted model.
Parameter identification from measured data is explicitly out of scope for this package; if you have
a fitted model, pass its parameters to the first form.

# Fields

  - `rc::RCSpec`: which nodes exist.
  - `C_i`, `C_e`, `C_h`: heat capacity of the indoor air, the envelope and the emitter, kWh/K.
  - `R_ia`: indoor air to ambient directly — ventilation and infiltration, K/kW.
  - `R_ie`, `R_ea`: indoor air to envelope, and envelope to ambient, K/kW.
  - `R_ih`: indoor air to emitter, K/kW. This is what sets how hot the radiators must run.
  - `A_w`: effective solar aperture, m². Multiplied by global horizontal irradiance to give a heat
    gain, so it absorbs window area, orientation, glazing transmittance and shading in one number.
  - `q_int::Float64`: average internal gains from people and appliances, kW.
"""
Base.@kwdef struct BuildingSpec
    rc::RCSpec = RCSpec()
    C_i::Float64
    C_e::Float64
    C_h::Float64
    R_ia::Float64
    R_ie::Float64
    R_ea::Float64
    R_ih::Float64
    A_w::Float64 = 4.0
    q_int::Float64 = 0.4
end

"""
    BuildingSpec(floor_area_m2; heat_loss_kw = 6.0, design_delta_k = 30.0, kwargs...)

Derive a [`BuildingSpec`](@ref) from headline figures.

`heat_loss_kw` is the steady heat demand at a temperature difference of `design_delta_k` — for the
Netherlands, indoors at 20 °C against a design outdoor temperature of −10 °C. That fixes the overall
conductance; the split into the individual resistances and capacities uses fixed proportions typical
of Dutch housing, documented in the source.

```jldoctest
julia> spec = BuildingSpec(120.0; heat_loss_kw = 6.0);

julia> round(1 / (1 / spec.R_ia + 1 / (spec.R_ie + spec.R_ea)), digits = 3)   # K/kW overall
5.0
```
"""
function BuildingSpec(
    floor_area_m2::Real;
    heat_loss_kw::Real = 6.0,
    design_delta_k::Real = 30.0,
    emitter_delta_k::Real = 15.0,
    rc::RCSpec = RCSpec(),
    kwargs...,
)
    heat_loss_kw > 0 || throw(ArgumentError("heat_loss_kw must be positive"))
    floor_area_m2 > 0 || throw(ArgumentError("floor_area_m2 must be positive"))
    # Overall thermal resistance from the design point: ΔT = q · R.
    r_total = design_delta_k / heat_loss_kw
    # Roughly a fifth of the loss is ventilation and infiltration, which bypasses the envelope mass
    # and so responds instantly; the rest goes through it. With the envelope node switched off there
    # is no other path, so the whole loss has to go down the direct one or the house would come out
    # five times better insulated than asked for.
    r_ia = rc.envelope ? 5 * r_total : r_total
    r_through = r_total * 5 / 4
    return BuildingSpec(;
        rc,
        # Capacities per square metre of floor: light interior mass, heavy envelope, and an emitter
        # somewhere between. A concrete floor pushes C_h up, a low-temperature radiator down.
        C_i = 0.012 * floor_area_m2,
        C_e = 0.09 * floor_area_m2,
        C_h = 0.015 * floor_area_m2,
        R_ia = r_ia,
        # Most of the resistance sits outside the envelope mass — that is what makes it slow.
        R_ie = 0.25 * r_through,
        R_ea = 0.75 * r_through,
        # The emitter runs `emitter_delta_k` above room temperature at design load.
        R_ih = emitter_delta_k / heat_loss_kw,
        kwargs...,
    )
end

"""
    nstates(spec::BuildingSpec) -> Int

Number of temperature states: indoor air, plus the envelope and emitter nodes that are enabled.
State order is always `Ti`, then `Te`, then `Th`.
"""
nstates(spec::BuildingSpec) = 1 + spec.rc.envelope + spec.rc.emitter

"""
    continuous(spec::BuildingSpec) -> (Ac, Bc)

Continuous-time state-space matrices of the thermal network, `dx/dt = Ac·x + Bc·u`.

The input vector is `u = [t_amb, q_heat, ghi, q_int]`: ambient temperature in °C, useful heat
delivered by the heat pump in kW, global horizontal irradiance in W/m², and internal gains in kW.
Solar and internal gains enter the air node; `q_heat` enters the emitter when there is one and the
air node otherwise.

Only `q_heat` is ever a decision variable, so the discretised form enters JuMP as plain linear
equalities — see [`discretize`](@ref).
"""
function continuous(spec::BuildingSpec)
    n = nstates(spec)
    Ac = zeros(n, n)
    Bc = zeros(n, 4)
    ie = spec.rc.envelope ? 2 : 0
    ih = spec.rc.emitter ? n : 0

    # Indoor air: ventilation and infiltration straight to ambient.
    Ac[1, 1] -= 1 / (spec.C_i * spec.R_ia)
    Bc[1, 1] += 1 / (spec.C_i * spec.R_ia)

    if spec.rc.envelope
        Ac[1, 1] -= 1 / (spec.C_i * spec.R_ie)
        Ac[1, ie] += 1 / (spec.C_i * spec.R_ie)
        Ac[ie, 1] += 1 / (spec.C_e * spec.R_ie)
        Ac[ie, ie] -= 1 / (spec.C_e * spec.R_ie) + 1 / (spec.C_e * spec.R_ea)
        Bc[ie, 1] += 1 / (spec.C_e * spec.R_ea)
    end

    if spec.rc.emitter
        Ac[1, 1] -= 1 / (spec.C_i * spec.R_ih)
        Ac[1, ih] += 1 / (spec.C_i * spec.R_ih)
        Ac[ih, 1] += 1 / (spec.C_h * spec.R_ih)
        Ac[ih, ih] -= 1 / (spec.C_h * spec.R_ih)
        Bc[ih, 2] += 1 / spec.C_h
    else
        Bc[1, 2] += 1 / spec.C_i
    end

    # W/m² to kW through the effective aperture, and internal gains, both into the air.
    Bc[1, 3] = spec.A_w / (1000 * spec.C_i)
    Bc[1, 4] = 1 / spec.C_i
    return Ac, Bc
end

"""
    discretize(Ac, Bc, dt) -> (Ad, Bd)

Exact zero-order-hold discretisation over `dt` hours, by the standard matrix-exponential
augmentation `exp([Ac Bc; 0 0]·dt)`.

Exact rather than forward Euler because a 15-minute step is not small against the emitter time
constant of a lightweight radiator, and Euler both damps the response and can go unstable on the
fast node. This is computed once per simulation; the result enters JuMP as constants.
"""
function discretize(Ac::AbstractMatrix, Bc::AbstractMatrix, dt::Real)
    n, m = size(Bc)
    size(Ac) == (n, n) ||
        throw(DimensionMismatch("Ac is $(size(Ac)) but Bc has $n rows"))
    block = [Ac Bc; zeros(m, n + m)]
    expanded = exp(block * dt)
    return expanded[1:n, 1:n], expanded[1:n, (n+1):(n+m)]
end

"""
    discretize(spec::BuildingSpec, dt) -> (Ad, Bd)

[`continuous`](@ref) followed by [`discretize`](@ref).
"""
discretize(spec::BuildingSpec, dt::Real) = discretize(continuous(spec)..., dt)

"""
    heat_loss_coefficient(spec::BuildingSpec) -> Float64

Steady-state conductance from indoor air to ambient, kW/K — the reciprocal of the ventilation path
in parallel with the path through the envelope. At steady state the heat pump must supply
`heat_loss_coefficient(spec) × (T_indoor − T_ambient)`, which is the number to check a spec against.
"""
heat_loss_coefficient(spec::BuildingSpec) =
    1 / spec.R_ia + (spec.rc.envelope ? 1 / (spec.R_ie + spec.R_ea) : 0.0)
