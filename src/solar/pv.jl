"""
    PVArray(; dc_capacity_kwp, ac_capacity_kw, tilt, azimuth, kwargs...)

One PV array with its own inverter. A home may have several — a south array and an east/west array
behave very differently against a variable tariff — so [`HomeSystem`](@ref) holds a vector of these.

# Fields

  - `dc_capacity_kwp::Float64`: module capacity at standard test conditions, kWp.
  - `ac_capacity_kw::Float64`: inverter AC rating, kW. Production above this is clipped.
  - `tilt::Float64`: degrees from horizontal, 0 = flat.
  - `azimuth::Float64`: degrees, 0 = north increasing clockwise, so 180 = south.
  - `losses::Float64`: fractional DC-side losses (soiling, mismatch, wiring, degradation).
  - `temperature_coefficient::Float64`: power temperature coefficient, per °C. Negative.
  - `noct::Float64`: nominal operating cell temperature, °C.
  - `inverter_efficiency::Float64`: fractional, applied before clipping.
  - `transposition::AbstractTranspositionModel`: sky-diffuse model.

# Examples

```jldoctest
julia> array = PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180);

julia> array.dc_capacity_kwp
4.0
```
"""
Base.@kwdef struct PVArray
    dc_capacity_kwp::Float64
    ac_capacity_kw::Float64
    tilt::Float64
    azimuth::Float64
    losses::Float64 = 0.14
    temperature_coefficient::Float64 = -0.0035
    noct::Float64 = 45.0
    inverter_efficiency::Float64 = 0.96
    transposition::AbstractTranspositionModel = HayDavies()
end

"""
    solar_positions(site::Site, grid::TimeGrid)

Sun position for every interval of `grid`, evaluated at the interval midpoint so that a 15-minute
average is not biased by the sun's movement within the interval. Returns the `StructVector` of
`SolarPosition.jl`, with `.zenith` and `.azimuth` in degrees.
"""
function solar_positions(site::Site, grid::TimeGrid)
    midpoints = [timestamp(grid, k) + grid.step ÷ 2 for k = 1:grid.n]
    return solar_position(observer(site), midpoints)
end

"""
    cell_temperature(array::PVArray, poa_total, t_amb) -> Float64

Cell temperature in °C from the NOCT model. `poa_total` is plane-of-array irradiance in W/m².
"""
cell_temperature(array::PVArray, poa_total::Real, t_amb::Real) =
    t_amb + (array.noct - 20) / 800 * poa_total

"""
    production(array::PVArray, site::Site, weather::Weather; positions) -> Vector{Float64}

AC power produced by `array`, in kW, one element per interval of `weather.grid`.

Pass `positions` when producing for several arrays on the same grid, so the sun position is computed
once rather than once per array.
"""
function production(
    array::PVArray,
    site::Site,
    weather::Weather;
    positions = solar_positions(site, weather.grid),
)
    grid = weather.grid
    times = timestamps(grid)
    power = zeros(Float64, grid.n)
    for k = 1:grid.n
        zenith = positions.zenith[k]
        components = poa(
            array.transposition,
            array.tilt,
            array.azimuth,
            site.albedo;
            dni = weather.dni[k],
            dhi = weather.dhi[k],
            ghi = weather.ghi[k],
            zenith = zenith,
            solar_azimuth = positions.azimuth[k],
            dni_extra = extraterrestrial(times[k]),
        )
        components.total <= 0 && continue
        t_cell = cell_temperature(array, components.total, weather.t_amb[k])
        derate = 1 + array.temperature_coefficient * (t_cell - 25)
        dc = array.dc_capacity_kwp * (components.total / 1000) * derate * (1 - array.losses)
        power[k] = min(max(dc, 0.0) * array.inverter_efficiency, array.ac_capacity_kw)
    end
    return power
end

"""
    production(arrays::AbstractVector{PVArray}, site::Site, weather::Weather) -> Vector{Float64}

Total AC power of all arrays, kW per interval. Each array is clipped at its own inverter rating
before the sum, which is why an east/west split can out-produce a single south array on a
small inverter.
"""
function production(arrays::AbstractVector{PVArray}, site::Site, weather::Weather)
    isempty(arrays) && return zeros(Float64, weather.grid.n)
    positions = solar_positions(site, weather.grid)
    total = zeros(Float64, weather.grid.n)
    for array in arrays
        total .+= production(array, site, weather; positions)
    end
    return total
end

"""
    annual_yield(array::PVArray, site::Site, weather::Weather) -> Float64

Specific yield in kWh/kWp over the weather period. For the Netherlands a south-facing 35° array
lands near 900 kWh/kWp over a full year; this is the quickest sanity check on a weather dataset.
"""
function annual_yield(array::PVArray, site::Site, weather::Weather)
    energy = sum(production(array, site, weather)) * hours(weather.grid)
    return energy / array.dc_capacity_kwp
end
