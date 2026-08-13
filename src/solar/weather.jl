"""
    Site(latitude, longitude; altitude = 0.0, albedo = 0.2)

Geographic location of the modelled home.

# Fields

  - `latitude::Float64`: degrees, positive north.
  - `longitude::Float64`: degrees, positive east.
  - `altitude::Float64`: metres above mean sea level.
  - `albedo::Float64`: ground reflectance, dimensionless. 0.2 is the usual default for grass and
    built-up surroundings; raise it for snow.

Timestamps everywhere in this package are UTC, matching `SolarPosition.solar_position`.
"""
Base.@kwdef struct Site
    latitude::Float64
    longitude::Float64
    altitude::Float64 = 0.0
    albedo::Float64 = 0.2
end

Site(latitude::Real, longitude::Real; kwargs...) =
    Site(; latitude = float(latitude), longitude = float(longitude), kwargs...)

"""
    observer(site::Site) -> SolarPosition.Observer

The `SolarPosition.jl` observer for this site.
"""
observer(site::Site) = Observer(site.latitude, site.longitude; altitude = site.altitude)

"""
    Weather(grid; ghi, dni, dhi, t_amb, wind)

Exogenous weather aligned to a [`TimeGrid`](@ref). One element per interval.

# Fields

  - `ghi::Vector{Float64}`: global horizontal irradiance, W/m².
  - `dni::Vector{Float64}`: direct normal irradiance, W/m².
  - `dhi::Vector{Float64}`: diffuse horizontal irradiance, W/m².
  - `t_amb::Vector{Float64}`: ambient dry-bulb temperature, °C.
  - `wind::Vector{Float64}`: wind speed at 10 m, m/s. Used only by the PV cell temperature model.

If only `ghi` is available, use [`decompose`](@ref) to estimate `dni` and `dhi` first.
"""
struct Weather
    grid::TimeGrid
    ghi::Vector{Float64}
    dni::Vector{Float64}
    dhi::Vector{Float64}
    t_amb::Vector{Float64}
    wind::Vector{Float64}

    function Weather(
        grid::TimeGrid;
        ghi::AbstractVector,
        dni::AbstractVector,
        dhi::AbstractVector,
        t_amb::AbstractVector,
        wind::AbstractVector = fill(1.0, grid.n),
    )
        for (series, name) in
            ((ghi, "ghi"), (dni, "dni"), (dhi, "dhi"), (t_amb, "t_amb"), (wind, "wind"))
            checkseries(grid, series, name)
        end
        return new(
            grid,
            collect(Float64, ghi),
            collect(Float64, dni),
            collect(Float64, dhi),
            collect(Float64, t_amb),
            collect(Float64, wind),
        )
    end
end

Base.length(weather::Weather) = weather.grid.n

"""
    window(weather::Weather, first::Integer, len::Integer) -> Weather

Slice `len` intervals starting at interval `first`, for the rolling-horizon driver.
"""
function window(weather::Weather, first::Integer, len::Integer)
    grid = window(weather.grid, first, len)
    rng = first:(first+grid.n-1)
    return Weather(
        grid;
        ghi = weather.ghi[rng],
        dni = weather.dni[rng],
        dhi = weather.dhi[rng],
        t_amb = weather.t_amb[rng],
        wind = weather.wind[rng],
    )
end

"""
    extraterrestrial(timestamp::DateTime) -> Float64

Extraterrestrial normal irradiance, W/m², from the day of year using Spencer's Fourier series for
the Earth-Sun distance correction.
"""
function extraterrestrial(t::DateTime)
    doy = dayofyear(t)
    b = 2π * (doy - 1) / 365
    correction =
        1.00011 +
        0.034221 * cos(b) +
        0.00128 * sin(b) +
        0.000719 * cos(2b) +
        0.000077 * sin(2b)
    return SOLAR_CONSTANT * correction
end

"""
    decompose(model, ghi, zenith, timestamps) -> (dni, dhi)

Split global horizontal irradiance into its direct-normal and diffuse-horizontal components. Needed
for weather sources such as KNMI hourly data that report global radiation only.

`zenith` is in degrees. Returns two vectors in W/m².
"""
function decompose end

"""
    Erbs()

The Erbs et al. (1982) correlation: the diffuse fraction is a piecewise-polynomial function of the
clearness index `kt`. Cheap, widely used, and adequate for annual energy studies.
"""
struct Erbs end

function decompose(
    ::Erbs,
    ghi::AbstractVector,
    zenith::AbstractVector,
    times::AbstractVector{DateTime},
)
    n = length(ghi)
    dni = zeros(Float64, n)
    dhi = zeros(Float64, n)
    for k = 1:n
        cosz = cosd(zenith[k])
        # Below a few degrees of elevation the clearness index is numerically unstable and the
        # irradiance is negligible; treat it as fully diffuse.
        if cosz <= COS_ZENITH_MIN || ghi[k] <= 0
            dhi[k] = max(ghi[k], 0.0)
            dni[k] = 0.0
            continue
        end
        kt = clamp(ghi[k] / (extraterrestrial(times[k]) * cosz), 0.0, 1.0)
        fraction = if kt <= 0.22
            1.0 - 0.09kt
        elseif kt <= 0.80
            0.9511 - 0.1604kt + 4.388kt^2 - 16.638kt^3 + 12.336kt^4
        else
            0.165
        end
        dhi[k] = fraction * ghi[k]
        dni[k] = (ghi[k] - dhi[k]) / cosz
    end
    return dni, dhi
end
