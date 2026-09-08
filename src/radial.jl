"""
    node_subgraph(net) -> (graph, vertices, extra)

The bus-only subgraph of `net`, as a `Graphs.SimpleGraph`.

Only node vertices and the edge components between them are kept: injections hang off a
single bus and can never create a cycle, so including them would make every network look
meshed by exactly the number of injections it has. `vertices[i]` is the network vertex
that local vertex `i` came from, and `extra` counts the edges that could not be added
because they duplicate another edge or are self-loops — that is, the parallel circuits and
loops that make a network non-radial even though the collapsed graph looks like a tree.
"""
function node_subgraph(net::PowerNetwork)
    local_of = zeros(Int, nv(net))
    verts = Int[]
    for i = 1:nv(net)
        net.vertex_roles[i] isa NodeRole || continue
        push!(verts, i)
        local_of[i] = length(verts)
    end

    g = Graphs.SimpleGraph(length(verts))
    extra = 0
    for (j, e) in enumerate(edges(net.graph))
        net.edge_roles[j] isa EdgeRole || continue
        s, d = local_of[src(e)], local_of[dst(e)]
        (s == 0 || d == 0) && continue
        if s == d || !Graphs.add_edge!(g, s, d)
            extra += 1
        end
    end
    return g, verts, extra
end

"""
    isradial(net) -> Bool

Whether the buses and the branches between them form a forest.

This is the test behind `layout = :auto`: a radial feeder is drawn far more legibly by a
tree layout than by a force-directed one. Parallel circuits and self-loops count against
radiality even though collapsing them would leave a tree, because two circuits between the
same pair of buses are a loop in the network whatever the drawing does with them.

Islands are fine — a forest of several feeders is still radial, and each one is laid out
and packed separately.
"""
function isradial(net::PowerNetwork)
    g, _, extra = node_subgraph(net)
    extra == 0 || return false
    nv(g) == 0 && return false
    return ne(g) == nv(g) - length(Graphs.connected_components(g))
end

"""
    RadialTree(; roots, satellites, satellite_distance, component_gap)

A tree layout for radial networks, wrapping NetworkLayout's `Buchheim`.

`Buchheim` itself is strict: it demands a rooted tree given as a parent → child adjacency
list with the root at vertex 1 and every node reachable, and it throws on anything else —
including an ordinary undirected tree, whose symmetric adjacency makes every node look like
the child of two parents. This wrapper does the work of meeting that contract: it splits
the graph into connected components, roots each one, renumbers it, and maps the resulting
coordinates back onto the original vertex numbering.

  - `roots` names preferred root vertices by index. The first one found in a component
    roots it; a component containing none is rooted at its highest-degree vertex. For a
    power network the roots are the reference buses, which is what [`radial_tree`](@ref)
    fills in.
  - `satellites` names vertices to place *around* their neighbour rather than as tree
    children — injections, which would otherwise be drawn as another level of feeder and
    make a two-level network look four levels deep. Each is fanned into the widest angular
    gap between its bus's tree neighbours, so it never sits on top of a branch.
  - `satellite_distance` is how far from the bus they sit, in Buchheim's units, where
    sibling nodes are two apart.
  - `component_gap` is the horizontal space left between islands.

Edges that are not part of the rooted tree — present only if this is forced onto a meshed
network — are simply drawn as chords between the vertices the tree placed.
"""
struct RadialTree
    roots::Vector{Int}
    satellites::Vector{Int}
    satellite_distance::Float64
    component_gap::Float64
end

function RadialTree(;
    roots = Int[],
    satellites = Int[],
    satellite_distance = 0.7,
    component_gap = 2.0,
)
    return RadialTree(
        collect(Int, roots),
        collect(Int, satellites),
        Float64(satellite_distance),
        Float64(component_gap),
    )
end

"""
    radial_tree(net; kwargs...) -> RadialTree

The [`RadialTree`](@ref) for `net`: rooted at the reference buses the backend reports, with
every injection treated as a satellite of its bus. `kwargs` are passed on to the
constructor.
"""
function radial_tree(net::PowerNetwork; kwargs...)
    wanted = Set(string(id) for id in reference_nodes(net.data))
    roots = Int[]
    if !isempty(wanted)
        for (i, ref) in enumerate(net.vertices)
            net.vertex_roles[i] isa NodeRole || continue
            ref.id in wanted && push!(roots, i)
        end
    end
    return RadialTree(;
        roots = roots,
        satellites = vertex_indices(net, InjectionRole()),
        kwargs...,
    )
end

function (alg::RadialTree)(g)
    n = Int(nv(g))
    positions = fill(Point2f(0, 0), n)
    n == 0 && return positions

    satellites = Set(v for v in alg.satellites if 1 <= v <= n)
    treevs = [v for v = 1:n if !(v in satellites)]

    if !isempty(treevs)
        _place_tree!(positions, g, treevs, alg)
    end
    _place_satellites!(positions, g, satellites, alg)
    return positions
end

"Lay the non-satellite vertices out as a forest, packing the components left to right."
function _place_tree!(positions, g, treevs, alg::RadialTree)
    local_of = Dict(v => i for (i, v) in enumerate(treevs))
    sub = Graphs.SimpleGraph(length(treevs))
    for v in treevs, w in Graphs.outneighbors(g, v)
        j = get(local_of, w, 0)
        (j == 0 || w <= v) && continue
        Graphs.add_edge!(sub, local_of[v], j)
    end

    preferred = Set{Int}(get(local_of, v, 0) for v in alg.roots)
    cursor = 0.0
    for comp in Graphs.connected_components(sub)
        pos = _buchheim_component(sub, comp, preferred)
        xs = [p[1] for p in pos]
        ys = [p[2] for p in pos]
        # Roots share a baseline at y = 0, so islands read as siblings rather than as one
        # deep feeder next to a shallow one.
        dx = cursor - minimum(xs)
        dy = -maximum(ys)
        for (k, v) in enumerate(comp)
            positions[treevs[v]] = Point2f(pos[k][1] + dx, pos[k][2] + dy)
        end
        cursor += (maximum(xs) - minimum(xs)) + alg.component_gap
    end
    return positions
end

"""
Buchheim coordinates for one connected component of `sub`, in the order of `comp`.

The BFS both chooses the parent of every vertex — which is what turns an undirected tree
into the rooted tree Buchheim insists on — and produces the visiting order used to
renumber the component so that its root lands on vertex 1.
"""
function _buchheim_component(sub, comp::Vector{Int}, preferred::Set{Int})
    length(comp) == 1 && return [Point2f(0, 0)]

    root = 0
    for v in comp
        if v in preferred
            root = v
            break
        end
    end
    if root == 0
        # No reference bus here: the best-connected vertex is the least arbitrary root.
        root = comp[argmax([Graphs.degree(sub, v) for v in comp])]
    end

    order = [root]
    children = Dict{Int,Vector{Int}}()
    seen = Set(order)
    head = 1
    while head <= length(order)
        v = order[head]
        head += 1
        kids = Int[]
        for w in Graphs.neighbors(sub, v)
            w in seen && continue
            push!(seen, w)
            push!(kids, w)
            push!(order, w)
        end
        children[v] = kids
    end

    newid = Dict(v => i for (i, v) in enumerate(order))
    adj = [Int[newid[c] for c in children[v]] for v in order]
    pos = NetworkLayout.Buchheim()(adj)

    return [Point2f(pos[newid[v]]) for v in comp]
end

"Fan each satellite into the widest angular gap around the vertex it hangs off."
function _place_satellites!(positions, g, satellites::Set{Int}, alg::RadialTree)
    isempty(satellites) && return positions

    grouped = Dict{Int,Vector{Int}}()
    orphans = Int[]
    for s in sort!(collect(satellites))
        host = 0
        for w in Graphs.outneighbors(g, s)
            if !(w in satellites)
                host = w
                break
            end
        end
        host == 0 ? push!(orphans, s) : push!(get!(grouped, host, Int[]), s)
    end

    for (host, sats) in sort!(collect(grouped); by = first)
        base = positions[host]
        angles = Float64[]
        for w in Graphs.outneighbors(g, host)
            w in satellites && continue
            d = positions[w] - base
            (d[1] == 0 && d[2] == 0) && continue
            push!(angles, atan(d[2], d[1]))
        end
        start, width = _widest_gap(angles)
        for (j, s) in enumerate(sats)
            θ = start + width * j / (length(sats) + 1)
            positions[s] =
                base +
                Point2f(alg.satellite_distance * cos(θ), alg.satellite_distance * sin(θ))
        end
    end

    # A satellite with no host has nothing to orbit; line the orphans up out of the way.
    for (j, s) in enumerate(orphans)
        positions[s] = Point2f(j * alg.satellite_distance, alg.component_gap)
    end
    return positions
end

"""
    _widest_gap(angles) -> (start, width)

The widest angular gap between the directions in `angles`, as the angle it starts at and
how wide it is. With no directions at all the whole circle is free.
"""
function _widest_gap(angles::Vector{Float64})
    isempty(angles) && return (0.0, 2π)
    a = sort(angles)
    n = length(a)
    best_start, best_width = a[n], a[1] + 2π - a[n]
    for i = 1:(n-1)
        w = a[i+1] - a[i]
        if w > best_width
            best_start, best_width = a[i], w
        end
    end
    return (best_start, best_width)
end
