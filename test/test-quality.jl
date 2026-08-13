@testitem "Aqua" tags = [:unit, :fast] begin
    using Aqua: Aqua
    Aqua.test_all(BatteryBusinessCase; ambiguities = false)
    Aqua.test_ambiguities(BatteryBusinessCase)
end
