@testsnippet ThemeTools begin
    using PowerPlotsMakie
    using PowerModels
    using CairoMakie
    using Makie: RGBAf, to_color, with_theme

    CairoMakie.activate!(type = "png")
    PowerModels.silence()

    readcase(name) = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", name),
    )

    "A colour with no hue left in it."
    isgrey(c) = c.r == c.g == c.b

    "The colour drawn for the first component of type `comp`."
    nodecolor(p, net, comp) = p.gp_node_color[][first(vertex_indices(net, comp))]
    nodemarker(p, net, comp) = p.node_style[].markers[first(vertex_indices(net, comp))]
end

@testitem "The academic theme is monochrome" tags = [:integration] setup = [ThemeTools] begin
    net = powernetwork(readcase("case5.m"))
    with_theme(academic_theme()) do
        f, ax, p = powerplot(readcase("case5.m"))
        for comp in (:bus, :gen, :load)
            @test isgrey(nodecolor(p, net, comp))
        end
        @test isgrey(p.gp_edge_color[][first(edge_indices(net, :branch))])

        # Told apart by shape, not by hue: that is what survives a black-and-white printer.
        @test nodemarker(p, net, :bus) === :circle
        @test nodemarker(p, net, :load) === :dtriangle
        # A generator is an open marker, so it needs a stroke to be visible at all.
        @test nodecolor(p, net, :gen) == RGBAf(1, 1, 1, 1)
        @test p.node_strokewidth[] > 0
    end
end

@testitem "The academic theme drops the axis furniture" tags = [:integration] setup =
    [ThemeTools] begin
    with_theme(academic_theme()) do
        f, ax, p = powerplot(readcase("case5.m"))
        @test !ax.xgridvisible[]
        @test !ax.yticklabelsvisible[]
        @test !ax.leftspinevisible[]
        @test to_color(ax.backgroundcolor[]) == RGBAf(1, 1, 1, 1)
    end
end

@testitem "Connector stubs go solid in print" tags = [:integration] setup = [ThemeTools] begin
    f0, ax0, p0 = powerplot(readcase("case5.m"))
    @test p0.edge_style[].linestyles[end] === :dash

    with_theme(academic_theme()) do
        f, ax, p = powerplot(readcase("case5.m"))
        # A dashed stub reads as a circuit of its own once the colour is gone.
        @test p.edge_style[].linestyles[end] === :solid
    end
end

@testitem "monochrome = false keeps the palette" tags = [:integration] setup = [ThemeTools] begin
    net = powernetwork(readcase("case5.m"))
    with_theme(academic_theme(monochrome = false)) do
        f, ax, p = powerplot(readcase("case5.m"))
        @test !isgrey(nodecolor(p, net, :bus))
        # The typography and the line weights still change.
        @test p.node_strokewidth[] == 0.8
    end
end

@testitem "A theme does not survive its own block" tags = [:integration] setup =
    [ThemeTools] begin
    net = powernetwork(readcase("case5.m"))
    with_theme(academic_theme()) do
        powerplot(readcase("case5.m"))
    end
    f, ax, p = powerplot(readcase("case5.m"))
    @test !isgrey(nodecolor(p, net, :bus))
    @test p.node_strokewidth[] == 0.0
end

@testitem "component_defaults sit under components" tags = [:integration] setup =
    [ThemeTools] begin
    net = powernetwork(readcase("case5.m"))
    f, ax, p = powerplot(
        readcase("case5.m");
        component_defaults = Dict(
            :bus => (color = :black, marker = :rect),
            :gen => (color = :green, marker = :diamond),
        ),
        components = Dict(:bus => (color = :red,)),
    )

    # The caller wins for what it names...
    @test nodecolor(p, net, :bus) == RGBAf(1, 0, 0, 1)
    # ...but only for that, and only for that component.
    @test nodemarker(p, net, :bus) === :rect
    @test nodemarker(p, net, :gen) === :diamond
end

@testitem "A themed figure renders for print" tags = [:integration] setup = [ThemeTools] begin
    case = readcase("case5.m")
    for (i, (_, br)) in enumerate(sort(collect(case["branch"]); by = first))
        br["pf"] = (iseven(i) ? -1.0 : 1.0) * 10.0 * i
    end

    with_theme(academic_theme()) do
        f, ax, p = powerplot(case; flow = true)
        powerlegend!(f[1, 2], p)
        mktempdir() do dir
            for ext in ("pdf", "svg", "png")
                path = joinpath(dir, "academic.$ext")
                save(path, f)
                @test filesize(path) > 0
            end
        end
    end
end
