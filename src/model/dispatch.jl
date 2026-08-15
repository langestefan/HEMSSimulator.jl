"""
    build_window(system::HomeSystem, ctx::DispatchContext, states) -> (model, vars)

Build the JuMP model for one rolling-horizon window.

The model is a linear program by default. Its structure is a single meter balance per interval —

```
import − export + pv − curtailment + Σ asset production == load + Σ asset consumption
```

— with each asset contributing its own variables, constraints and objective terms through the
[`AbstractAsset`](@ref) contract. `states` is a vector parallel to `system.assets` holding the state
each asset carries in from the previous window.

The objective is set by `options.strategy`: a weighted sum of imported energy and of money, the
latter covering the dispatch price signal plus whatever the assets add (throughput cost, terminal
storage value). See [`AbstractStrategy`](@ref).
"""
function build_window(system::HomeSystem, ctx::DispatchContext, states)
    n = ctx.grid.n
    dt = ctx.dt
    inputs = ctx.inputs
    model = Model(ctx.options.optimizer)
    ctx.options.silent && set_silent(model)

    limit = system.connection_kw
    imported =
        @variable(model, [1:n], lower_bound = 0, upper_bound = limit, base_name = "import")
    exported =
        @variable(model, [1:n], lower_bound = 0, upper_bound = limit, base_name = "export")
    curtail = @variable(model, [1:n], lower_bound = 0, base_name = "curtail")
    @constraint(model, curtailment_limit[k=1:n], curtail[k] <= inputs.pv_kw[k])

    asset_vars = [add_variables!(model, asset, ctx) for asset in system.assets]
    for (asset, vars, state) in zip(system.assets, asset_vars, states)
        add_constraints!(model, asset, ctx, vars, state)
    end

    consumption = [AffExpr(inputs.load_kw[k]) for k = 1:n]
    production_expr = [AffExpr(inputs.pv_kw[k]) for k = 1:n]
    for (asset, vars) in zip(system.assets, asset_vars)
        terms = power_terms(asset, vars)
        for k = 1:n
            add_to_expression!(consumption[k], terms.consumption[k])
            add_to_expression!(production_expr[k], terms.production[k])
        end
    end

    @constraint(
        model,
        balance[k=1:n],
        imported[k] - exported[k] + production_expr[k] - curtail[k] == consumption[k]
    )

    # The strategy is two weights, not a branch: one on imported energy, one on money. See
    # `AbstractStrategy`. Economic is (0, 1) and reproduces the objective exactly as it was.
    weights = objective_weights(ctx.options.strategy, ctx)
    objective = AffExpr(0.0)
    for k = 1:n
        add_to_expression!(objective, weights.import_kwh * dt, imported[k])
        add_to_expression!(objective, weights.cost * dt * inputs.price_buy[k], imported[k])
        add_to_expression!(
            objective,
            -weights.cost * dt * inputs.price_sell[k],
            exported[k],
        )
    end
    for (asset, vars) in zip(system.assets, asset_vars)
        add_to_expression!(objective, weights.cost, cost_terms(model, asset, ctx, vars))
    end
    @objective(model, Min, objective)

    vars = (; imported, exported, curtail, assets = asset_vars)
    return model, vars
end

"""
    solve_window(system::HomeSystem, ctx::DispatchContext, states) -> (vars, model)

Build and solve one window, throwing if the solver does not reach a feasible optimum.

!!! note "LP degeneracy"

    The linear program stops the battery charging and discharging at once, and stops the meter
    importing and exporting at once, only because doing both wastes energy and wasting energy costs
    money. Two situations break that assumption:

    Under full net metering the buy and sell price are equal, so a simultaneous import and export is
    free; `RunOptions.price_epsilon` forces a small spread to keep the optimum unique.

    Under negative prices — routine on the Dutch day-ahead market — burning energy is *profitable*,
    and the LP will happily cycle the battery or import-and-export to dump kWh. No price nudge fixes
    that; it needs the binary formulation, `RunOptions.exclusive = true`.

    `RunOptions.check_degeneracy` verifies the returned solution and warns with the offending
    intervals, so a scenario that needs binaries announces itself rather than silently reporting
    impossible flows.
"""
function solve_window(system::HomeSystem, ctx::DispatchContext, states)
    model, vars = build_window(system, ctx, states)
    optimize!(model)
    is_solved_and_feasible(model) || error(
        "dispatch window starting at interval $(ctx.offset) did not solve: " *
        "$(termination_status(model))",
    )
    ctx.options.check_degeneracy && check_degeneracy(system, vars, ctx)
    return vars, model
end

"""
    check_degeneracy(system, vars, ctx)

Warn if the solved window simultaneously imports and exports, or simultaneously charges and
discharges an asset. See the note on [`solve_window`](@ref).
"""
function check_degeneracy(system::HomeSystem, vars, ctx::DispatchContext)
    tol = 1.0e-6
    both = findall(
        k -> value(vars.imported[k]) > tol && value(vars.exported[k]) > tol,
        1:ctx.grid.n,
    )
    isempty(both) ||
        @warn "solution imports and exports in the same interval; enable RunOptions.exclusive" window_offset =
            ctx.offset intervals = first(both, 5) count = length(both)
    for (asset, avars) in zip(system.assets, vars.assets)
        haskey(avars, :charge) && haskey(avars, :discharge) || continue
        clash = findall(
            k -> value(avars.charge[k]) > tol && value(avars.discharge[k]) > tol,
            1:ctx.grid.n,
        )
        isempty(clash) ||
            @warn "asset charges and discharges in the same interval; enable RunOptions.exclusive" asset =
                typeof(asset) window_offset = ctx.offset intervals = first(clash, 5) count =
                length(clash)
    end
    return nothing
end
