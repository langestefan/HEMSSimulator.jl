@testitem "Aqua" tags = [:unit, :fast] begin
    using Aqua: Aqua
    Aqua.test_all(HEMSSimulator; ambiguities = false)
    Aqua.test_ambiguities(HEMSSimulator)
end
