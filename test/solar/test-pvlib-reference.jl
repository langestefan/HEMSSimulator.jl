@testmodule PvlibReference begin
    # Reference values from pvlib-python 0.15.2, the de facto standard implementation of these
    # models. Generated once and pinned here rather than recomputed, so the test does not need
    # Python; regenerate with the script below if a model changes.
    #
    #     import pvlib
    #     am = pvlib.atmosphere.get_relative_airmass(zenith)
    #     pvlib.irradiance.get_total_irradiance(tilt, azimuth, zenith, solar_azimuth,
    #         dni=dni, ghi=ghi, dhi=dhi, dni_extra=dni_extra, airmass=am,
    #         albedo=0.2, model=model)
    #
    # The conditions span the cases where the three models actually disagree: a high clear sun, a
    # low winter sun, a fully overcast sky with no beam at all, a hazy morning, a surface with the
    # sun behind it, and a sun almost on the horizon shining straight down a west wall.
    const ALBEDO = 0.2

    const CONDITIONS = [
        (name = "summer noon clear", zenith = 30.0, solar_azimuth = 180.0, dni = 850.0, dhi = 90.0, ghi = 826.2, dni_extra = 1321.0),
        (name = "winter noon clear", zenith = 70.0, solar_azimuth = 180.0, dni = 700.0, dhi = 60.0, ghi = 299.4, dni_extra = 1413.0),
        (name = "overcast", zenith = 45.0, solar_azimuth = 150.0, dni = 0.0, dhi = 250.0, ghi = 250.0, dni_extra = 1367.0),
        (name = "hazy morning", zenith = 75.0, solar_azimuth = 110.0, dni = 300.0, dhi = 150.0, ghi = 227.6, dni_extra = 1390.0),
        (name = "sun behind plane", zenith = 60.0, solar_azimuth = 0.0, dni = 600.0, dhi = 120.0, ghi = 420.0, dni_extra = 1367.0),
        (name = "low sun west", zenith = 85.0, solar_azimuth = 275.0, dni = 450.0, dhi = 70.0, ghi = 109.2, dni_extra = 1367.0),
    ]

    const SURFACES = [
        (tilt = 35.0, azimuth = 180.0),
        (tilt = 0.0, azimuth = 180.0),
        (tilt = 90.0, azimuth = 270.0),
        (tilt = 20.0, azimuth = 90.0),
    ]

    # (condition, surface, model) => (sky, beam, ground, total), all W/m²
    const EXPECTED = Dict(
        (1, 1, :isotropic) => (81.861842, 846.765493, 14.941658, 943.568993),
        (1, 1, :haydavies) => (95.802709, 846.765493, 14.941658, 957.509861),
        (1, 1, :perez) => (102.406805, 846.765493, 14.941658, 964.113956),
        (1, 2, :isotropic) => (90.000000, 736.121593, 0.000000, 826.121593),
        (1, 2, :haydavies) => (90.000000, 736.121593, 0.000000, 826.121593),
        (1, 2, :perez) => (90.000000, 736.121593, 0.000000, 826.121593),
        (1, 3, :isotropic) => (45.000000, 0.000000, 82.620000, 127.620000),
        (1, 3, :haydavies) => (16.044663, 0.000000, 82.620000, 98.664663),
        (1, 3, :perez) => (37.661911, 0.000000, 82.620000, 120.281911),
        (1, 4, :isotropic) => (87.286168, 691.728029, 4.982596, 783.996793),
        (1, 4, :haydavies) => (85.539947, 691.728029, 4.982596, 782.250572),
        (1, 4, :perez) => (91.386106, 691.728029, 4.982596, 788.096731),
        (2, 1, :isotropic) => (54.574561, 573.406431, 5.414588, 633.395580),
        (2, 1, :haydavies) => (98.728490, 573.406431, 5.414588, 677.549509),
        (2, 1, :perez) => (102.190908, 573.406431, 5.414588, 681.011927),
        (2, 2, :isotropic) => (60.000000, 239.414100, 0.000000, 299.414100),
        (2, 2, :haydavies) => (60.000000, 239.414100, 0.000000, 299.414100),
        (2, 2, :perez) => (60.000000, 239.414100, 0.000000, 299.414100),
        (2, 3, :isotropic) => (30.000000, 0.000000, 29.940000, 59.940000),
        (2, 3, :haydavies) => (15.138004, 0.000000, 29.940000, 45.078004),
        (2, 3, :perez) => (34.382166, 0.000000, 29.940000, 64.322166),
        (2, 4, :isotropic) => (58.190779, 224.975663, 1.805603, 284.972045),
        (2, 4, :haydavies) => (57.294491, 224.975663, 1.805603, 284.075757),
        (2, 4, :perez) => (63.274284, 224.975663, 1.805603, 290.055550),
        (3, 1, :isotropic) => (227.394006, 0.000000, 4.521199, 231.915204),
        (3, 1, :haydavies) => (227.394006, 0.000000, 4.521199, 231.915204),
        (3, 1, :perez) => (228.650848, 0.000000, 4.521199, 233.172047),
        (3, 2, :isotropic) => (250.000000, 0.000000, 0.000000, 250.000000),
        (3, 2, :haydavies) => (250.000000, 0.000000, 0.000000, 250.000000),
        (3, 2, :perez) => (250.000000, 0.000000, 0.000000, 250.000000),
        (3, 3, :isotropic) => (125.000000, 0.000000, 25.000000, 150.000000),
        (3, 3, :haydavies) => (125.000000, 0.000000, 25.000000, 150.000000),
        (3, 3, :perez) => (98.429356, 0.000000, 25.000000, 123.429356),
        (3, 4, :isotropic) => (242.461578, 0.000000, 1.507684, 243.969262),
        (3, 4, :haydavies) => (242.461578, 0.000000, 1.507684, 243.969262),
        (3, 4, :perez) => (240.796958, 0.000000, 1.507684, 242.304642),
        (4, 1, :isotropic) => (136.436403, 120.450706, 4.116099, 261.003209),
        (4, 1, :haydavies) => (157.211186, 120.450706, 4.116099, 281.777992),
        (4, 1, :perez) => (163.766932, 120.450706, 4.116099, 288.333738),
        (4, 2, :isotropic) => (150.000000, 77.645714, 0.000000, 227.645714),
        (4, 2, :haydavies) => (150.000000, 77.645714, 0.000000, 227.645714),
        (4, 2, :perez) => (150.000000, 77.645714, 0.000000, 227.645714),
        (4, 3, :isotropic) => (75.000000, 0.000000, 22.760000, 97.760000),
        (4, 3, :haydavies) => (58.812950, 0.000000, 22.760000, 81.572950),
        (4, 3, :perez) => (59.810454, 0.000000, 22.760000, 82.570454),
        (4, 4, :isotropic) => (145.476947, 166.095877, 1.372596, 312.945420),
        (4, 4, :haydavies) => (183.332122, 166.095877, 1.372596, 350.800595),
        (4, 4, :perez) => (192.310793, 166.095877, 1.372596, 359.779266),
        (5, 1, :isotropic) => (109.149123, 0.000000, 7.595614, 116.744737),
        (5, 1, :haydavies) => (61.241680, 0.000000, 7.595614, 68.837295),
        (5, 1, :perez) => (70.263460, 0.000000, 7.595614, 77.859074),
        (5, 2, :isotropic) => (120.000000, 300.000000, 0.000000, 420.000000),
        (5, 2, :haydavies) => (120.000000, 300.000000, 0.000000, 420.000000),
        (5, 2, :perez) => (120.000000, 300.000000, 0.000000, 420.000000),
        (5, 3, :isotropic) => (60.000000, 0.000000, 42.000000, 102.000000),
        (5, 3, :haydavies) => (33.664960, 0.000000, 42.000000, 75.664960),
        (5, 3, :perez) => (55.267773, 0.000000, 42.000000, 97.267773),
        (5, 4, :isotropic) => (116.381557, 281.907786, 2.532910, 400.822253),
        (5, 4, :haydavies) => (114.793360, 281.907786, 2.532910, 399.234056),
        (5, 4, :perez) => (122.943946, 281.907786, 2.532910, 407.384642),
        (6, 1, :isotropic) => (63.670322, 9.717099, 1.974860, 75.362280),
        (6, 1, :haydavies) => (48.419948, 9.717099, 1.974860, 60.111907),
        (6, 1, :perez) => (57.034280, 9.717099, 1.974860, 68.726239),
        (6, 2, :isotropic) => (70.000000, 39.220084, 0.000000, 109.220084),
        (6, 2, :haydavies) => (70.000000, 39.220084, 0.000000, 109.220084),
        (6, 2, :perez) => (70.000000, 39.220084, 0.000000, 109.220084),
        (6, 3, :isotropic) => (35.000000, 446.581744, 10.920000, 492.501744),
        (6, 3, :haydavies) => (285.860689, 446.581744, 10.920000, 743.362433),
        (6, 3, :perez) => (132.233172, 446.581744, 10.920000, 589.734917),
        (6, 4, :isotropic) => (67.889242, 0.000000, 0.658557, 68.547798),
        (6, 4, :haydavies) => (45.540918, 0.000000, 0.658557, 46.199474),
        (6, 4, :perez) => (58.734356, 0.000000, 0.658557, 59.392912),
    )
end

@testitem "Transposition matches pvlib" tags = [:validation, :fast] setup =
    [PvlibReference] begin
    # Every other transposition test in this package checks an invariant — horizontal reproduces
    # GHI, nothing at night, tilting toward the sun gains. Invariants cannot catch a mistyped Perez
    # coefficient or a sign error in the circumsolar term, because a wrong model still satisfies
    # them. These are absolute values from an independent implementation.
    models = Dict(:isotropic => Isotropic(), :haydavies => HayDavies(), :perez => Perez())

    for ((ci, si, name), expected) in PvlibReference.EXPECTED
        condition = PvlibReference.CONDITIONS[ci]
        surface = PvlibReference.SURFACES[si]
        got = poa(
            models[name],
            surface.tilt,
            surface.azimuth,
            PvlibReference.ALBEDO;
            dni = condition.dni,
            dhi = condition.dhi,
            ghi = condition.ghi,
            zenith = condition.zenith,
            solar_azimuth = condition.solar_azimuth,
            dni_extra = condition.dni_extra,
        )
        label = "$(condition.name) / tilt $(surface.tilt) azimuth $(surface.azimuth) / $name"
        @test got.sky ≈ expected[1] rtol = 1e-5
        @test got.beam ≈ expected[2] rtol = 1e-5
        @test got.ground ≈ expected[3] rtol = 1e-5
        @test (got.total, label)[1] ≈ expected[4] rtol = 1e-5
    end
end

@testitem "Air mass matches pvlib's Kasten-Young" tags = [:validation, :fast] begin
    # pvlib.atmosphere.get_relative_airmass(z, model="kastenyoung1989")
    for (zenith, expected) in (
        (0.0, 0.999712),
        (30.0, 1.153992),
        (60.0, 1.994293),
        (75.0, 3.812912),
        (85.0, 10.305791),
        (89.0, 26.310555),
    )
        @test airmass(zenith) ≈ expected rtol = 1e-5
    end
    @test airmass(90.0) == Inf
    @test airmass(120.0) == Inf
end
