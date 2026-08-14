@testitem "Aqua" tags = [:unit, :fast] begin
    using Aqua: Aqua
    Aqua.test_all(HEMSSimulator; ambiguities = false)
    Aqua.test_ambiguities(HEMSSimulator)
end

@testitem "JET finds no error paths in this package" tags = [:validation, :slow] begin
    using JET: JET

    # `report_package` walks every method in the package and follows the call graph out into the
    # dependencies, so most of what it returns is about DataFrames, CSV and JuMP internals rather
    # than about us — 101 reports at the time of writing, none of them ours. Asserting "no reports
    # at all" would therefore be a test of our dependencies' release notes. What is meaningful, and
    # what this asserts, is that no report is *located* in this package's own source.
    report = JET.report_package(HEMSSimulator; toplevel_logger = nothing)
    source = abspath(dirname(pathof(HEMSSimulator)))
    here(entry) = startswith(string(entry.file), source)
    ours = filter(rep -> here(last(rep.vst)), JET.get_reports(report))

    if !isempty(ours)
        for rep in ours
            frame = last(rep.vst)
            @info "JET report in package source" file = relpath(string(frame.file), source) line =
                frame.line kind = nameof(typeof(rep))
        end
    end
    @test isempty(ours)
end
