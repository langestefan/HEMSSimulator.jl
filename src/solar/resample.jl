"""
    upsample_irradiance(site, grid, times, ghi; dhi = nothing) -> (; ghi, dni, dhi)

Refine an hourly irradiance series onto the finer `grid`, in W/m².

Irradiance cannot be resampled with either of the generic methods in `core/resample.jl`. Holding an
hourly value flat gives a sunrise that switches on in one step; interpolating it linearly smears the
morning and evening ramps and misplaces the peak by half an hour. Both distort inverter clipping and
therefore the self-consumption a battery is being sized against.

What varies slowly is not the irradiance but the *sky*. So:

 1. Reduce each source interval to a clearness index `kt = GHI / clearsky_GHI`, evaluated at that
    interval's own solar position — a number that reflects cloud cover alone.
 2. Interpolate `kt` linearly onto `grid` ([`LinearInterp`](@ref)).
 3. Rebuild `GHI = kt × clearsky_GHI(zenith)` at each fine interval's *actual* solar position, so
    the diurnal shape comes from geometry rather than from interpolation.
 4. Rescale within each source interval so its sub-intervals average back to the value that was
    downloaded. Energy is conserved exactly, which is the invariant the tests assert.

The diffuse component is handled the same way through the diffuse fraction `DHI / GHI`, and the
direct normal component is then **re-derived** from the closure equation `DNI = (GHI − DHI) / cos z`
rather than interpolated, so the three components stay mutually consistent at every interval. Pass
`dhi = nothing` (the default) for a GHI-only source such as a KNMI station: the split is then made
with [`Erbs`](@ref) after upsampling.

`times` are the interval-beginning timestamps of the source series, in UTC, and must be uniformly
spaced and cover `grid` — see [`source_step`](@ref).
"""
function upsample_irradiance(
    site::Site,
    grid::TimeGrid,
    times::AbstractVector{DateTime},
    ghi::AbstractVector{<:Real};
    dhi::Union{Nothing,AbstractVector{<:Real}} = nothing,
)
    length(times) == length(ghi) || throw(
        ArgumentError("got $(length(times)) timestamps but $(length(ghi)) GHI values"),
    )
    step = source_step(times)

    # Clearness index of each source interval, at that interval's own midpoint.
    src_mid = times .+ (step ÷ 2)
    src_clear = clearsky_ghi.(solar_position(observer(site), src_mid).zenith)
    kt_src = [
        src_clear[i] > 0 ? clamp(ghi[i] / src_clear[i], 0.0, 1.2) : 0.0 for
        i in eachindex(ghi)
    ]

    positions = solar_positions(site, grid)
    fine_clear = clearsky_ghi.(positions.zenith)
    fine_ghi = resample(LinearInterp(), times, kt_src, grid) .* fine_clear
    _conserve!(fine_ghi, ghi, times, step, grid)

    fine_dhi = if dhi === nothing
        _, d = decompose(Erbs(), fine_ghi, positions.zenith, timestamps(grid))
        d
    else
        length(dhi) == length(ghi) || throw(
            ArgumentError("got $(length(ghi)) GHI values but $(length(dhi)) DHI values"),
        )
        fraction = [
            ghi[i] > 0 ? clamp(dhi[i] / ghi[i], 0.0, 1.0) : 1.0 for i in eachindex(ghi)
        ]
        d = resample(LinearInterp(), times, fraction, grid) .* fine_ghi
        _conserve!(d, dhi, times, step, grid)
        # The rescale is energy-preserving but blind to the closure constraint, so clip the rare
        # interval where it would push the diffuse component above the global one.
        clamp.(d, 0.0, fine_ghi)
    end

    fine_dni = similar(fine_ghi)
    for k = 1:grid.n
        cosz = cosd(positions.zenith[k])
        fine_dni[k] =
            cosz > COS_ZENITH_MIN ? max(0.0, (fine_ghi[k] - fine_dhi[k]) / cosz) : 0.0
    end

    return (; ghi = fine_ghi, dni = fine_dni, dhi = fine_dhi)
end

# Scale `fine` within each source interval so its sub-intervals average back to `coarse`. When the
# reconstructed shape is identically zero over a source interval but the source is not (twilight,
# sensor noise, a snow-covered pyranometer), fall back to spreading the energy flat: conserving it
# matters more than the shape at those levels.
function _conserve!(
    fine::AbstractVector{Float64},
    coarse::AbstractVector{<:Real},
    times::AbstractVector{DateTime},
    step::Millisecond,
    grid::TimeGrid,
)
    groups = group_indices(times, step, grid)
    sums = zeros(Float64, length(coarse))
    counts = zeros(Int, length(coarse))
    for k = 1:grid.n
        sums[groups[k]] += fine[k]
        counts[groups[k]] += 1
    end
    for k = 1:grid.n
        g = groups[k]
        fine[k] = if sums[g] > 0
            max(0.0, fine[k] * coarse[g] * counts[g] / sums[g])
        else
            max(0.0, coarse[g])
        end
    end
    return fine
end
