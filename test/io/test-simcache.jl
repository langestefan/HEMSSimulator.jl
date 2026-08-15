@testsnippet SimCase begin
    using Dates: DateTime

    site = Site(52.1, 5.18)
    grid = TimeGrid(DateTime(2024, 4, 1), 96 * 2)
    weather = synthetic_weather(grid, site; seed = 7)
    load = synthetic_load(grid; annual_kwh = 3000)
    contract = Contract(grid; commodity = synthetic_prices(grid) .+ 0.02, feed_in = 0.04)
    home = HomeSystem(
        site = site,
        pv = [
            PVArray(dc_capacity_kwp = 4.0, ac_capacity_kw = 3.6, tilt = 35, azimuth = 180),
        ],
        assets = [Battery(10.0, 5.0)],
    )
    options = RunOptions(window_hours = 24, step_hours = 6, terminal_value = false)
    inputs = prepare(home, weather, load, contract; options)
end

@testitem "simulation_key separates what changes the answer" tags = [:unit, :fast] setup =
    [SimCase] begin
    key = simulation_key(home, inputs, options)
    @test length(key) == 64                       # sha256, hex
    @test simulation_key(home, inputs, options) == key      # and it is stable

    # A different battery, a different option, a different input series: all different simulations.
    bigger = with_assets(home, [Battery(12.0, 5.0)])
    @test simulation_key(bigger, inputs, options) != key
    @test simulation_key(home, inputs, RunOptions(; window_hours = 48, step_hours = 6)) !=
          key

    moved = SimulationInputs(
        inputs.grid,
        inputs.pv_kw,
        inputs.load_kw .+ 0.001,
        inputs.price_buy,
        inputs.price_sell,
        inputs.t_amb,
        inputs.ghi,
    )
    @test simulation_key(home, moved, options) != key

    # The contract is deliberately absent: `simulate` never reads it, and what it does change — the
    # dispatch prices — is already inside `inputs`.
    @test simulation_key(home, inputs, options) == key
end

@testitem "the simulation cache round-trips a result exactly" tags = [:integration, :fast] setup =
    [SimCase] begin
    mktempdir() do dir
        withenv("HEMS_SIMCACHE_DIR" => dir) do
            @test simulation_cache_dir() == dir

            fresh = simulate(home, inputs; options, cache = true)
            @test length(readdir(dir)) == 2          # one frame, one metadata sidecar

            hit = simulate(home, inputs; options, cache = true)
            # Exact, not approximate: a cache that loses the last bits silently changes every bill
            # computed from it.
            @test names(hit.frame) == names(fresh.frame)
            for column in names(fresh.frame)
                @test hit.frame[!, column] == fresh.frame[!, column]
            end
            @test hit.windows == fresh.windows
            @test hit.asset_columns == fresh.asset_columns
            @test settle(hit, contract).total == settle(fresh, contract).total

            # And it is genuinely a lookup rather than a re-solve.
            solved = 0
            again = simulate(
                home,
                inputs;
                options,
                cache = true,
                progress = (_, _) -> solved += 1,
            )
            @test solved == 0
            @test again.frame.import_kw == fresh.frame.import_kw

            clear_simulation_cache!()
            @test isempty(readdir(dir))
        end
    end
end

@testitem "caching is off unless asked for" tags = [:unit, :fast] setup = [SimCase] begin
    mktempdir() do dir
        withenv("HEMS_SIMCACHE_DIR" => dir) do
            simulate(home, inputs; options)
            @test isempty(readdir(dir))
        end
    end
end
