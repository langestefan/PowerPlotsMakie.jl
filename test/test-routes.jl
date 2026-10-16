@testsnippet RouteTools begin
    using PowerPlotsMakie
    using PowerPlotsMakie: _waypoints, _use_routes, _polyline_midpoint, graph_plot
    using PowerModels
    using CairoMakie
    using Graphs: src, dst, nv, ne
    using Makie: Point2f

    CairoMakie.activate!(type = "png")
    PowerModels.silence()

    readcase(name) = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", name),
    )

    """
    case5 drawn on a map: every bus at a coordinate, and branch "1" (bus 1 to bus 2) given a
    route that runs the wrong way round and dips below the chord on its way.
    """
    function routed_case5()
        case = readcase("case5.m")
        for (i, id) in enumerate(sort(collect(keys(case["bus"])); by = x -> parse(Int, x)))
            case["bus"][id]["xcoord_1"], case["bus"][id]["ycoord_1"] = (10.0 * i, 0.0)
        end
        br = case["branch"]["1"]
        @assert (br["f_bus"], br["t_bus"]) == (1, 2)
        # stored from bus 2 to bus 1, with ends a little off the bus coordinates
        br["coordinates"] = [[20.5, 0.5], [17.0, -4.0], [13.0, -4.0], [9.5, 0.5]]
        return case
    end

    branch_index(net, id) =
        only(j for (j, r) in enumerate(net.edges) if r.component === :branch && r.id == id)
end

@testitem "PowerModels routes come from a coordinates list" tags = [:unit, :fast] setup =
    [RouteTools] begin
    case = readcase("case5.m")
    @test edge_coordinates(case, :branch, "1") === nothing
    case["branch"]["1"]["coordinates"] = [[0, 0], [1.5, 2], [3, 0]]
    @test edge_coordinates(case, :branch, "1") == Point2f[(0, 0), (1.5, 2), (3, 0)]
    # A single point is not a route.
    case["branch"]["1"]["coordinates"] = [[0, 0]]
    @test edge_coordinates(case, :branch, "1") === nothing
    @test edge_coordinates(case, :branch, "nope") === nothing
end

@testitem "A route is turned to run from the from-node" tags = [:unit, :fast] setup =
    [RouteTools] begin
    p1, p2 = Point2f(0, 0), Point2f(10, 0)
    route = Point2f[(10, 1), (5, 3), (0, 1)]
    @test _waypoints(route, p1, p2) == Point2f[(0, 1), (5, 3), (10, 1)]
    @test _waypoints(reverse(route), p1, p2) == Point2f[(0, 1), (5, 3), (10, 1)]
    # Points on the nodes themselves and repeats are not passed on to GraphMakie.
    @test _waypoints(Point2f[(0, 0), (5, 3), (5, 3), (10, 0)], p1, p2) == Point2f[(5, 3)]
end

@testitem "Routes are drawn only on a map unless forced" tags = [:unit, :fast] setup =
    [RouteTools] begin
    case = routed_case5()
    @test _use_routes(:auto, powernetwork(case))
    @test !_use_routes(false, powernetwork(case))

    # One bus without a coordinate means the layout is computed, and a route has no place
    # on it.
    delete!(case["bus"]["3"], "xcoord_1")
    @test !_use_routes(:auto, powernetwork(case))
    @test _use_routes(true, powernetwork(case))
    @test_throws ArgumentError _use_routes(:yes, powernetwork(case))
end

@testitem "Only edges with a route get waypoints" tags = [:unit, :fast] setup = [RouteTools] begin
    net = powernetwork(routed_case5())
    routes = edge_routes(net)
    j = branch_index(net, "1")
    @test collect(keys(routes)) == [j]

    pos = [Point2f(i, 0) for i = 1:nv(net)]
    wps = route_waypoints(net, routes, pos)
    @test length(wps) == ne(net)
    @test all(isempty, wps[k] for k in eachindex(wps) if k != j)
    @test length(wps[j]) == 4
end

@testitem "The midpoint of a polyline is halfway along it" tags = [:unit, :fast] setup =
    [RouteTools] begin
    point, tangent = _polyline_midpoint(Point2f[(0, 0), (0, 1), (3, 1)])
    @test point ≈ Point2f(1, 1)
    @test tangent ≈ Point2f(3, 0)
end

@testitem "The recipe draws a branch along its route" tags = [:integration] setup =
    [RouteTools] begin
    case = routed_case5()
    net = powernetwork(case)
    j = branch_index(net, "1")
    f, ax, p = powerplot(case)

    path = graph_plot(p).edge_paths[][j]
    drawn = PowerPlotsMakie.GraphMakie.discretize(path)
    @test first(drawn) ≈ Point2f(10, 0)
    @test last(drawn) ≈ Point2f(20, 0)
    @test any(q -> q ≈ Point2f(13, -4), drawn)
    @test any(q -> q ≈ Point2f(17, -4), drawn)

    # The other branches keep their chords.
    k = branch_index(net, "2")
    @test isempty(p.edge_waypoints[][k])

    # Off a map, or switched off, nothing is routed.
    f, ax, p = powerplot(case; routes = false)
    @test all(isempty, p.edge_waypoints[])
end

@testitem "A dragged bus keeps its routed line attached" tags = [:integration] setup =
    [RouteTools] begin
    case = routed_case5()
    net = powernetwork(case)
    j = branch_index(net, "1")
    f, ax, p = powerplot(case)

    pos = copy(p.node_pos[])
    e = net.graph.edges[j]
    pos[src(e)] = Point2f(10, 30)
    p.layout = pos

    drawn = PowerPlotsMakie.GraphMakie.discretize(graph_plot(p).edge_paths[][j])
    @test first(drawn) ≈ Point2f(10, 30)
    @test any(q -> q ≈ Point2f(13, -4), drawn)
end

@testitem "A flow arrow sits halfway along the route" tags = [:integration] setup =
    [RouteTools] begin
    case = routed_case5()
    for (_, br) in case["branch"]
        br["pf"] = 1.0
    end
    net = powernetwork(case)
    j = branch_index(net, "1")
    f, ax, p = powerplot(case; flow = true)

    pos = p.node_pos[]
    e = net.graph.edges[j]
    expected, _ =
        _polyline_midpoint(vcat([pos[src(e)]], p.edge_waypoints[][j], [pos[dst(e)]]))
    k = findfirst(==(j), edge_indices(net, EdgeRole()))
    @test p.flow_pos[][k] ≈ expected
    # Symmetric route, so halfway is the bottom of the dip, well off the chord.
    @test expected ≈ Point2f(15, -4)
end
