"""
    aoi(tilt, azimuth, zenith, solar_azimuth) -> Float64

Angle of incidence between the sun and a tilted surface, in degrees.

All angles are in degrees. `tilt` is measured from horizontal (0 = flat, 90 = vertical) and both
azimuths follow the [`SolarPosition`](https://github.com/JuliaAstro/SolarPosition.jl) convention:
0 = north, increasing clockwise, so 180 = south.
"""
function aoi(tilt::Real, azimuth::Real, zenith::Real, solar_azimuth::Real)
    cos_aoi =
        cosd(zenith) * cosd(tilt) +
        sind(zenith) * sind(tilt) * cosd(solar_azimuth - azimuth)
    return acosd(clamp(cos_aoi, -1.0, 1.0))
end

"""
    airmass(zenith) -> Float64

Relative optical air mass from the Kasten & Young (1989) formula, dimensionless. Returns `Inf` for a
sun below the horizon.
"""
function airmass(zenith::Real)
    zenith >= 90 && return Inf
    return 1 / (cosd(zenith) + 0.50572 * (96.07995 - zenith)^-1.6364)
end

"""
    AbstractTranspositionModel

Supertype for sky-diffuse transposition models, i.e. the models that convert diffuse horizontal
irradiance into the diffuse irradiance seen by a tilted plane. Concrete models are
[`Isotropic`](@ref), [`HayDavies`](@ref) and [`Perez`](@ref); they are singleton dispatch structs,
matching the algorithm-struct idiom of `SolarPosition.jl`.
"""
abstract type AbstractTranspositionModel end

"""
    Isotropic()

Assumes uniform sky radiance. Simplest and always well behaved, but systematically underestimates
plane-of-array irradiance for tilted surfaces under clear skies.
"""
struct Isotropic <: AbstractTranspositionModel end

"""
    HayDavies()

Splits the diffuse component into an isotropic and a circumsolar part weighted by the anisotropy
index. A good default: nearly as accurate as [`Perez`](@ref) for annual energy, far simpler.
"""
struct HayDavies <: AbstractTranspositionModel end

"""
    Perez()

The Perez et al. (1990) all-sites-composite model, with circumsolar and horizon-brightening terms.
The most accurate of the three, and the one to use when array tilt or azimuth is the quantity under
study.
"""
struct Perez <: AbstractTranspositionModel end

# Perez (1990) "all sites composite" coefficients. Rows are sky-clearness bins with upper bounds
# `PEREZ_BINS`; columns are F11, F12, F13, F21, F22, F23.
const PEREZ_BINS = (1.065, 1.23, 1.5, 1.95, 2.8, 4.5, 6.2, Inf)
const PEREZ_COEFFS = (
    (-0.008, 0.588, -0.062, -0.060, 0.072, -0.022),
    (0.130, 0.683, -0.151, -0.019, 0.066, -0.029),
    (0.330, 0.487, -0.221, 0.055, -0.064, -0.026),
    (0.568, 0.187, -0.295, 0.109, -0.152, -0.014),
    (0.873, -0.392, -0.362, 0.226, -0.462, 0.001),
    (1.132, -1.237, -0.412, 0.288, -0.823, 0.056),
    (1.060, -1.600, -0.359, 0.264, -1.127, 0.131),
    (0.678, -0.327, -0.250, 0.156, -1.377, 0.251),
)

"""
    sky_diffuse(model, tilt, incidence, zenith, dni, dhi, dni_extra) -> Float64

Diffuse irradiance on the tilted plane, W/m². `incidence` is the angle of incidence in degrees,
`dni_extra` the extraterrestrial normal irradiance in W/m².
"""
function sky_diffuse end

sky_diffuse(::Isotropic, tilt, _incidence, _zenith, _dni, dhi, _dni_extra) =
    dhi * (1 + cosd(tilt)) / 2

function sky_diffuse(::HayDavies, tilt, incidence, zenith, dni, dhi, dni_extra)
    dni_extra <= 0 && return dhi * (1 + cosd(tilt)) / 2
    anisotropy = clamp(dni / dni_extra, 0.0, 1.0)
    rb = max(0.0, cosd(incidence)) / max(cosd(zenith), COS_ZENITH_MIN)
    return dhi * (anisotropy * rb + (1 - anisotropy) * (1 + cosd(tilt)) / 2)
end

function sky_diffuse(::Perez, tilt, incidence, zenith, dni, dhi, dni_extra)
    (dhi <= 0 || dni_extra <= 0) && return 0.0
    # Sky clearness and brightness (Perez et al. 1990, eqs. 1 and 2).
    kappa = 5.535e-6
    clearness = ((dhi + dni) / dhi + kappa * zenith^3) / (1 + kappa * zenith^3)
    bin = findfirst(bound -> clearness < bound, PEREZ_BINS)
    bin === nothing && (bin = length(PEREZ_BINS))
    f11, f12, f13, f21, f22, f23 = PEREZ_COEFFS[bin]

    am = airmass(zenith)
    brightness = isfinite(am) ? dhi * am / dni_extra : 0.0
    z = deg2rad(zenith)
    f1 = max(0.0, f11 + f12 * brightness + f13 * z)
    f2 = f21 + f22 * brightness + f23 * z

    # Circumsolar term, clipped as in the original formulation to keep it finite at low sun.
    a = max(0.0, cosd(incidence))
    b = max(cosd(85), cosd(zenith))
    return dhi * ((1 - f1) * (1 + cosd(tilt)) / 2 + f1 * a / b + f2 * sind(tilt))
end

"""
    poa(model, tilt, azimuth, albedo; dni, dhi, ghi, zenith, solar_azimuth, dni_extra)
        -> (; beam, sky, ground, total)

Plane-of-array irradiance components for a single interval, W/m².

  - `beam`: direct irradiance projected onto the plane.
  - `sky`: diffuse sky irradiance, from the chosen [`AbstractTranspositionModel`](@ref).
  - `ground`: isotropically reflected ground irradiance.
  - `total`: their sum, the quantity the PV model converts to DC power.
"""
function poa(
    model::AbstractTranspositionModel,
    tilt::Real,
    azimuth::Real,
    albedo::Real;
    dni::Real,
    dhi::Real,
    ghi::Real,
    zenith::Real,
    solar_azimuth::Real,
    dni_extra::Real,
)
    incidence = aoi(tilt, azimuth, zenith, solar_azimuth)
    # No beam contribution when the sun is behind the plane or below the horizon.
    beam = (zenith >= 90 || incidence >= 90) ? 0.0 : dni * cosd(incidence)
    sky =
        zenith >= 90 ? 0.0 :
        sky_diffuse(model, tilt, incidence, zenith, dni, dhi, dni_extra)
    ground = ghi * albedo * (1 - cosd(tilt)) / 2
    sky = max(sky, 0.0)
    return (; beam, sky, ground, total = beam + sky + ground)
end
