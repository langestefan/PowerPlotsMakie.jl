@testsnippet GroupTools begin
    using PowerPlotsMakie
    using PowerPlotsMakie: graph_plot, GraphMakie, hover_text, boundary_indices
    using PowerModels
    using CairoMakie
    using Graphs: src, dst, nv, ne
    using Makie: Point2f, RGBAf

    CairoMakie.activate!(type = "png")
    PowerModels.silence()

    readcase(name) = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", name),
    )

    "case24: a 138 kV and a 230 kV network joined by transformers."
    case24() = readcase("case24.m")

    branch_ends_kv(case, br) = (
        case["bus"][string(br["f_bus"])]["base_kv"],
        case["bus"][string(br["t_bus"])]["base_kv"],
    )
end

@testitem "Groups follow the buses they hang off" tags = [:unit, :fast] setup = [GroupTools] begin
    case = case24()
    net = powernetwork(case)
    g = network_groups(net, Field(:base_kv))

    @test g.values == [138.0, 230.0]
    for (i, r) in enumerate(net.vertices)
        r.component === :bus && @test g.vertex[i] == case["bus"][r.id]["base_kv"]
    end
    for (j, r) in enumerate(net.edges)
        r.component === :branch || continue
        a, b = branch_ends_kv(case, case["branch"][r.id])
        # A line takes its level; a transformer between two levels belongs to neither.
        @test isequal(g.edge[j], a == b ? a : missing)
    end
    # Injections and their connectors take their bus's level.
    for (j, r) in enumerate(net.edges)
        net.edge_roles[j] isa InjectionRole || continue
        e = net.graph.edges[j]
        @test g.vertex[dst(e)] == g.vertex[src(e)] == g.edge[j]
    end

    @test network_groups(net, nothing).field === nothing
    @test_throws ArgumentError network_groups(net, :base_kv)
end

@testitem "Group colours come from the palette" tags = [:unit, :fast] setup = [GroupTools] begin
    net = powernetwork(case24())
    # A Dict is matched by value, whatever the number type: 230 finds 230.0.
    g = network_groups(net, Field(:base_kv); palette = Dict(230 => :red))
    @test g.colors[230.0] == RGBAf(1, 0, 0, 1)
    @test g.colors[138.0] != g.colors[230.0]
    g = network_groups(net, Field(:base_kv); palette = [:black, :white])
    @test g.colors[138.0] == RGBAf(0, 0, 0, 1)
    @test g.colors[230.0] == RGBAf(1, 1, 1, 1)
    @test group_label(150.0) == "150"
    @test group_label(1.5) == "1.5"
    @test group_label("north") == "north"
end

@testitem "Hiding a group hides its edges and the transformers into it" tags =
    [:unit, :fast] setup = [GroupTools] begin
    case = case24()
    net = powernetwork(case)
    g = network_groups(net, Field(:base_kv))
    vh, eh = hidden_masks(g, [230])

    @test vh == [isequal(v, 230.0) for v in g.vertex]
    for (j, r) in enumerate(net.edges)
        r.component === :branch || continue
        # Hidden whenever either end is at 230 kV, transformers included.
        @test eh[j] == (230.0 in branch_ends_kv(case, case["branch"][r.id]))
    end
    @test !any(first(hidden_masks(g, Any[])))
end

@testitem "A grouped plot colours by group, except where told otherwise" tags =
    [:integration] setup = [GroupTools] begin
    case = case24()
    net = powernetwork(case)
    f, ax, p = powerplot(case; group = Field(:base_kv), group_palette = Dict(138 => :red))
    g = p.groups[]
    for i in vertex_indices(net, :bus)
        @test p.gp_node_color[][i] == g.colors[g.vertex[i]]
    end
    @test p.node_style[].results[:bus].kind === :group

    # An explicit colour beats the group's.
    f, ax, p = powerplot(
        case;
        group = Field(:base_kv),
        components = Dict(:bus => (color = :black,)),
    )
    @test all(==(RGBAf(0, 0, 0, 1)), p.gp_node_color[][vertex_indices(net, :bus)])
end

@testitem "Hidden groups are drawn transparent, with no flow arrows" tags = [:integration] setup =
    [GroupTools] begin
    case = case24()
    for (_, br) in case["branch"]
        br["pf"] = 1.0
    end
    net = powernetwork(case)
    f, ax, p = powerplot(case; group = Field(:base_kv), flow = true)
    narrows = length(p.flow_pos[])

    p.hidden_groups = [230]
    vh, eh = p.vertex_hidden[], p.edge_hidden[]
    @test any(vh) && any(eh)
    @test all(c -> c.alpha == 0, p.gp_node_color[][vh])
    @test all(c -> c.alpha > 0, p.gp_node_color[][.!vh])
    @test all(c -> c.alpha == 0, p.gp_edge_color[][eh])
    @test length(p.flow_pos[]) == narrows - count(eh[edge_indices(net, EdgeRole())])
    # The ring goes too, on the scatter GraphMakie actually draws.
    rings = GraphMakie.get_node_plot(graph_plot(p)).strokecolor[]
    @test all(c -> c.alpha == 0, rings[vh])
    @test all(c -> c.alpha > 0, rings[.!vh])

    p.hidden_groups = Any[]
    @test all(c -> c.alpha > 0, p.gp_node_color[])
end

@testitem "The node stroke colour reaches the drawn scatter" tags = [:integration] setup =
    [GroupTools] begin
    # GraphMakie has no `node_strokecolor` of its own and drops one passed to it.
    f, ax, p = powerplot(case24(); node_strokecolor = :red, node_strokewidth = 1)
    @test all(==(RGBAf(1, 0, 0, 1)), GraphMakie.get_node_plot(graph_plot(p)).strokecolor[])
    p.node_strokecolor = :blue
    @test all(==(RGBAf(0, 0, 1, 1)), GraphMakie.get_node_plot(graph_plot(p)).strokecolor[])
end

@testitem "The legend's group entries and hidden_groups stay in step" tags = [:integration] setup =
    [GroupTools] begin
    f = Figure()
    ax = Axis(f[1, 1])
    p = powerplot!(ax, case24(); group = Field(:base_kv))
    leg =
        powerlegend!(f[1, 2], p; group_labels = (v, n) -> "$(group_label(v)) kV $(n.nodes)")

    section = first(leg.legend.entrygroups[])
    @test first(section) == "base_kv"
    entries = last(section)
    @test [e.label[] for e in entries] == ["138 kV 10", "230 kV 14"]

    # Clicking an entry is Makie toggling the plots it links.
    Makie.toggle_visibility!(entries[2])
    @test p.hidden_groups[] == [230.0]
    Makie.toggle_visibility!(entries[2])
    @test isempty(p.hidden_groups[])

    # And the other way round: hiding from code dims the entry.
    p.hidden_groups = [138]
    visible = Bool[]
    Makie.foreach_plot(q -> push!(visible, q.visible[]), entries[1])
    @test visible == [false]
end

@testitem "Boundary buses get their own marker and legend entry" tags = [:integration] setup =
    [GroupTools] begin
    case = case24()
    @test boundary_nodes(case) == String[]
    case["bus"]["3"]["boundary"] = true
    @test boundary_nodes(case) == ["3"]

    net = powernetwork(case)
    i = only(boundary_indices(net))
    @test net.vertices[i] == ComponentRef(:bus, "3")

    f, ax, p = powerplot(case; group = Field(:base_kv), autoscale = false, node_size = 10)
    style = p.node_style[]
    @test style.markers[i] === :diamond
    @test style.colors[i] == RGBAf(0, 0, 0, 1)
    @test p.gp_node_size[][i] ≈ 12.0
    @test :boundary in [e.component for e in legend_entries(p)]

    f, ax, p = powerplot(case; boundary = false)
    @test p.node_style[].markers[i] === :circle
    @test !(:boundary in [e.component for e in legend_entries(p)])
end

@testitem "Picks translate back to components" tags = [:integration] setup = [GroupTools] begin
    case = case24()
    net = powernetwork(case)
    f, ax, p = powerplot(case; group = Field(:base_kv), hover_fields = [:base_kv, :nope])
    gp = graph_plot(p)
    nodes = GraphMakie.get_node_plot(gp)
    edgeplot = GraphMakie.get_edge_plot(gp)

    @test component_at(p, nodes, 1) == net.vertices[1]
    @test component_at(p, (nodes, 1)) == net.vertices[1]
    @test component_at(p, nodes, 0) === nothing
    @test component_at(p, ax.scene, 1) === nothing
    # case24 mixes solid branches and dashed connectors, so GraphMakie draws one lines per
    # edge and the plot itself names the edge.
    @test component_at(p, edgeplot.plots[3], 1) == net.edges[3]

    @test hover_text(p, net.vertices[1]) == "bus[\"1\"]\nbase_kv = 138.0"
    @test nodes.inspector_label[](nodes, 1, nothing) == hover_text(p, net.vertices[1])

    # Hidden components are not there to be picked.
    p.hidden_groups = [138]
    @test component_at(p, nodes, 1) === nothing
end

@testitem "Hiding the plot hides everything in it" tags = [:integration] setup =
    [GroupTools] begin
    f, ax, p = powerplot(case24())
    leaves = Any[]
    collect_leaves(q) =
        isempty(q.plots) ? push!(leaves, q) : foreach(collect_leaves, q.plots)
    collect_leaves(p)
    @test !isempty(leaves)
    # Some parts start out hidden — GraphMakie's arrow heads on an undirected graph — and
    # must stay that way when the plot is shown again.
    before = [q.visible[] for q in leaves]
    @test any(before)
    p.visible = false
    @test all(q -> !q.visible[], leaves)
    p.visible = true
    @test [q.visible[] for q in leaves] == before
end

@testitem "A fully placed network keeps its coordinates" tags = [:integration] setup =
    [GroupTools] begin
    case = readcase("case5.m")
    for k in ("gen", "load", "shunt", "storage")
        delete!(case, k)
    end
    for (id, bus) in case["bus"]
        bus["xcoord_1"], bus["ycoord_1"] = parse(Float64, id), 2 * parse(Float64, id)
    end
    net = powernetwork(case)
    pos = layout_positions(net)
    @test pos ==
          [Point2f(parse(Float64, r.id), 2 * parse(Float64, r.id)) for r in net.vertices]
end

@testitem "autoscale_min is the floor on the node diameter" tags = [:unit, :fast] setup =
    [GroupTools] begin
    # A thousand nodes in a 10×10 viewport: the measured diameter is far below any floor.
    pos = [Point2f(rand(), rand()) for _ = 1:1000]
    @test autoscale_factor(pos, (10, 10)) * PowerPlotsMakie.REFERENCE_NODE_SIZE ≈
          PowerPlotsMakie.MIN_NODE_PIXELS
    @test autoscale_factor(pos, (1000, 1000); min_pixels = 8) *
          PowerPlotsMakie.REFERENCE_NODE_SIZE >= 8 - 1e-9
end
