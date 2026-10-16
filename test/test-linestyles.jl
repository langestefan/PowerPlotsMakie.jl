@testsnippet LinestyleTools begin
    using PowerPlotsMakie
    using PowerPlotsMakie: _route_path, graph_plot, GraphMakie, ROUTE_LAYER_PLOTS
    using PowerModels
    using CairoMakie
    using Makie: Point2f, RGBAf

    CairoMakie.activate!(type = "png")
    PowerModels.silence()

    readcase(name) = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", name),
    )

    """
    case5 on a map with branch "1" (bus 1 to bus 2) routed, stored from bus 2 to bus 1, and
    going underground for its middle segment.
    """
    function cabled_case5()
        case = readcase("case5.m")
        for (i, id) in enumerate(sort(collect(keys(case["bus"])); by = x -> parse(Int, x)))
            case["bus"][id]["xcoord_1"], case["bus"][id]["ycoord_1"] = (10.0 * i, 0.0)
        end
        br = case["branch"]["1"]
        br["coordinates"] = [[20.5, 0.5], [17.0, -4.0], [13.0, -4.0], [9.5, 0.5]]
        br["route_kind"] = ["overhead", "cable", "overhead"]
        return case
    end

    branch_index(net, id) =
        only(j for (j, r) in enumerate(net.edges) if r.component === :branch && r.id == id)

    cable_style = Dict(
        :branch =>
            (linestyle = Field(:route_kind), linestyles = Dict("cable" => :dash)),
    )
end

@testitem "Line styles are looked up from a field" tags = [:unit, :fast] setup =
    [LinestyleTools] begin
    r = resolve_linestyles(Any[true, false, missing], :cable, nothing)
    @test r.styles == [:dash, :solid, :solid]
    @test r.result.values == [false, true]
    @test r.result.styles == [:solid, :dash]

    # A Dict names styles by value, numbers matched by value; anything else is solid.
    r = resolve_linestyles(Any[150.0, 380.0, 50.0], :kv, Dict(380 => :dot))
    @test r.styles == [:solid, :dot, :solid]
    @test r.result.values == [50.0, 150.0, 380.0]

    # A vector is handed out over the sorted values.
    r = resolve_linestyles(Any["b", "a", "c"], :x, [:dash, :dot])
    @test r.styles == [:dot, :dash, :dash]

    # One value per segment: kept per segment, the edge itself in its most common style.
    r = resolve_linestyles(
        Any[["cable", "overhead", "cable"], "overhead"],
        :route_kind,
        Dict("cable" => :dash),
    )
    @test r.segments[1] == [:dash, :solid, :dash]
    @test r.styles == [:dash, :solid]
    @test r.segments[2] === nothing

    @test_throws ArgumentError resolve_linestyles(Any[1], :x, :dash)
end

@testitem "Segment values follow the route onto the drawn path" tags = [:unit, :fast] setup =
    [LinestyleTools] begin
    p1, p2 = Point2f(0, 0), Point2f(10, 0)
    route = Point2f[(1, 1), (5, 3), (9, 1)]
    via, segs = _route_path(route, p1, p2, ["a", "b"])
    @test via == route
    # node → first point takes the first segment's value, last point → node the last's
    @test segs == ["a", "a", "b", "b"]

    # Stored the other way round: values turn with the points.
    via, segs = _route_path(reverse(route), p1, p2, ["b", "a"])
    @test via == route
    @test segs == ["a", "a", "b", "b"]

    # A point on the node is dropped, and the segment from it keeps its value.
    via, segs = _route_path(Point2f[(0, 0), (5, 3), (10, 0)], p1, p2, ["a", "b"])
    @test via == Point2f[(5, 3)]
    @test segs == ["a", "b"]
    @test length(segs) == length(via) + 1
end

@testitem "Routes are drawn stretch by stretch in their own style" tags = [:integration] setup =
    [LinestyleTools] begin
    case = cabled_case5()
    net = powernetwork(case)
    j = branch_index(net, "1")
    f, ax, p = powerplot(case; components = cable_style, edge_width = 2, autoscale = false)

    @test p.segment_edges[] == [k == j for k = 1:length(net.edges)]
    layers = p.route_layers[]
    @test Set(keys(layers)) == Set([:solid, :dash])
    nan(q) = isnan(q[1])
    # Overhead from bus 1 to the first bend, cable across the bottom, overhead into bus 2.
    @test filter(!nan, layers[:dash].points) == Point2f[(13, -4), (17, -4)]
    @test filter(!nan, layers[:solid].points) ==
          Point2f[(10, 0), (9.5, 0.5), (13, -4), (17, -4), (20.5, 0.5), (20, 0)]
    @test all(==(j), layers[:dash].edges)
    @test all(==(2.0f0), layers[:dash].widths)

    # GraphMakie leaves the edge to the layers, drawn in the style of the other branches.
    @test p.gp_graph_edge_width[][j] == 0
    @test p.gp_edge_width[][j] == 2
    @test all(==(:solid), p.gp_edge_linestyle[][edge_indices(net, EdgeRole())])

    # Hovering a layer finds the branch.
    plots = ROUTE_LAYER_PLOTS[p]
    @test component_at(p, plots[:dash], 1) == net.edges[j]
    @test plots[:dash].inspector_label[](plots[:dash], 1, nothing) ==
          hover_text(p, net.edges[j])
end

@testitem "Route layers follow colours, hiding and visibility" tags = [:integration] setup =
    [LinestyleTools] begin
    case = cabled_case5()
    net = powernetwork(case)
    j = branch_index(net, "1")
    f, ax, p = powerplot(case; components = cable_style, group = Field(:base_kv))
    @test all(==(p.gp_edge_color[][j]), p.route_layers[][:dash].colors)

    p.hidden_groups = [230]
    @test all(c -> c.alpha == 0, p.route_layers[][:dash].colors)
    @test component_at(p, ROUTE_LAYER_PLOTS[p][:dash], 1) === nothing

    p.visible = false
    @test all(q -> !q.visible[], values(ROUTE_LAYER_PLOTS[p]))

    # Changing the mapping restyles the layers: the cable is now dotted, and the dashed
    # layer left with nothing to draw.
    p.components = Dict(
        :branch => (linestyle = Field(:route_kind), linestyles = Dict("cable" => :dot)),
    )
    @test haskey(p.route_layers[], :dot) && !haskey(p.route_layers[], :dash)
    @test isempty(ROUTE_LAYER_PLOTS[p][:dash][1][])
end

@testitem "Without a route an edge is drawn whole in its most common style" tags =
    [:integration] setup = [LinestyleTools] begin
    case = cabled_case5()
    delete!(case["branch"]["1"], "coordinates")
    case["branch"]["2"]["route_kind"] = "cable"
    net = powernetwork(case)
    f, ax, p = powerplot(case; components = cable_style)
    @test !any(p.segment_edges[])
    @test isempty(p.route_layers[])
    styles = p.gp_edge_linestyle[]
    @test styles[branch_index(net, "1")] === :solid
    @test styles[branch_index(net, "2")] === :dash
end

@testitem "The legend explains the line styles" tags = [:integration] setup =
    [LinestyleTools] begin
    f = Figure()
    ax = Axis(f[1, 1])
    p = powerplot!(ax, cabled_case5(); components = cable_style, group = Field(:base_kv))
    leg = powerlegend!(
        f[1, 2],
        p;
        linestyle_title = "line",
        linestyle_labels = k -> k == "cable" ? "underground" : "overhead",
    )
    sections = leg.legend.entrygroups[]
    titles = [first(s) for s in sections]
    @test "line" in titles
    entries = last(sections[findfirst(==("line"), titles)])
    @test [e.label[] for e in entries] == ["underground", "overhead"]

    e = only(filter(e -> e.component === :branch, legend_entries(p)))
    @test e.linestyles.field === :route_kind
    @test e.linestyles.styles == [:dash, :solid]
end
