"""
    fixed_positions(net; projection = identity) -> Dict{Int,Point2f}

Coordinates already carried by the data, keyed by vertex index, each passed through
`projection`.

Networks with geographic or hand-authored positions expose them through
[`node_coordinates`](@ref). Only node components are consulted; injections are placed by
the layout around whatever bus they hang off.
"""
function fixed_positions(net::PowerNetwork; projection = identity)
    out = Dict{Int,Point2f}()
    for (i, ref) in enumerate(net.vertices)
        net.vertex_roles[i] isa NodeRole || continue
        p = node_coordinates(net.data, ref.component, ref.id)
        p === nothing || (out[i] = _project(projection, p))
    end
    return out
end

"""
    layout_positions(net; layout = :auto, pin = nothing, projection = identity)
        -> Vector{Point2f}

Position every vertex of `net`. Coordinates from the data are first passed through
`projection`, a function from point to point — [`web_mercator`](@ref) to draw longitude and
latitude over web map tiles — and the layout works around them where they now lie.

`layout` accepts:

  - `:auto` — use the data's coordinates when every vertex has them; otherwise pick an
    algorithm for this network: [`RadialTree`](@ref) when the buses and branches form a
    forest ([`isradial`](@ref)), `Stress` otherwise. Data-supplied coordinates for some
    vertices, or an explicit `pin`, force `Stress`, since it is the choice that can honour
    them;
  - `:radial` — a [`RadialTree`](@ref) rooted at the reference buses, whether or not the
    network is a forest;
  - `:stress` — stress majorization, honouring `pin`;
  - a NetworkLayout algorithm, e.g. `Stress()` or `Spring(; C = 3)`;
  - a vector of points, one per vertex, used as given;
  - any callable `graph -> positions`.

`pin` names vertices that must not move, as a collection of indices or a `Dict` of
`index => Bool`. Vertices whose coordinates come from the data are pinned automatically,
which is how PowerPlots.jl's `fixed = true` behaves — the difference being that here the
pinning is expressed through NetworkLayout's own `pin` support rather than a bespoke
layout, so it works with `Spring`, `Stress` and `SFDP` alike.

With `:auto` or `:stress` and every vertex with coordinates held, the vertices without —
generators and loads, typically — are placed around the bus they hang off, a quarter of a
typical line's length away whatever units the coordinates are in, and Stress lays out
whatever is left.
"""
function layout_positions(
    net::PowerNetwork;
    layout = :auto,
    pin = nothing,
    projection = identity,
)
    n = nv(net)

    if layout isa AbstractVector
        length(layout) == n || throw(
            ArgumentError(
                "layout has $(length(layout)) positions but the network has $n vertices",
            ),
        )
        return Point2f[Point2f(p) for p in layout]
    end

    fixed = fixed_positions(net; projection)
    # A map, fully placed by the data: there is nothing left for an algorithm to decide, and
    # running Stress with every vertex pinned would only cost time.
    if layout === :auto && pin === nothing && length(fixed) == n
        return Point2f[fixed[i] for i = 1:n]
    end
    pinned = _pin_dict(pin, fixed, n)
    if layout in (:auto, :stress) &&
       !isempty(fixed) &&
       all(i -> get(pinned, i, false), keys(fixed))
        # Stress measures in graph steps, the data in metres, degrees or anything else: laid
        # out among the data's coordinates, a generator lands a metre from its bus, or a
        # degree, or is pulled into the middle of the map. So what hangs off a bus with
        # coordinates is placed around it directly, at a fraction of a typical line.
        reach = _reach(net, fixed)
        placed = merge(_hung_off(net, fixed, reach), fixed)
        length(placed) == n && return Point2f[placed[i] for i = 1:n]

        # Stress for the rest, centred and scaled to graph steps: it solves for the free
        # vertices as if the layout were centred on the origin, and drops them there when
        # the pinned ones are a map's worth of metres away from it.
        origin = sum(Point2d, values(fixed)) / length(fixed)
        start = Dict{Int,Point2f}(i => Point2f((p .- origin) ./ reach) for (i, p) in placed)
        for i in keys(placed)
            pinned[i] = true
        end
        algorithm = _layout_algorithm(net, layout, start, pinned)
        out = Point2f[Point2f(origin .+ p .* reach) for p in algorithm(net.graph)]
        for (i, p) in placed
            out[i] = p
        end
        return out
    end
    algorithm = _layout_algorithm(net, layout, fixed, pinned)
    return Point2f[Point2f(p) for p in algorithm(net.graph)]
end

"""
How far a vertex without coordinates is laid out from the bus it hangs off, as a fraction
of a typical line between two buses that have them.
"""
const FREE_VERTEX_REACH = 0.25

"""
    _reach(net, fixed) -> Float64

How far, in data units, a vertex without coordinates is placed from the bus it hangs off:
`FREE_VERTEX_REACH` times the median length of the edges between two vertices with
coordinates, ignoring edges whose ends coincide — the voltage levels of one substation,
say. Falls back on the spacing between the vertices, and on `1` when there is nothing to
measure.
"""
function _reach(net::PowerNetwork, fixed::Dict{Int,Point2f})
    lengths = Float64[]
    for e in edges(net.graph)
        a, b = get(fixed, src(e), nothing), get(fixed, dst(e), nothing)
        (a === nothing || b === nothing) && continue
        d = hypot(Float64(b[1] - a[1]), Float64(b[2] - a[2]))
        d > 0 && push!(lengths, d)
    end
    typical =
        isempty(lengths) ? nearest_neighbor_spacing(collect(values(fixed))) :
        _median(lengths)
    return typical > 0 ? FREE_VERTEX_REACH * typical : 1.0
end

"""
    _hung_off(net, fixed, reach) -> Dict{Int,Point2f}

Positions for the vertices without coordinates that hang off one with them: `reach` away
from it, those of one bus fanned evenly around it starting straight up.
"""
function _hung_off(net::PowerNetwork, fixed::Dict{Int,Point2f}, reach::Float64)
    around = Dict{Int,Vector{Int}}()
    for i = 1:nv(net)
        haskey(fixed, i) && continue
        k = findfirst(v -> haskey(fixed, v), Graphs.neighbors(net.graph, i))
        k === nothing ||
            push!(get!(Vector{Int}, around, Graphs.neighbors(net.graph, i)[k]), i)
    end
    out = Dict{Int,Point2f}()
    for (bus, hung) in around, (k, i) in enumerate(sort!(hung))
        θ = π / 2 + 2π * (k - 1) / length(hung)
        out[i] = Point2f(fixed[bus] .+ reach .* (cos(θ), sin(θ)))
    end
    return out
end

"Normalise the many spellings of `pin` into what NetworkLayout wants."
function _pin_dict(pin, fixed::Dict{Int,Point2f}, n::Int)
    out = Dict{Int,Bool}()
    # Data-supplied coordinates are pinned by default; an explicit `pin` can add to them.
    for i in keys(fixed)
        out[i] = true
    end
    pin === nothing && return out
    if pin isa AbstractDict
        for (k, v) in pin
            v === false ? delete!(out, k) : (out[k] = true)
        end
    else
        for i in pin
            1 <= i <= n || throw(ArgumentError("pinned vertex $i is out of range"))
            out[i] = true
        end
    end
    return out
end

function _layout_algorithm(net, layout, fixed, pinned)
    if layout === :auto
        # Coordinates from the data, or vertices the caller wants held, are a layout that
        # already exists in part; only the iterative algorithms can build around one.
        free = isempty(fixed) && isempty(pinned)
        layout = free && isradial(net) ? :radial : :stress
    end

    if layout === :radial
        return radial_tree(net)
    elseif layout === :stress
        return isempty(fixed) && isempty(pinned) ? NetworkLayout.Stress() :
               NetworkLayout.Stress(; initialpos = fixed, pin = pinned)
    elseif layout isa NetworkLayout.AbstractLayout
        # An explicitly constructed algorithm is taken at its word: the caller has already
        # said what it wants, including any initialpos/pin of its own.
        return layout
    elseif layout isa Symbol
        throw(
            ArgumentError(
                "unknown layout $(repr(layout)); expected :auto, :radial, :stress or an algorithm",
            ),
        )
    end
    return layout
end
