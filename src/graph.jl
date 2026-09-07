"""
    PowerEdge <: Graphs.AbstractEdge{Int}

An edge of a [`PowerGraph`](@ref).

Unlike `Graphs.SimpleEdge`, several `PowerEdge`s may connect the same pair of vertices:
power networks routinely carry parallel circuits (of the MATPOWER cases, `case5` has one
extra circuit and `case24` has four). `mult` distinguishes them, numbering the circuits
between a given pair of buses from `1` upwards in insertion order. It is what the plotting
code uses to fan parallel circuits apart, since GraphMakie's `curve_distance_usage =
automatic` only bows *antiparallel* edges of a directed graph and would leave parallel
circuits drawn exactly on top of each other.
"""
struct PowerEdge <: Graphs.AbstractEdge{Int}
    src::Int
    dst::Int
    mult::Int
end

Graphs.src(e::PowerEdge) = e.src
Graphs.dst(e::PowerEdge) = e.dst

"Circuit number of `e` among the edges sharing its endpoints, counting from 1."
multiplicity(e::PowerEdge) = e.mult

Base.reverse(e::PowerEdge) = PowerEdge(e.dst, e.src, e.mult)
Base.:(==)(a::PowerEdge, b::PowerEdge) =
    a.mult == b.mult &&
    ((a.src == b.src && a.dst == b.dst) || (a.src == b.dst && a.dst == b.src))
Base.hash(e::PowerEdge, h::UInt) =
    hash(PowerEdge, hash(minmax(e.src, e.dst), hash(e.mult, h)))
Base.show(io::IO, e::PowerEdge) = print(io, "PowerEdge $(e.src) => $(e.dst) (#$(e.mult))")

"""
    PowerGraph <: Graphs.AbstractGraph{Int}

An undirected graph that admits parallel edges, used as the topological backbone of a
network plot.

`Graphs.SimpleGraph` silently collapses parallel edges, which would merge two circuits
between the same buses into a single drawn line and cost them their independent colouring.
`PowerGraph` keeps one edge per electrical component instead, so `edges(g)` yields exactly
one entry per branch/transformer/switch/connector and GraphMakie's per-edge attribute
vectors line up one-to-one with the network's edge components.

The adjacency list is *deduplicated*: parallel edges appear once in `fadj`. Multiplicity
lives only in `edges`. That keeps `adjacency_matrix`, `degree`, `dijkstra_shortest_paths`
and friends behaving as they would on the underlying simple graph — which is what the
layout algorithms want — while `ne(g)` still counts every circuit, which is what the
renderer wants. Do not "fix" this by pushing duplicates into `fadj`: it makes
`adjacency_matrix` emit duplicate structural entries and double-counts `degree`.
"""
struct PowerGraph <: Graphs.AbstractGraph{Int}
    nv::Int
    edges::Vector{PowerEdge}
    fadj::Vector{Vector{Int}}
end

"""
    PowerGraph(nv, pairs)

Build a `PowerGraph` on `nv` vertices from an iterable of `(src, dst)` vertex pairs. The
order of `pairs` is preserved by `edges`, so callers can keep a parallel vector of
component references aligned with it. Repeated pairs become parallel edges with increasing
[`multiplicity`](@ref).
"""
function PowerGraph(nv::Integer, pairs)
    nv = Int(nv)
    seen = Dict{Tuple{Int,Int},Int}()
    edgelist = Vector{PowerEdge}(undef, length(pairs))
    fadj = [Int[] for _ = 1:nv]
    for (i, (s, d)) in enumerate(pairs)
        s, d = Int(s), Int(d)
        (1 <= s <= nv && 1 <= d <= nv) ||
            throw(ArgumentError("edge ($s, $d) is out of range for $nv vertices"))
        key = minmax(s, d)
        mult = get(seen, key, 0) + 1
        seen[key] = mult
        edgelist[i] = PowerEdge(s, d, mult)
        # deduplicated adjacency: see the note in the docstring
        d in fadj[s] || push!(fadj[s], d)
        s in fadj[d] || push!(fadj[d], s)
    end
    return PowerGraph(nv, edgelist, fadj)
end

Base.eltype(::PowerGraph) = Int
Base.eltype(::Type{PowerGraph}) = Int
Graphs.edgetype(::PowerGraph) = PowerEdge
Graphs.nv(g::PowerGraph) = g.nv
Graphs.ne(g::PowerGraph) = length(g.edges)
Graphs.vertices(g::PowerGraph) = Base.OneTo(g.nv)
Graphs.edges(g::PowerGraph) = g.edges
Graphs.has_vertex(g::PowerGraph, v) = 1 <= v <= g.nv
Graphs.outneighbors(g::PowerGraph, v) = g.fadj[v]
Graphs.inneighbors(g::PowerGraph, v) = g.fadj[v]
Graphs.is_directed(::PowerGraph) = false
Graphs.is_directed(::Type{PowerGraph}) = false

Graphs.has_edge(g::PowerGraph, s, d) = Graphs.has_vertex(g, s) && d in g.fadj[s]

"""
    simple_graph(g::PowerGraph) -> Graphs.SimpleGraph

The underlying simple graph, with parallel edges collapsed. Use this for topology questions
such as radial detection, where `ne(g)` inflated by parallel circuits would give the wrong
answer.
"""
function simple_graph(g::PowerGraph)
    sg = Graphs.SimpleGraph(g.nv)
    for e in g.edges
        Graphs.add_edge!(sg, e.src, e.dst)
    end
    return sg
end

"""
    parallel_offsets(g::PowerGraph; spread = 0.2) -> Vector{Float64}

Per-edge `curve_distance` values that fan parallel circuits apart, in the order of
`edges(g)`.

A single circuit between two buses stays straight (offset `0`). A group of `n > 1` parallel
circuits is spread evenly over `[-spread, spread]`, mirroring how PowerPlots.jl offsets
parallel edges along the edge normal (`PowerPlots/src/core/data.jl:39-51`) — except that
GraphMakie bows the edge rather than translating it, so the visual is an arc rather than a
parallel chord.

Pass the result as `curve_distance`, together with `curve_distance_usage = true`:
`automatic` bows only antiparallel edges of a *directed* graph and would leave these
overlapping.
"""
function parallel_offsets(g::PowerGraph; spread::Real = 0.2)
    counts = Dict{Tuple{Int,Int},Int}()
    for e in g.edges
        key = minmax(e.src, e.dst)
        counts[key] = max(get(counts, key, 0), e.mult)
    end
    offsets = Vector{Float64}(undef, ne(g))
    for (i, e) in enumerate(g.edges)
        n = counts[minmax(e.src, e.dst)]
        if n == 1
            offsets[i] = 0.0
        else
            # even spread over [-spread, spread], matching PowerPlots' offset_range
            offsets[i] = -spread + 2 * spread * (e.mult - 1) / (n - 1)
        end
    end
    return offsets
end
