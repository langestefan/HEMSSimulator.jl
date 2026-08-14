@testitem "Cache: a second request is served from disk" tags = [:unit, :fast] begin
    original = get_cache()
    saved = (original.dir, original.enabled)
    try
        mktempdir() do dir
            set_cache(; dir, enabled = true)
            calls = Ref(0)
            fetch = () -> (calls[] += 1; "body $(calls[])")

            @test HEMSSimulator.cached(fetch, "key-a") == "body 1"
            @test HEMSSimulator.cached(fetch, "key-a") == "body 1"
            @test calls[] == 1

            # A different key is a different request.
            @test HEMSSimulator.cached(fetch, "key-b") == "body 2"
            @test calls[] == 2

            # `refresh` goes back to the source and overwrites.
            @test HEMSSimulator.cached(fetch, "key-a"; refresh = true) == "body 3"
            @test HEMSSimulator.cached(fetch, "key-a") == "body 3"
            @test calls[] == 3

            @test clear_cache!() == 2
            @test HEMSSimulator.cached(fetch, "key-a") == "body 4"
        end
    finally
        set_cache(; dir = saved[1], enabled = saved[2])
    end
end

@testitem "Cache: disabling it always hits the source" tags = [:unit, :fast] begin
    original = get_cache()
    saved = (original.dir, original.enabled)
    try
        mktempdir() do dir
            set_cache(; dir, enabled = false)
            calls = Ref(0)
            fetch = () -> (calls[] += 1; "body $(calls[])")

            @test HEMSSimulator.cached(fetch, "key") == "body 1"
            @test HEMSSimulator.cached(fetch, "key") == "body 2"
            @test calls[] == 2
            @test isempty(readdir(dir))
        end
    finally
        set_cache(; dir = saved[1], enabled = saved[2])
    end
end

@testitem "Cache: the path is stable and keyed by content" tags = [:unit, :fast] begin
    a = HEMSSimulator.cache_path("https://example.org/a"; tag = "t", ext = ".json")
    b = HEMSSimulator.cache_path("https://example.org/b"; tag = "t", ext = ".json")
    @test a == HEMSSimulator.cache_path("https://example.org/a"; tag = "t", ext = ".json")
    @test a != b
    @test endswith(a, ".json")
    @test occursin("t-", basename(a))
end
