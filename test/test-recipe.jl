@testsnippet RecipeTools begin
    using PowerPlotsMakie
    using PowerModels
    using CairoMakie
    using Colors: Colorant
    using Makie: RGBAf
    using Graphs

    CairoMakie.activate!(type = "png")
    PowerModels.silence()

    casepath(name) =
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", name)
    readcase(name) = PowerModels.parse_file(casepath(name))
    hexcolor(s) = RGBAf(parse(Colorant, s))

    "The GraphMakie plot nested inside a powerplot."
    graphplot_of(p) = only(filter(x -> x isa GraphMakie.GraphPlot, p.plots))
end

@testitem "A default plot reproduces the PowerPlots palette" tags = [:integration] setup = [
    RecipeTools,
] begin
    f, ax, p = powerplot(readcase("case5.m"))
    net = powernetwork(readcase("case5.m"))
    colors = p.gp_node_color[]

    @test length(colors) == nv(net)
    @test all(==(hexcolor("#3182BD")), colors[vertex_indices(net, :bus)])
    @test all(==(hexcolor("#E6550D")), colors[vertex_indices(net, :gen)])
    @test all(==(hexcolor("#CB181D")), colors[vertex_indices(net, :load)])

    ecolors = p.gp_edge_color[]
    @test all(==(hexcolor("#31A354")), ecolors[edge_indices(net, :branch)])
end

@testitem "Connectors are grey and dashed" tags = [:integration] setup = [RecipeTools] begin
    using PowerPlotsMakie: CONNECTOR_COLOR
    f, ax, p = powerplot(readcase("case5.m"))
    net = powernetwork(readcase("case5.m"))

    conn = edge_indices(net, InjectionRole())
    @test all(==(CONNECTOR_COLOR), p.gp_edge_color[][conn])

    styles = p.gp_edge_linestyle[]
    @test styles isa AbstractVector          # branches and connectors differ, so no collapse
    @test all(==(:dash), styles[conn])
    @test all(==(:solid), styles[edge_indices(net, :branch)])
end

@testitem "Parallel circuits are fanned apart" tags = [:integration] setup = [RecipeTools] begin
    using PowerPlotsMakie: multiplicity
    f, ax, p = powerplot(readcase("case5.m"))
    net = powernetwork(readcase("case5.m"))

    cd = p.curve_distances[]
    el = collect(edges(net.graph))
    # How many circuits share each pair of endpoints.
    groupsize = Dict{Tuple{Int,Int},Int}()
    for e in el
        key = minmax(src(e), dst(e))
        groupsize[key] = get(groupsize, key, 0) + 1
    end

    parallel = findall(e -> groupsize[minmax(src(e), dst(e))] > 1, el)
    solo = findall(e -> groupsize[minmax(src(e), dst(e))] == 1, el)

    @test !isempty(parallel)
    # Every circuit of a parallel group is displaced off the straight chord...
    @test all(!iszero, cd[parallel])
    # ...and every lone circuit stays straight.
    @test all(iszero, cd[solo])
end

@testitem "Positions come out one per vertex" tags = [:integration] setup = [RecipeTools] begin
    case = readcase("case5.m")
    f, ax, p = powerplot(case)
    pos = p.node_pos[]
    @test length(pos) == nv(powernetwork(case))
    @test all(pt -> all(isfinite, pt), pos)
end

@testitem "An explicit layout vector is used verbatim" tags = [:integration] setup = [
    RecipeTools,
] begin
    using Makie: Point2f
    case = readcase("case5.m")
    net = powernetwork(case)
    wanted = [Point2f(i, 2i) for i in 1:nv(net)]
    f, ax, p = powerplot(case; layout = wanted)
    @test p.node_pos[] == wanted
end

@testitem "Data coordinates are honoured and pinned" tags = [:integration] setup = [
    RecipeTools,
] begin
    using Makie: Point2f
    case = readcase("case5.m")
    for (id, xy) in ("1" => (0.0, 0.0), "2" => (1.0, 0.0), "3" => (1.0, 1.0))
        case["bus"][id]["xcoord_1"], case["bus"][id]["ycoord_1"] = xy
    end
    f, ax, p = powerplot(case)
    net = powernetwork(case)
    idx = Dict(r.id => i for (i, r) in enumerate(net.vertices) if r.component === :bus)
    pos = p.node_pos[]
    # Pinned buses must land exactly where the data put them.
    @test pos[idx["1"]] ≈ Point2f(0, 0)
    @test pos[idx["2"]] ≈ Point2f(1, 0)
    @test pos[idx["3"]] ≈ Point2f(1, 1)
end

@testitem "Per-component overrides beat role defaults" tags = [:integration] setup = [
    RecipeTools,
] begin
    case = readcase("case5.m")
    net = powernetwork(case)
    f, ax, p = powerplot(
        case;
        node_color = :black,
        components = Dict(:gen => (color = :red, size = 30.0)),
    )
    colors = p.gp_node_color[]
    @test all(==(RGBAf(1, 0, 0, 1)), colors[vertex_indices(net, :gen)])
    @test all(==(RGBAf(0, 0, 0, 1)), colors[vertex_indices(net, :bus)])
    @test all(==(30.0), p.gp_node_size[][vertex_indices(net, :gen)])
end

@testitem "Colouring by a field varies the colours" tags = [:integration] setup = [
    RecipeTools,
] begin
    case = readcase("case14.m")
    net = powernetwork(case)
    f, ax, p = powerplot(case; components = Dict(:bus => (color = Field(:vm),)))
    buscolors = p.gp_node_color[][vertex_indices(net, :bus)]
    @test length(unique(buscolors)) > 1
end

@testitem "Uniform attributes collapse to scalars" tags = [:integration] setup = [
    RecipeTools,
] begin
    # Every edge solid: GraphMakie should not be pushed onto its per-edge `lines` fallback.
    case = readcase("case5.m")
    f, ax, p = powerplot(case; connector_linestyle = :solid)
    @test p.gp_edge_linestyle[] === :solid
    @test p.gp_node_marker[] === :circle
end

@testitem "The plot nests exactly one GraphPlot" tags = [:integration] setup = [RecipeTools] begin
    import GraphMakie
    f, ax, p = powerplot(readcase("case5.m"))
    gp = graphplot_of(p)
    @test gp isa GraphMakie.GraphPlot
    @test length(gp[:edge_paths][]) == ne(powernetwork(readcase("case5.m")))
end

@testitem "Plots render to file" tags = [:integration] setup = [RecipeTools] begin
    f, ax, p = powerplot(readcase("case5.m"))
    mktempdir() do dir
        for ext in ("png", "svg", "pdf")
            path = joinpath(dir, "case5.$ext")
            save(path, f)
            @test isfile(path)
            @test filesize(path) > 0
        end
    end
end

@testitem "A PowerNetwork can be plotted directly" tags = [:integration] setup = [
    RecipeTools,
] begin
    net = powernetwork(readcase("case5.m"))
    f, ax, p = powerplot(net)
    @test length(p.node_pos[]) == nv(net)
end
