@testitem "Angle of incidence" tags = [:unit, :fast] begin
    # `acos` is ill-conditioned near an argument of 1: an error of 1e-16 in the cosine becomes
    # about 1e-6 degrees in the angle. That is harmless here because every consumer takes the
    # cosine again, but it is why these tolerances are not tighter.
    @test aoi(0, 180, 0, 180) ≈ 0 atol = 1e-5
    # Panel pointing straight at the sun.
    @test aoi(30, 180, 30, 180) ≈ 0 atol = 1e-5
    # A flat panel sees the incidence angle equal to the zenith angle, whatever the azimuth.
    @test aoi(0, 180, 40, 90) ≈ 40 atol = 1e-9
    # Sun behind the panel.
    @test aoi(90, 180, 45, 0) > 90
end

@testitem "Air mass" tags = [:unit, :fast] begin
    # Overhead sun traverses one atmosphere; the value grows monotonically toward the horizon.
    @test airmass(0) ≈ 1.0 atol = 1e-3
    @test airmass(60) ≈ 2.0 atol = 0.01
    @test airmass(30) < airmass(60) < airmass(85)
    @test airmass(90) == Inf
end

@testitem "Transposition onto a horizontal plane reproduces GHI" tags = [:unit, :fast] begin
    # This is the identity every transposition model must satisfy: with zero tilt the beam
    # projection is cos(zenith), the whole sky is visible and no ground is, so POA == GHI.
    zenith, azimuth = 40.0, 150.0
    dni, dhi = 700.0, 150.0
    ghi = dni * cosd(zenith) + dhi
    for model in (Isotropic(), HayDavies(), Perez())
        components = poa(
            model,
            0.0,
            180.0,
            0.2;
            dni,
            dhi,
            ghi,
            zenith,
            solar_azimuth = azimuth,
            dni_extra = 1367.0,
        )
        @test components.total ≈ ghi rtol = 1e-6
        @test components.ground ≈ 0 atol = 1e-12
    end
end

@testitem "Transposition is zero at night" tags = [:unit, :fast] begin
    for model in (Isotropic(), HayDavies(), Perez())
        components = poa(
            model,
            35.0,
            180.0,
            0.2;
            dni = 0.0,
            dhi = 0.0,
            ghi = 0.0,
            zenith = 110.0,
            solar_azimuth = 0.0,
            dni_extra = 1367.0,
        )
        @test components.total == 0
    end
end

@testitem "Tilting toward the sun gains irradiance" tags = [:unit, :fast] begin
    # Low winter sun in the south: a tilted array must collect more than a flat one, and the
    # anisotropic models must collect at least as much as the isotropic one because they
    # concentrate diffuse radiation around the solar disc.
    args = (;
        dni = 800.0,
        dhi = 120.0,
        ghi = 320.0,
        zenith = 65.0,
        solar_azimuth = 180.0,
        dni_extra = 1400.0,
    )
    flat = poa(HayDavies(), 0.0, 180.0, 0.2; args...).total
    tilted = poa(HayDavies(), 45.0, 180.0, 0.2; args...).total
    @test tilted > flat

    isotropic = poa(Isotropic(), 45.0, 180.0, 0.2; args...).total
    @test poa(HayDavies(), 45.0, 180.0, 0.2; args...).total >= isotropic
    @test poa(Perez(), 45.0, 180.0, 0.2; args...).total >= isotropic
end

@testitem "Erbs decomposition is self-consistent" tags = [:unit, :fast] begin
    using Dates: DateTime

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 6, 21), 96)
    positions = solar_positions(site, grid)
    times = timestamps(grid)
    ghi = [clearsky_ghi(z) * 0.8 for z in positions.zenith]

    dni, dhi = decompose(Erbs(), ghi, positions.zenith, times)

    for k = 1:length(grid)
        @test dhi[k] >= 0
        @test dni[k] >= 0
        @test dhi[k] <= ghi[k] + 1e-9
        # The components must reconstruct the global horizontal irradiance they came from.
        if cosd(positions.zenith[k]) > 0.05
            @test dni[k] * cosd(positions.zenith[k]) + dhi[k] ≈ ghi[k] rtol = 1e-8
        end
    end
end
