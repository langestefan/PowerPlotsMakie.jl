@testsnippet MapTools begin
    using PowerPlotsMakie
    using PowerPlotsMakie: WEB_MERCATOR_RADIUS
    using PowerModels
    using CairoMakie
    using Tyler
    using Makie: Point2f, Point2d
    using Colors: RGB, N0f8
    using FileIO: load

    CairoMakie.activate!(type = "png")
    PowerModels.silence()

    const Ext = Base.get_extension(PowerPlotsMakie, :PPMTylerExt)
    const TileProviders = Tyler.TileProviders

    readcase(name) = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", name),
    )

    """
    case5 in the Netherlands, by longitude and latitude: buses spread east of Utrecht, and
    branch "1" given a route.
    """
    function lonlat_case5()
        case = readcase("case5.m")
        for (i, id) in enumerate(sort(collect(keys(case["bus"])); by = x -> parse(Int, x)))
            case["bus"][id]["xcoord_1"], case["bus"][id]["ycoord_1"] =
                (5.0 + 0.1i, 52.0 + 0.05i)
        end
        case["branch"]["1"]["coordinates"] = [[5.1, 52.05], [5.15, 52.0], [5.2, 52.1]]
        return case
    end

    """
    A tile provider that needs no network: every tile is the same small PNG on disk, fetched
    through a `file://` URL.
    """
    function local_provider()
        path = joinpath(mktempdir(), "tile.png")
        save(path, fill(CairoMakie.RGBf(0.2, 0.4, 0.8), 256, 256))
        return TileProviders.Provider(
            "file://" * path;
            max_zoom = 4,
            attribution = "&copy; <a href=\"https://example.org\">Test tiles</a>",
        )
    end
end

@testitem "Web Mercator projects longitude and latitude to metres" tags = [:unit, :fast] setup =
    [MapTools] begin
    @test isapprox(web_mercator((0, 0)), Point2d(0, 0); atol = 1e-6)
    @test web_mercator((180, 0))[1] ≈ π * WEB_MERCATOR_RADIUS
    # The square world: the clamped latitude reaches as far north as 180° reaches east.
    @test web_mercator((0, 85.0511287798066))[2] ≈ π * WEB_MERCATOR_RADIUS
    @test web_mercator((0, 89.9)) == web_mercator((0, 90))
    # Utrecht, as Proj has it in EPSG:3857.
    @test isapprox(
        web_mercator((5.1214, 52.0907)),
        Point2d(570_111.640, 6_816_541.821);
        atol = 1e-3,
    )
end

@testitem "The projection moves buses and routes together" tags = [:integration] setup =
    [MapTools] begin
    case = lonlat_case5()
    f, ax, p = powerplot(case; projection = web_mercator)
    net = powernetwork(case)
    bus1 =
        only(i for (i, r) in enumerate(net.vertices) if r.component === :bus && r.id == "1")
    @test p.node_pos[][bus1] ≈ Point2f(web_mercator((5.1, 52.05)))
    route = only(values(p.edge_routes[]))
    @test route ≈
          Point2f[web_mercator(q) for q in ((5.1, 52.05), (5.15, 52.0), (5.2, 52.1))]

    # Changing the projection redraws the network where it now lies.
    p.projection = identity
    @test p.node_pos[][bus1] ≈ Point2f(5.1, 52.05)
    @test only(values(p.edge_routes[]))[2] ≈ Point2f(5.15, 52.0)
end

@testitem "powermap draws the network over tiles" tags = [:integration] setup = [MapTools] begin
    case = lonlat_case5()
    provider = local_provider()
    f, ax, p = powermap(case; provider, fade = 0.5)
    @test p isa PowerPlotsMakie.PowerPlot
    m = basemap(p)
    @test m isa Tyler.Map
    @test basemap(powerplot!(Axis(Figure()[1, 1]), case)) === nothing

    # Tiles are fetched as this package, through the provider's own URL.
    @test m.provider isa Ext.IdentifiedProvider
    @test startswith(m.provider.user_agent, "PowerPlotsMakie.jl/")
    @test m.provider.url == provider.url
    @test m.provider.options == provider.options

    # The network is above the tiles, and the view starts on it with a margin.
    @test Makie.translation(p)[][3] == Ext.NETWORK_DEPTH
    xs = [q[1] for q in p.node_pos[]]
    lims = ax.finallimits[]
    @test minimum(lims)[1] < minimum(xs) && maximum(lims)[1] > maximum(xs)

    # The credit is the provider's, as text.
    texts = filter(q -> q isa Makie.Text, ax.scene.plots)
    @test any(t -> t.text[] == ["© Test tiles"], texts)

    # Saving waits for the tiles and draws them, faded halfway to white.
    path = joinpath(mktempdir(), "map.png")
    save(path, f)
    @test !isempty(m.plots)
    near(c) = all(abs.(Float32.((c.r, c.g, c.b)) .- (0.6f0, 0.7f0, 0.9f0)) .< 0.02f0)
    @test count(near, load(path)) > 0.5 * length(load(path))
    @test near(only(Ext._fade(fill(RGB{N0f8}(0.2, 0.4, 0.8), 1, 1), 0.5f0)))
end

@testitem "powermap options" tags = [:integration] setup = [MapTools] begin
    case = lonlat_case5()
    provider = local_provider()
    f = Figure()
    ax = Axis(f[1, 1])
    p = powermap!(ax, case; provider, attribution = false, user_agent = nothing)
    @test basemap(p).provider === provider
    @test !any(q -> q isa Makie.Text, ax.scene.plots)

    ax2 = Axis(f[1, 2])
    powermap!(ax2, case; provider, attribution = "tiles: mine")
    @test any(q -> q isa Makie.Text && q.text[] == ["tiles: mine"], ax2.scene.plots)

    @test_throws ArgumentError powermap!(Axis(f[1, 3]), case; provider, fade = 2)
    # A provider that is not a plain URL template is left for Tyler to fetch its way.
    @test Ext._identified(:other, "agent") === :other
end

@testitem "Without Tyler the map functions say what is missing" tags = [:unit, :fast] begin
    using PowerPlotsMakie
    err = try
        basemap(42)
    catch e
        e
    end
    @test err isa MethodError
    @test occursin("using Tyler", sprint(showerror, err))
end
