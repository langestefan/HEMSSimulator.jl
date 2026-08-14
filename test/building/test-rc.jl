@testitem "RC networks have the nodes they were asked for" tags = [:unit, :fast] begin
    const B = BatteryBusinessCase

    full = BuildingSpec(120.0)
    @test B.nstates(full) == 3
    @test B.nstates(BuildingSpec(120.0; rc = RCSpec(emitter = false))) == 2
    @test B.nstates(BuildingSpec(120.0; rc = RCSpec(envelope = false))) == 2
    @test B.nstates(BuildingSpec(120.0; rc = RCSpec(false, false))) == 1

    for spec in (
        full,
        BuildingSpec(120.0; rc = RCSpec(emitter = false)),
        BuildingSpec(120.0; rc = RCSpec(envelope = false)),
        BuildingSpec(120.0; rc = RCSpec(false, false)),
    )
        n = B.nstates(spec)
        Ac, Bc = B.continuous(spec)
        @test size(Ac) == (n, n)
        @test size(Bc) == (n, 4)
        Ad, Bd = B.discretize(spec, 0.25)
        @test size(Ad) == (n, n)
        @test size(Bd) == (n, 4)
    end
end

@testitem "Discretisation is stable and preserves the physics" tags = [:unit, :fast] begin
    using LinearAlgebra: I, eigvals
    const B = BatteryBusinessCase

    spec = BuildingSpec(120.0; heat_loss_kw = 6.0)
    Ad, Bd = B.discretize(spec, 0.25)

    # A passive thermal network cannot amplify anything.
    @test maximum(abs, eigvals(Ad)) < 1

    # With no heat input and a constant outdoor temperature every node ends up at that temperature.
    # This is the single strongest check on the matrices: it fails if any conductance is misplaced.
    for ambient in (-10.0, 0.0, 18.0)
        @test all(≈(ambient), (I - Ad) \ (Bd[:, 1] * ambient))
    end

    # With constant heat and an ambient of zero, the steady state is set by the resistances alone.
    q = 2.0
    x = (I - Ad) \ (Bd[:, 2] * q)
    @test x[1] ≈ q / heat_loss_coefficient(spec)
    @test x[end] - x[1] ≈ q * spec.R_ih          # the emitter runs above the room
    @test x[2] > 0 && x[2] < x[1]                # the envelope sits between room and outside

    # Solar and internal gains enter the air node and are worth what they should be.
    solar = (I - Ad) \ (Bd[:, 3] * 500.0)
    @test solar[1] ≈ (500.0 * spec.A_w / 1000) / heat_loss_coefficient(spec)
    internal = (I - Ad) \ (Bd[:, 4] * 0.4)
    @test internal[1] ≈ 0.4 / heat_loss_coefficient(spec)

    @test_throws DimensionMismatch B.discretize(zeros(2, 2), zeros(3, 4), 0.25)
end

@testitem "A building can be specified from headline figures" tags = [:unit, :fast] begin
    # Heat loss at the design temperature difference is the number a homeowner has, and it is what
    # the derived conductance must reproduce — including when the envelope node is switched off,
    # where the whole loss has to travel down the one remaining path.
    for loss in (4.0, 6.0, 9.0), delta in (25.0, 30.0)
        spec = BuildingSpec(120.0; heat_loss_kw = loss, design_delta_k = delta)
        @test heat_loss_coefficient(spec) ≈ loss / delta
        simple = BuildingSpec(
            120.0;
            heat_loss_kw = loss,
            design_delta_k = delta,
            rc = RCSpec(envelope = false),
        )
        @test heat_loss_coefficient(simple) ≈ loss / delta
    end

    # The emitter runs the requested amount above the room at design load.
    spec = BuildingSpec(120.0; heat_loss_kw = 6.0, emitter_delta_k = 15.0)
    @test spec.R_ih * 6.0 ≈ 15.0
    # A bigger house has more mass.
    @test BuildingSpec(200.0).C_e > BuildingSpec(80.0).C_e

    @test_throws ArgumentError BuildingSpec(120.0; heat_loss_kw = 0.0)
    @test_throws ArgumentError BuildingSpec(0.0)
end

@testitem "COP falls as it gets colder, which is the whole problem" tags = [:unit, :fast] begin
    const B = BatteryBusinessCase

    for model in (CarnotCOP(), LinearCOP())
        temperatures = -15.0:1.0:25.0
        values = [B.cop(model, t) for t in temperatures]
        @test issorted(values)
        @test all(model.cop_min .<= values .<= model.cop_max)
        # Heat is dearest exactly when it is needed most.
        @test B.cop(model, -5.0) < B.cop(model, 10.0)
    end

    # A modern air-source unit at a 40 °C supply.
    @test B.cop(CarnotCOP(), 7.0) ≈ 4.27 atol = 0.01
    @test B.cop(CarnotCOP(), -5.0) ≈ 3.13 atol = 0.01
    # The clamps bite at the extremes rather than returning nonsense.
    @test B.cop(CarnotCOP(), 39.5) == CarnotCOP().cop_max
    @test B.cop(CarnotCOP(efficiency = 0.05), 7.0) == CarnotCOP().cop_min

    @test B.cop(LinearCOP(), 7.0) == 4.0
    @test B.cop(LinearCOP(), 17.0) == 5.0
end
