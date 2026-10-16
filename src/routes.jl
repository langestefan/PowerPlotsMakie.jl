"""
    edge_routes(net; projection = identity) -> Dict{Int,Vector{Point2f}}

Routes carried by the data, keyed by edge index, every point passed through `projection`
as the bus coordinates are (see [`layout_positions`](@ref)).

Only edge components are consulted, through [`edge_coordinates`](@ref); connectors are
plumbing and have no route. A route of fewer than two points says nothing about the path
and is ignored.
"""
function edge_routes(net::PowerNetwork; projection = identity)
    out = Dict{Int,Vector{Point2f}}()
    for (j, ref) in enumerate(net.edges)
        net.edge_roles[j] isa EdgeRole || continue
        route = edge_coordinates(net.data, ref.component, ref.id)
        route === nothing && continue
        points = Point2f[_project(projection, p) for p in route]
        length(points) >= 2 && (out[j] = points)
    end
    return out
end

"""
    _use_routes(routes, net) -> Bool

Whether the `routes` attribute asks for the data's routes to be drawn.

`:auto` draws them only when every node has coordinates of its own. A route is a polyline
in the data's coordinate system, and a computed layout has no coordinate system it could be
drawn in: a Stress layout of a geographic network would scatter the buses while their lines
still ran across the map.
"""
function _use_routes(routes, net::PowerNetwork)
    routes isa Bool && return routes
    routes === :auto || throw(
        ArgumentError(
            "routes = $(repr(routes)) is not understood; expected :auto, true or false",
        ),
    )
    nodes = count(r -> r isa NodeRole, net.vertex_roles)
    return nodes > 0 && length(fixed_positions(net)) == nodes
end

"""
    route_waypoints(net, routes, positions) -> Vector{Vector{Point2f}}

The waypoints GraphMakie should draw each edge through, in edge order; empty for an edge
with no route, which is then drawn as usual.

Each route is turned to run from the edge's from-node to its to-node, whichever way the
data stored it, and the edge is drawn from the node, through every point of the route, to
the other node. The route is not trimmed or stretched to meet the nodes: a line in the data
seldom ends exactly on the coordinate a substation is drawn at, and the short hop between
the two is more honest than moving either. It also means a bus dragged away from its
coordinate stays connected, the end segments following it while the route stays put.
"""
function route_waypoints(net::PowerNetwork, routes::AbstractDict, positions::AbstractVector)
    out = [Point2f[] for _ = 1:ne(net)]
    for (j, route) in routes
        e = net.graph.edges[j]
        out[j] = _waypoints(route, Point2f(positions[src(e)]), Point2f(positions[dst(e)]))
    end
    return out
end

_distance(a, b) = hypot((b - a)...)

_waypoints(route::AbstractVector{Point2f}, p1::Point2f, p2::Point2f) =
    first(_route_path(route, p1, p2, nothing))

"""
    _route_path(route, p1, p2, values) -> (waypoints, segment_values)

The waypoints an edge from `p1` to `p2` is drawn through along `route`, and — when `values`
holds one value per segment of the route — the value of each segment of the drawn path
`[p1; waypoints; p2]`, which has one more segment than there are waypoints.

The hop from a node onto the route takes the value of the segment it joins, and a segment
lost to a dropped point takes its value with it.
"""
function _route_path(route::AbstractVector{Point2f}, p1::Point2f, p2::Point2f, values)
    a, b = first(route), last(route)
    flipped = _distance(a, p2) + _distance(b, p1) < _distance(a, p1) + _distance(b, p2)
    points = flipped ? reverse(route) : route
    vals = values === nothing ? nothing : (flipped ? reverse(values) : values)
    out = Point2f[]
    segs = Any[]
    for (i, p) in enumerate(points)
        # GraphMakie drops a first or last waypoint equal to the node by mutating the vector
        # it is given, and a repeated point leaves a rounded corner (`route_radius > 0`) no
        # direction to turn in, so neither is passed on.
        (p == p1 || p == p2) && continue
        (!isempty(out) && last(out) == p) && continue
        push!(out, p)
        # The segment arriving here: the route's segment into point `i`, or for the first
        # point the hop from the node, which takes the first segment's value.
        vals === nothing || push!(segs, vals[max(i - 1, 1)])
    end
    vals === nothing || push!(segs, last(vals))
    return out, segs
end

"""
    _polyline_midpoint(points) -> (point, tangent)

The point halfway along a polyline, by length, and the direction of travel there.

This is exact for routes drawn with straight segments (`route_radius = 0`), and within the
rounding of a corner otherwise.
"""
function _polyline_midpoint(points::AbstractVector{Point2f})
    lengths = [_distance(points[i], points[i+1]) for i = 1:(length(points)-1)]
    half = sum(lengths) / 2
    walked = 0.0
    for (i, len) in enumerate(lengths)
        if len > 0 && walked + len >= half
            t = (half - walked) / len
            step = points[i+1] - points[i]
            return points[i] + Float32(t) * step, step
        end
        walked += len
    end
    return last(points), last(points) - first(points)
end
