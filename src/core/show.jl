# Compact `show` for the container types, plus a `text/plain` breakdown where the detail is what the
# user actually wants to see (a bill, a simulation).

Base.show(io::IO, grid::TimeGrid) =
    print(io, "TimeGrid($(grid.start), $(grid.step), $(grid.n))")

Base.show(io::IO, site::Site) =
    print(io, "Site($(site.latitude), $(site.longitude), $(site.altitude) m)")

Base.show(io::IO, array::PVArray) = print(
    io,
    "PVArray($(array.dc_capacity_kwp) kWp / $(array.ac_capacity_kw) kW, ",
    "tilt $(array.tilt)°, azimuth $(array.azimuth)°)",
)

Base.show(io::IO, battery::Battery) = print(
    io,
    "Battery($(battery.capacity_kwh) kWh, ",
    "$(battery.charge_power_kw)/$(battery.discharge_power_kw) kW)",
)

function Base.show(io::IO, system::HomeSystem)
    pv = isempty(system.pv) ? "no PV" : "$(sum(a.dc_capacity_kwp for a in system.pv)) kWp"
    return print(io, "HomeSystem($pv, $(length(system.assets)) assets)")
end

function Base.show(io::IO, ::MIME"text/plain", system::HomeSystem)
    println(io, "HomeSystem")
    println(io, "  site: ", system.site)
    println(io, "  connection: ", system.connection_kw, " kW")
    println(io, "  pv:")
    for array in system.pv
        println(io, "    ", array)
    end
    isempty(system.pv) && println(io, "    (none)")
    println(io, "  assets:")
    for asset in system.assets
        println(io, "    ", asset)
    end
    isempty(system.assets) && print(io, "    (none)")
    return nothing
end

Base.show(io::IO, weather::Weather) =
    print(io, "Weather($(weather.grid.n) intervals from $(weather.grid.start))")

Base.show(io::IO, result::SimulationResult) = print(
    io,
    "SimulationResult($(result.grid.n) intervals, $(result.windows) windows, ",
    "import $(round(imported_kwh(result), digits = 1)) kWh, ",
    "export $(round(exported_kwh(result), digits = 1)) kWh)",
)

function Base.show(io::IO, ::MIME"text/plain", result::SimulationResult)
    println(io, "SimulationResult")
    println(io, "  horizon:  ", result.grid.n, " intervals from ", result.grid.start)
    println(
        io,
        "  windows:  ",
        result.windows,
        " solves in ",
        round(result.solve_time, digits = 2),
        " s",
    )
    println(io, "  imported: ", round(imported_kwh(result), digits = 1), " kWh")
    println(io, "  exported: ", round(exported_kwh(result), digits = 1), " kWh")
    println(io, "  pv used:  ", round(produced_kwh(result), digits = 1), " kWh")
    println(
        io,
        "  self-consumption: ",
        round(100 * self_consumption(result), digits = 1),
        " %",
    )
    print(
        io,
        "  self-sufficiency: ",
        round(100 * self_sufficiency(result), digits = 1),
        " %",
    )
    return nothing
end

Base.show(io::IO, bill::Bill) = print(io, "Bill(€", round(bill.total, digits = 2), ")")

function Base.show(io::IO, ::MIME"text/plain", bill::Bill)
    println(io, "Bill over ", round(bill.years, digits = 3), " years")
    items = (
        ("commodity", bill.commodity_cost),
        ("netting credit", -bill.netting_credit),
        ("feed-in revenue", -bill.feed_in_revenue),
        ("energy tax", bill.energy_tax),
        ("tax credit", bill.tax_credit),
        ("transport", bill.transport_cost),
        ("fixed", bill.fixed_cost),
        ("VAT", bill.vat),
    )
    for (label, amount) in items
        @printf(io, "  %-16s %10.2f\n", label, amount)
    end
    @printf(io, "  %-16s %10.2f\n", "total", bill.total)
    @printf(
        io,
        "  imported %.1f kWh, exported %.1f kWh, netted %.1f kWh",
        bill.imported_kwh,
        bill.exported_kwh,
        bill.netted_kwh
    )
    return nothing
end
