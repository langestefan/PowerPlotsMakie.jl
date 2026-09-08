@testsnippet LegendTools begin
    using PowerPlotsMakie
    using PowerModels
    using CairoMakie
    using Makie: Colorbar, Legend, LineElement, MarkerElement, RGBAf

    CairoMakie.activate!(type = "png")
    PowerModels.silence()

    readcase(name) = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", name),
    )

    "The entry for one component, or `nothing`."
    entry(entries, comp) =
        findfirst(e -> e.component === comp, entries) |>
        i -> i === nothing ? nothing : entries[i]
end

@testitem "A default plot is keyed by component type" tags = [:integration] setup =
    [LegendTools] begin
    f, ax, p = powerplot(readcase("case5.m"))
    entries = legend_entries(p)

    # Every component the plot draws, in drawing order: nodes, injections, then edges.
    @test [e.component for e in entries] == [:bus, :gen, :load, :branch]
    @test all(e -> e.result.kind === :constant, entries)
    # Connectors are plumbing, not data.
    @test !any(e -> e.component === :connector, entries)

    elements, labels, titles = legend_groups(entries)
    # One legend per styled component, gathered into a single group: with flat colours the
    # group is itself the key to which colour is which component.
    @test titles == ["component"]
    @test labels == [["bus", "gen", "load", "branch"]]
    @test length(only(elements)) == 4

    # A swatch is shaped like the thing it describes.
    @test all(el -> el isa MarkerElement, only(elements)[1:3])
    @test only(elements)[4] isa LineElement
end

@testitem "Continuous colouring gives a colorbar, not a legend entry" tags = [:integration] setup =
    [LegendTools] begin
    f, ax, p = powerplot(
        readcase("case5.m");
        components = Dict(:bus => (color = Field(:vm), colormap = :viridis)),
    )
    key = powerlegend!(f[1, 2], p)

    @test key.legend isa Legend
    @test length(key.colorbars) == 1
    @test only(key.colorbars) isa Colorbar
    # The bus is described by the bar, so it must not also appear as a flat swatch.
    _, labels, _ = legend_groups(legend_entries(p))
    @test "bus" ∉ only(labels)
    @test entry(legend_entries(p), :bus).result.kind === :continuous
end

@testitem "A categorical component gets its own titled group" tags = [:integration] setup =
    [LegendTools] begin
    f, ax, p = powerplot(
        readcase("case5.m");
        components = Dict(:bus => (color = Field(:bus_type), colormode = :categorical)),
    )
    _, labels, titles = legend_groups(legend_entries(p))

    @test "bus (bus_type)" in titles
    i = findfirst(==("bus (bus_type)"), titles)
    # case5 has a reference bus (3) alongside PV (2) and PQ (1) buses.
    @test labels[i] == ["1", "2", "3"]
    # The flat group still describes everything else, and comes first.
    @test titles[1] == "component"
end

@testitem "The key is restricted to the named components" tags = [:integration] setup =
    [LegendTools] begin
    f, ax, p =
        powerplot(readcase("case5.m"); components = Dict(:bus => (color = Field(:vm),)))

    @test [e.component for e in legend_entries(p; components = [:gen])] == [:gen]

    # Only the bus: nothing flat is left, so there is no Legend at all.
    key = powerlegend!(f[1, 2], p; components = [:bus])
    @test key.legend === nothing
    @test length(key.colorbars) == 1

    # Only flat components: no colorbar.
    key2 = powerlegend!(f[1, 3], p; components = [:gen, :load])
    @test key2.legend isa Legend
    @test isempty(key2.colorbars)
end

@testitem "Explicit per-index colours are left out of the key" tags = [:integration] setup =
    [LegendTools] begin
    case = readcase("case5.m")
    nbus = length(case["bus"])
    f, ax, p = powerplot(case; components = Dict(:bus => (color = fill(:red, nbus),)))

    # A list of colours has no single swatch to stand for it.
    @test entry(legend_entries(p), :bus) === nothing
    @test p.node_style[].results[:bus].kind === :explicit
    # Everything else is still described.
    @test [e.component for e in legend_entries(p)] == [:gen, :load, :branch]
end

@testitem "A colorbar follows the plot it describes" tags = [:integration] setup =
    [LegendTools] begin
    f, ax, p =
        powerplot(readcase("case5.m"); components = Dict(:bus => (color = Field(:vm),)))
    cb = powercolorbar!(f[1, 2], p, :bus)

    before = cb.limits[]
    p.components = Dict(:bus => (color = Field(:vm), colorrange = (0.5, 2.0)))
    @test cb.limits[] == (0.5, 2.0)
    @test cb.limits[] != before
end

@testitem "A colorbar needs something to show" tags = [:integration] setup = [LegendTools] begin
    f, ax, p = powerplot(readcase("case5.m"))
    # Flat colours have no scale.
    @test_throws ArgumentError powercolorbar!(f[1, 2], p, :bus)
    # Neither does a component that is not there.
    @test_throws ArgumentError powercolorbar!(f[1, 2], p, :nonesuch)
end

@testitem "A bare Figure gets a new column" tags = [:integration] setup = [LegendTools] begin
    fig = Figure()
    ax = Axis(fig[1, 1])
    p = powerplot!(ax, readcase("case5.m"))
    key = powerlegend!(fig, p)

    @test key.legend isa Legend
    @test size(fig.layout) == (1, 2)
end

@testitem "A keyed plot renders to file" tags = [:integration] setup = [LegendTools] begin
    f, ax, p = powerplot(
        readcase("case5.m");
        components = Dict(
            :bus => (color = Field(:vm), colormap = :viridis),
            :branch => (color = Field(:transformer),),
        ),
    )
    powerlegend!(f[1, 2], p)

    mktempdir() do dir
        for ext in ("png", "svg")
            path = joinpath(dir, "keyed.$ext")
            save(path, f)
            @test isfile(path)
            @test filesize(path) > 0
        end
    end
end
