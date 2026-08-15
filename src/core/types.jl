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
    AbstractStrategy

What the controller is trying to achieve. The dispatch model is the same either way — same
variables, same constraints, same assets — and only the objective changes, which is the point: the
two strategies are comparable because nothing else differs.

  - [`EconomicStrategy`](@ref) minimises what the household pays.
  - [`GreenStrategy`](@ref) minimises what it takes from the grid.
"""
abstract type AbstractStrategy end

"""
    EconomicStrategy()

Minimise cost at the dispatch price: `Σ Δ·(buy·import − sell·export)`, plus whatever the assets
add. The default, and what every result in this package assumed before strategies existed.
"""
struct EconomicStrategy <: AbstractStrategy end

"""
    GreenStrategy(; cost_weight = 1.0e-3)

Minimise energy taken from the grid, `Σ Δ·import`, with the cost objective kept on at
`cost_weight` as a tie-break.

**Self-consumption falls out rather than being imposed.** Charging the battery from the grid *is* an
import, and a round trip loses energy, so it can never avoid as much later import as it costs now.
An import-minimising optimizer therefore never grid-charges — it only ever stores surplus PV. There
is no rule forbidding it because none is needed.

The tie-break matters. Minimising imports leaves many equally good schedules, and with nothing to
separate them the solver returns an arbitrary one; the cost term picks the cheapest of them. It is a
scalarisation, not a lexicographic solve: `cost_weight` must stay small enough that no amount of
money outweighs a kWh of import. At the default, a kWh of import costs the objective 1 while the
dearest kWh ever seen costs it about 0.0005.

One consequence worth expecting: at that weight `Battery.degradation_cost` is also scaled into
insignificance, so a green household may cycle its battery harder than an economic one for no
return. That is arguably right for a strategy that does not care about money, but it shows up in
`cycles_per_year`.
"""
Base.@kwdef struct GreenStrategy <: AbstractStrategy
    cost_weight::Float64 = 1.0e-3
end

"""
    objective_weights(strategy, ctx) -> (; import_kwh, cost)

How much the window objective weights imported energy and money. `dispatch.jl` assembles

    Σ Δ·(import_kwh·import[k])  +  cost·(the price and asset terms)

so a strategy is two numbers, and adding one means adding a method here rather than a branch in the
model builder.
"""
objective_weights(::EconomicStrategy, _) = (; import_kwh = 0.0, cost = 1.0)
objective_weights(strategy::GreenStrategy, _) =
    (; import_kwh = 1.0, cost = strategy.cost_weight)

"""
    RunOptions(; kwargs...)

How a simulation is run: the rolling-horizon geometry, the solver, and the modelling switches.

# Fields

  - `window_hours::Float64`: length of each optimization window. The default 48 h with a 24 h step
    means every day is optimized with a day of lookahead and only the first day is implemented.
  - `step_hours::Float64`: how far the horizon advances per solve, i.e. how much of each window is
    kept. Fractional values are the realistic controller: `step_hours = 0.25` re-optimizes every
    interval, which is what a real MPC does — and costs one solve per interval of the horizon
    rather than one per day, so a year goes from 366 solves to 35 040.
  - `optimizer`: a solver factory, passed straight to `JuMP.Model`. Never hardcoded.
  - `exclusive::Bool`: add binaries forbidding simultaneous charge and discharge. Off by default;
    see the note on LP degeneracy in [`solve_window`](@ref).
  - `terminal_value::Bool`: value energy left in storage at the end of a window, so the optimizer
    does not empty it at every window boundary.
  - `price_epsilon::Float64`: €/kWh spread forced between buy and sell price inside the dispatch
    objective. Keeps the LP non-degenerate under net metering, where the two are otherwise equal.
  - `check_degeneracy::Bool`: warn if a solution simultaneously imports and exports, or
    simultaneously charges and discharges.
  - `strategy::AbstractStrategy`: what the controller optimizes for. See [`AbstractStrategy`](@ref).
  - `silent::Bool`: suppress solver output.
  - `tie_break::Float64`: a tiny preference for acting **earlier**, €/kWh *per interval of delay*. The dispatch LP routinely has several optima — four quarter-hours inside a step-held
    hourly price cost exactly the same, so charging in any of them is equally optimal — and which one
    a solver returns is arbitrary. That is invisible to the controller and *not* invisible to the
    bill, because [`settle`](@ref) reads the flows rather than the objective: on a 2025 year, HiGHS
    with and without presolve and Clp all hit the same optimum to 5e-15 and produced annual bills
    €0.51 apart. This term makes the optimum unique so results are reproducible across solvers.

    Its size is squeezed from both ends, and *per interval* is what makes the bound checkable. It
    must clear the solver's dual-feasibility tolerance (1e-7 for HiGHS) or the term is ignored and
    the tie goes back to being arbitrary; it must stay under the smallest real price difference
    between neighbouring intervals (1.21e-5 €/kWh in the 2025 Dutch data) or it would override
    genuine economics. The default of 1e-6 is 10x the former and 12x below the latter. Set it to
    `0.0` to restore the old, solver-dependent behaviour.

    Note how much of the horizon this touches: step-holding an hourly price onto quarter-hours makes
    19 753 of 2025's 35 040 adjacent intervals *exactly* equal, so more than half the year is a tie.
  - `direct::Bool`: build each window with JuMP's [`direct_model`](https://jump.dev/JuMP.jl/stable/manual/models/#Direct-mode)
    instead of the default caching layer. Worth about 27% of a window: the cache has to be *copied*
    into the solver at `optimize!`, and on this model that copy costs nearly as much as the solve.
    The trade is that a direct model has no bridges, so an optimizer that cannot take a constraint
    natively errors instead of having it reformulated. HiGHS takes everything this package builds,
    which is why it defaults to `true`; set it to `false` for a solver that needs bridging.
"""
struct RunOptions{O,S<:AbstractStrategy}
    window_hours::Float64
    step_hours::Float64
    optimizer::O
    exclusive::Bool
    terminal_value::Bool
    price_epsilon::Float64
    check_degeneracy::Bool
    strategy::S
    silent::Bool
    direct::Bool
    tie_break::Float64
end

# Written out rather than `@kwdef` so that the hours accept any `Real`: `step_hours = 0.25` and
# `window_hours = 24` are both natural to type, and `@kwdef` on a parametric struct passes keywords
# through untouched, so an `Int` would miss the constructor.
RunOptions(;
    window_hours::Real = 48.0,
    step_hours::Real = 24.0,
    optimizer = HiGHS.Optimizer,
    exclusive::Bool = false,
    terminal_value::Bool = true,
    price_epsilon::Real = 1.0e-4,
    check_degeneracy::Bool = true,
    strategy::AbstractStrategy = EconomicStrategy(),
    silent::Bool = true,
    direct::Bool = true,
    tie_break::Real = 1.0e-6,
) = RunOptions(
    float(window_hours),
    float(step_hours),
    optimizer,
    exclusive,
    terminal_value,
    float(price_epsilon),
    check_degeneracy,
    strategy,
    silent,
    direct,
    float(tie_break),
)

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
