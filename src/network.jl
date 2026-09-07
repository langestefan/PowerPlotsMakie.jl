"""
    PowerNetwork

A power network prepared for plotting: the backend data, the [`PowerGraph`](@ref) built
from it, and the component references that give every vertex and edge its meaning.

`vertices[i]` is the component drawn at vertex `i`, and `edges[j]` the component drawn as
`edges(graph)[j]`, so any per-index vector handed to GraphMakie can be traced back to the
component it describes. Vertices are ordered node components first, then injections; edges
are ordered edge components first, then the synthesized connectors.

Build one with [`powernetwork`](@ref).
"""
struct PowerNetwork{D}
    data::D
    graph::PowerGraph
    vertices::Vector{ComponentRef}
    edges::Vector{ComponentRef}
    vertex_roles::Vector{ComponentRole}
    edge_roles::Vector{ComponentRole}
    vertex_index::Dict{ComponentRef,Int}
end

"""
    CONNECTOR

Component type of the synthesized edges joining an injection to its bus. These have no
counterpart in the source data, so `component_field` is never consulted for them.
"""
const CONNECTOR = :connector

"""
    powernetwork(data) -> PowerNetwork

Build the plot graph for `data` using the loaded backend.

Node components become vertices, injections become further vertices joined to their bus by
a [`CONNECTOR`](@ref) edge, and edge components become edges between the vertices of their
endpoints. Component types with no instances are skipped entirely, and edge components
whose endpoints are missing from the data are dropped with a warning rather than aborting
the plot.
"""
function powernetwork(data)
    _assert_supported(data)

    vertices = ComponentRef[]
    vertex_roles = ComponentRole[]
    vertex_index = Dict{ComponentRef,Int}()

    # Node components first, then injections. The ordering is what the palette rotation and
    # the drawing order are keyed on, so it must not depend on Dict iteration order.
    for role in (NodeRole(), InjectionRole())
        for comp in component_types(data, role)
            for id in component_ids(data, comp)
                ref = ComponentRef(comp, id)
                push!(vertices, ref)
                push!(vertex_roles, role)
                vertex_index[ref] = length(vertices)
            end
        end
    end

    node_refs = Dict{Tuple{Symbol,String},Int}()
    for (i, ref) in enumerate(vertices)
        vertex_roles[i] isa NodeRole && (node_refs[(ref.component, ref.id)] = i)
    end
    # Endpoint ids are looked up by id alone: an edge names its buses, not their component
    # type.
    node_by_id = Dict{String,Int}()
    for (i, ref) in enumerate(vertices)
        vertex_roles[i] isa NodeRole && get!(node_by_id, ref.id, i)
    end

    edges = ComponentRef[]
    edge_roles = ComponentRole[]
    pairs = Tuple{Int,Int}[]

    for comp in component_types(data, EdgeRole())
        for id in component_ids(data, comp)
            from, to = edge_endpoints(data, comp, id)
            f = get(node_by_id, string(from), 0)
            t = get(node_by_id, string(to), 0)
            if f == 0 || t == 0
                @warn "skipping $comp[\"$id\"]: endpoint not found in node components" from to
                continue
            end
            push!(edges, ComponentRef(comp, id))
            push!(edge_roles, EdgeRole())
            push!(pairs, (f, t))
        end
    end

    # Connectors, in injection-vertex order so they are reproducible.
    for (i, ref) in enumerate(vertices)
        vertex_roles[i] isa InjectionRole || continue
        bus = string(injection_bus(data, ref.component, ref.id))
        b = get(node_by_id, bus, 0)
        if b == 0
            @warn "skipping connector for $ref: bus not found" bus
            continue
        end
        push!(edges, ComponentRef(CONNECTOR, "$(ref.component)_$(ref.id)"))
        push!(edge_roles, InjectionRole())
        push!(pairs, (b, i))
    end

    graph = PowerGraph(length(vertices), pairs)
    return PowerNetwork(
        data, graph, vertices, edges, vertex_roles, edge_roles, vertex_index,
    )
end

Graphs.nv(net::PowerNetwork) = nv(net.graph)
Graphs.ne(net::PowerNetwork) = ne(net.graph)

"Indices of the vertices playing `role`."
vertex_indices(net::PowerNetwork, role::ComponentRole) =
    findall(r -> r isa typeof(role), net.vertex_roles)

"Indices of the edges playing `role`."
edge_indices(net::PowerNetwork, role::ComponentRole) =
    findall(r -> r isa typeof(role), net.edge_roles)

"Indices of the vertices belonging to component type `comp`."
vertex_indices(net::PowerNetwork, comp::Symbol) =
    findall(r -> r.component === comp, net.vertices)

"Indices of the edges belonging to component type `comp`."
edge_indices(net::PowerNetwork, comp::Symbol) =
    findall(r -> r.component === comp, net.edges)

"""
    vertex_components(net) -> Vector{Symbol}
    edge_components(net) -> Vector{Symbol}

The component type of each vertex / edge, in index order.

This is the equivalent of the `ComponentType` column PowerPlots.jl injects into its
DataFrames, and it is the default field for categorical colouring: with no other
instruction, a plot is coloured by component type.
"""
vertex_components(net::PowerNetwork) = [r.component for r in net.vertices]
edge_components(net::PowerNetwork) = [r.component for r in net.edges]

"""
    vertex_column(net, field::Symbol) -> Vector
    edge_column(net, field::Symbol) -> Vector

Look `field` up for every vertex / edge, in index order, with `missing` where a component
has no such field.

This is deliberately not a DataFrame: the per-index vector is exactly the shape GraphMakie
consumes for its attributes, and building one on demand avoids materialising a table of
every field of every component just to colour by one of them.
"""
vertex_column(net::PowerNetwork, field::Symbol) = _column(net, net.vertices, field)
edge_column(net::PowerNetwork, field::Symbol) = _column(net, net.edges, field)

function _column(net::PowerNetwork, refs::Vector{ComponentRef}, field::Symbol)
    field === :component && return [r.component for r in refs]
    return [
        r.component === CONNECTOR ? missing :
        component_field(net.data, r.component, r.id, field) for r in refs
    ]
end

"""
    present_components(net, role) -> Vector{Symbol}

Component types playing `role` that actually have instances in this network, in drawing
order.

PowerPlots assigns default colours only to components that have rows, so an absent
component type consumes no palette slot and does not shift the colours of the others
(`PowerPlots/src/core/utils.jl:16-36`). Reproducing that behaviour needs this list.
"""
function present_components(net::PowerNetwork, role::ComponentRole)
    refs = role isa EdgeRole ? net.edges : net.vertices
    roles = role isa EdgeRole ? net.edge_roles : net.vertex_roles
    out = Symbol[]
    for (i, r) in enumerate(refs)
        roles[i] isa typeof(role) || continue
        r.component === CONNECTOR && continue
        r.component in out || push!(out, r.component)
    end
    return out
end

function Base.show(io::IO, net::PowerNetwork)
    nnode = count(r -> r isa NodeRole, net.vertex_roles)
    ninj = count(r -> r isa InjectionRole, net.vertex_roles)
    nedge = count(r -> r isa EdgeRole, net.edge_roles)
    ncon = count(r -> r isa InjectionRole, net.edge_roles)
    print(
        io,
        "PowerNetwork($nnode nodes, $ninj injections, $nedge edges, $ncon connectors)",
    )
end
