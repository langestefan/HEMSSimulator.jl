# Physical constants and numerical guards shared across the package.

"Solar constant, W/m². The value the Erbs and Perez correlations were fitted against."
const SOLAR_CONSTANT = 1367.0

"""
Smallest cosine of the solar zenith angle treated as daylight. Below it (about 89°) the projection
factors used by the transposition models are numerically unstable and the irradiance is negligible.
"""
const COS_ZENITH_MIN = 0.01745

"""
    AbstractAsset

Supertype for controllable assets that contribute decision variables to the dispatch model.

Purely exogenous quantities — PV production, the household base load — are not assets: they enter
the model as data through [`SimulationInputs`](@ref). An asset is something the optimizer *decides
about*.

Implementations must provide the following contract. `ctx` is a [`DispatchContext`](@ref) describing
the current rolling-horizon window.

  - `initial_state(asset)` — the state this asset carries into the first window.
  - `add_variables!(model, asset, ctx)` — return a `NamedTuple` of variable references.
  - `add_constraints!(model, asset, ctx, vars, state)` — attach the asset's own constraints,
    starting from `state`.
  - `power_terms(asset, vars)` — return `(; consumption, production)`, each a vector of one
    expression per interval in kW, which the dispatch model sums into the meter balance.
  - `cost_terms(model, asset, ctx, vars)` — return an objective contribution in euros, or `0.0`.
  - `carry_state(asset, vars, k)` — the state after `k` implemented intervals, for the next window.
  - `result_columns(asset, vars, k)` — a `NamedTuple` of length-`k` vectors recorded into the
    result frame.
  - `consumption_columns(asset)` / `production_columns(asset)` — which of those column names are
    power drawn from and delivered to the meter. Default to empty. Implement them or the asset's
    flows will be missing from [`balance_residual`](@ref), [`self_consumption`](@ref) and
    [`self_sufficiency`](@ref), which reconstruct the balance from the frame rather than from the
    model.

Optional capability predicates default to `false`: [`supports_binary`](@ref), [`supports_v2g`](@ref).
"""
abstract type AbstractAsset end

"""
    initial_state(asset::AbstractAsset)

State the asset starts the simulation in. See [`AbstractAsset`](@ref).
"""
function initial_state end

"""
    add_variables!(model, asset::AbstractAsset, ctx) -> NamedTuple

Attach the asset's decision variables to `model`. See [`AbstractAsset`](@ref).
"""
function add_variables! end

"""
    add_constraints!(model, asset::AbstractAsset, ctx, vars, state)

Attach the asset's constraints to `model`, starting from `state`. See [`AbstractAsset`](@ref).
"""
function add_constraints! end

"""
    power_terms(asset::AbstractAsset, vars) -> (; consumption, production)

Per-interval power expressions in kW that enter the meter balance. See [`AbstractAsset`](@ref).
"""
function power_terms end

"""
    cost_terms(model, asset::AbstractAsset, ctx, vars)

Objective contribution in euros. See [`AbstractAsset`](@ref).
"""
function cost_terms end

"""
    carry_state(asset::AbstractAsset, vars, k)

State after `k` implemented intervals, carried into the next window. See [`AbstractAsset`](@ref).
"""
function carry_state end

"""
    result_columns(asset::AbstractAsset, vars, k) -> NamedTuple

Solved values for the first `k` intervals, recorded into the result frame. See
[`AbstractAsset`](@ref).
"""
function result_columns end

"""
    consumption_columns(asset::AbstractAsset) -> Vector{Symbol}

Which of the asset's [`result_columns`](@ref) are power drawn from the meter, in kW.

The reporting layer reconstructs the meter balance from the result frame, not from the solved model,
so an asset that does not declare these is invisible to it — its charging would simply not appear in
[`balance_residual`](@ref). Declaring them here rather than hard-coding column names in
`results.jl` is what keeps adding an asset a single-file change.
"""
consumption_columns(::AbstractAsset) = Symbol[]

"""
    production_columns(asset::AbstractAsset) -> Vector{Symbol}

Which of the asset's [`result_columns`](@ref) are power delivered to the meter, in kW. See
[`consumption_columns`](@ref).
"""
production_columns(::AbstractAsset) = Symbol[]

"""
    supports_binary(asset::AbstractAsset) -> Bool

Whether the asset has a binary formulation available for `RunOptions.exclusive`.
"""
supports_binary(::AbstractAsset) = false

"""
    supports_v2g(asset::AbstractAsset) -> Bool

Whether the asset can export to the home (vehicle-to-grid / vehicle-to-home).
"""
supports_v2g(::AbstractAsset) = false

"""
    RunOptions(; kwargs...)

How a simulation is run: the rolling-horizon geometry, the solver, and the modelling switches.

# Fields

  - `window_hours::Int`: length of each optimization window. The default 48 h with a 24 h step means
    every day is optimized with a day of lookahead and only the first day is implemented.
  - `step_hours::Int`: how far the horizon advances per solve, i.e. how much of each window is kept.
  - `optimizer`: a solver factory, passed straight to `JuMP.Model`. Never hardcoded.
  - `exclusive::Bool`: add binaries forbidding simultaneous charge and discharge. Off by default;
    see the note on LP degeneracy in [`solve_window`](@ref).
  - `terminal_value::Bool`: value energy left in storage at the end of a window, so the optimizer
    does not empty it at every window boundary.
  - `price_epsilon::Float64`: €/kWh spread forced between buy and sell price inside the dispatch
    objective. Keeps the LP non-degenerate under net metering, where the two are otherwise equal.
  - `check_degeneracy::Bool`: warn if a solution simultaneously imports and exports, or
    simultaneously charges and discharges.
  - `silent::Bool`: suppress solver output.
"""
Base.@kwdef struct RunOptions{O}
    window_hours::Int = 48
    step_hours::Int = 24
    optimizer::O = HiGHS.Optimizer
    exclusive::Bool = false
    terminal_value::Bool = true
    price_epsilon::Float64 = 1.0e-4
    check_degeneracy::Bool = true
    silent::Bool = true
end

"""
    DispatchContext

Everything an asset needs to know about the window currently being optimized.

# Fields

  - `grid::TimeGrid`: the window's time grid.
  - `dt::Float64`: interval length in hours, the kW → kWh factor.
  - `inputs::SimulationInputs`: exogenous series sliced to this window.
  - `options::RunOptions`: the run switches.
  - `offset::Int`: index of this window's first interval within the full horizon, so results can be
    written back in the right place.
"""
struct DispatchContext{I,O}
    grid::TimeGrid
    dt::Float64
    inputs::I
    options::O
    offset::Int
end
