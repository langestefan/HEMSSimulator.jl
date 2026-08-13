"""
    HomeSystem(; site, pv = PVArray[], assets = AbstractAsset[], connection_kw = 17.3)

The physical home: where it is, what generates, and what the optimizer controls.

# Fields

  - `site::Site`: location and ground albedo.
  - `pv::Vector{PVArray}`: zero or more PV arrays, each with its own orientation and inverter.
  - `assets::Vector{AbstractAsset}`: controllable assets. An empty vector is the no-battery
    baseline every business case is measured against.
  - `connection_kw::Float64`: physical grid connection limit, kW in each direction. The default
    corresponds to a 3×25 A connection.

# Examples

```jldoctest
julia> system = HomeSystem(
           site = Site(52.1, 5.2),
           pv = [PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180)],
           assets = [Battery(10.0, 5.0)],
       );

julia> length(system.assets)
1
```
"""
Base.@kwdef struct HomeSystem
    site::Site
    pv::Vector{PVArray} = PVArray[]
    assets::Vector{AbstractAsset} = AbstractAsset[]
    connection_kw::Float64 = 17.3
end

"""
    with_assets(system::HomeSystem, assets) -> HomeSystem

Copy of `system` with a different set of controllable assets. Used by [`sweep`](@ref) to vary the
battery without rebuilding the rest of the home.
"""
with_assets(system::HomeSystem, assets::AbstractVector) = HomeSystem(;
    site = system.site,
    pv = system.pv,
    assets = collect(AbstractAsset, assets),
    connection_kw = system.connection_kw,
)

"""
    SimulationInputs

Every exogenous series the dispatch model needs, precomputed once for the whole horizon and sliced
per rolling-horizon window.

Keeping this separate from [`HomeSystem`](@ref) is what makes a sizing sweep cheap: PV production,
prices and the base load are computed once and reused for every candidate battery.

# Fields

  - `grid::TimeGrid`: the horizon.
  - `pv_kw::Vector{Float64}`: total AC PV production available, kW.
  - `load_kw::Vector{Float64}`: household base load, kW.
  - `price_buy::Vector{Float64}`, `price_sell::Vector{Float64}`: the dispatch price signal, €/kWh.
  - `t_amb::Vector{Float64}`: ambient temperature, °C. Carried for the heat pump model.
"""
struct SimulationInputs
    grid::TimeGrid
    pv_kw::Vector{Float64}
    load_kw::Vector{Float64}
    price_buy::Vector{Float64}
    price_sell::Vector{Float64}
    t_amb::Vector{Float64}
end

"""
    prepare(system, weather, load_kw, contract; options = RunOptions()) -> SimulationInputs

Compute the exogenous series for a simulation: PV production from the weather and the arrays, and
the dispatch price signal from the contract.
"""
function prepare(
    system::HomeSystem,
    weather::Weather,
    load_kw::AbstractVector,
    contract::Contract;
    options::RunOptions = RunOptions(),
)
    grid = weather.grid
    checkseries(grid, load_kw, "load_kw")
    checkseries(grid, contract.commodity, "contract.commodity")
    checkseries(grid, contract.feed_in, "contract.feed_in")
    buy, sell = dispatch_prices(contract, options)
    return SimulationInputs(
        grid,
        production(system.pv, system.site, weather),
        collect(Float64, load_kw),
        buy,
        sell,
        copy(weather.t_amb),
    )
end

function window(inputs::SimulationInputs, first::Integer, len::Integer)
    grid = window(inputs.grid, first, len)
    rng = first:(first+grid.n-1)
    return SimulationInputs(
        grid,
        inputs.pv_kw[rng],
        inputs.load_kw[rng],
        inputs.price_buy[rng],
        inputs.price_sell[rng],
        inputs.t_amb[rng],
    )
end

Base.length(inputs::SimulationInputs) = inputs.grid.n
