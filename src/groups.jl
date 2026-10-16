"""
    NetworkGroups

Which group every vertex and edge belongs to, and the colour each group is drawn in.

A group is a value of one node field — a bus's voltage level, its zone, its owner — and is
what a plot of a large network is usually read by: "show me the 150 kV layer", "hide the
foreign buses". Grouping does two things the per-component styling cannot: it colours
nodes *and* the edges between them by the same key, and it lets whole groups be hidden
without splitting the network into several plots.

`vertex[i]` and `edge[j]` are the group of vertex `i` and edge `j`, `missing` where there
is none; `edge_ends[j]` holds the groups of edge `j`'s two endpoints, which decide whether
an edge between two groups — a transformer — is drawn when one of them is hidden.
"""
struct NetworkGroups
    field::Union{Nothing,Symbol}
    values::Vector{Any}
    colors::Dict{Any,RGBAf}
    vertex::Vector{Any}
    edge::Vector{Any}
    edge_ends::Vector{Tuple{Any,Any}}
end

"No grouping: every vertex and edge belongs to no group."
function NetworkGroups(net::PowerNetwork)
    return NetworkGroups(
        nothing,
        Any[],
        Dict{Any,RGBAf}(),
        fill(missing, nv(net)),
        fill(missing, ne(net)),
        fill((missing, missing), ne(net)),
    )
end

"""
    network_groups(net, group; palette = nothing) -> NetworkGroups

Sort the vertices and edges of `net` into groups by the node field `group`, a
[`Field`](@ref) (or `nothing` for no grouping).

Node components take the field's value. Everything else inherits it, unless it carries the
field itself: an injection from its bus, an edge from its endpoints when both lie in the
same group. An edge whose endpoints lie in different groups — a transformer between two
voltage levels — belongs to neither, keeps its own component colour, and is hidden when
either end is.

`palette` colours the groups: a `Dict` from group value to colour, a vector of colours
handed out over the sorted values, or a colormap name sampled across them. Values a `Dict`
does not mention, and every value when `palette` is `nothing`, take Makie's default
categorical palette.
"""
function network_groups(net::PowerNetwork, group; palette = nothing)
    group === nothing && return NetworkGroups(net)
    group isa Field || throw(
        ArgumentError(
            "group = $(repr(group)) is not understood; expected nothing or Field(:name)",
        ),
    )
    field = group.name

    vertex = Vector{Any}(missing, nv(net))
    for (i, ref) in enumerate(net.vertices)
        net.vertex_roles[i] isa NodeRole || continue
        vertex[i] = _group_value(component_field(net.data, ref.component, ref.id, field))
    end

    edgelist = net.graph.edges
    edge = Vector{Any}(missing, ne(net))
    ends = Vector{Tuple{Any,Any}}(undef, ne(net))
    for (j, ref) in enumerate(net.edges)
        e = edgelist[j]
        if net.edge_roles[j] isa InjectionRole
            # A connector runs from the bus to the injection: it, and the injection, take
            # the injection's own value if it has one and the bus's otherwise.
            inj = dst(e)
            r = net.vertices[inj]
            own = _group_value(component_field(net.data, r.component, r.id, field))
            vertex[inj] = ismissing(own) ? vertex[src(e)] : own
            edge[j] = vertex[inj]
            ends[j] = (vertex[src(e)], vertex[inj])
        else
            a, b = vertex[src(e)], vertex[dst(e)]
            own = _group_value(component_field(net.data, ref.component, ref.id, field))
            edge[j] = !ismissing(own) ? own : (!ismissing(a) && isequal(a, b) ? a : missing)
            ends[j] = (a, b)
        end
    end

    values = unique(skipmissing(vcat(vertex, edge)))
    try
        sort!(values)
    catch
        # Values that do not define an order keep first-seen order.
    end
    return NetworkGroups(field, values, _group_colors(values, palette), vertex, edge, ends)
end

"A field value as a group key: `nothing` and `missing` mean no group."
_group_value(v) = v === nothing ? missing : v

function _group_colors(values, palette)
    defaults = Makie.wong_colors()
    fallback(i) = RGBAf(to_color(defaults[mod1(i, length(defaults))]))
    out = Dict{Any,RGBAf}()
    for (i, v) in enumerate(values)
        out[v] = if palette isa AbstractDict
            haskey(palette, v) ? RGBAf(to_color(palette[v])) : fallback(i)
        elseif palette isa AbstractVector
            RGBAf(to_color(palette[mod1(i, length(palette))]))
        elseif palette !== nothing
            ramp = _as_ramp(palette)
            _sample(ramp, length(values) == 1 ? 0.0 : (i - 1) / (length(values) - 1))
        else
            fallback(i)
        end
    end
    return out
end

"""
    group_label(value) -> String

How a group value reads in a legend: whole numbers stored as floats lose their `.0`, so a
voltage level of `150.0` reads as `150`.
"""
group_label(v) = v isa AbstractFloat && isinteger(v) ? string(Int(v)) : string(v)

"""
    hidden_masks(groups, hidden) -> (vertices::BitVector, edges::BitVector)

Which vertices and edges are hidden when the groups in `hidden` are.

A vertex is hidden with its group. An edge is hidden with its own group, and also with
either endpoint's, so that hiding a voltage level takes the transformers into it along.
"""
function hidden_masks(groups::NetworkGroups, hidden)
    isempty(hidden) && return falses(length(groups.vertex)), falses(length(groups.edge))
    h(v) = !ismissing(v) && any(x -> isequal(x, v), hidden)
    vertices = BitVector(h.(groups.vertex))
    edges = BitVector([
        h(groups.edge[j]) || h(groups.edge_ends[j][1]) || h(groups.edge_ends[j][2]) for
        j in eachindex(groups.edge)
    ])
    return vertices, edges
end

"""
    group_counts(net, groups) -> Dict{Any,NamedTuple}

How many node components and edge components each group holds, as `(nodes, edges)`.
Injections and connectors are not counted.
"""
function group_counts(net::PowerNetwork, groups::NetworkGroups)
    out = Dict{Any,NamedTuple{(:nodes, :edges),Tuple{Int,Int}}}()
    for v in groups.values
        nodes = count(
            i -> net.vertex_roles[i] isa NodeRole && isequal(groups.vertex[i], v),
            eachindex(groups.vertex),
        )
        edges = count(
            j -> net.edge_roles[j] isa EdgeRole && isequal(groups.edge[j], v),
            eachindex(groups.edge),
        )
        out[v] = (nodes = nodes, edges = edges)
    end
    return out
end
