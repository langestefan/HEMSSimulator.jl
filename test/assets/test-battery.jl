@testitem "Battery state of charge follows its dynamics" tags = [:unit, :fast] setup =
    [SmallHome] begin
    battery = Battery(
        10.0,
        5.0;
        soc_initial = 0.5,
        charge_efficiency = 0.9,
        discharge_efficiency = 0.9,
    )
    system = with_assets(home, [battery])
    result = simulate(system, weather, load, contract)
    frame = result.frame
    dt = hours(grid)

    @test initial_state(battery) ≈ 5.0

    soc = frame.battery_soc_kwh
    for k = 2:length(grid)
        expected =
            soc[k-1] +
            dt * (0.9 * frame.battery_charge_kw[k] - frame.battery_discharge_kw[k] / 0.9)
        @test soc[k] ≈ expected atol = 1e-6
    end
    @test all(0.5 - 1e-6 .<= soc .<= 10.0 + 1e-6)
end
