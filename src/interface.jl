"""
    ComponentRole

How a component type participates in the plot graph. Power-system data models differ in
what they call things, but they agree on these three roles, so the generic graph builder is
written against the roles rather than against any particular data model.

Subtypes: [`NodeRole`](@ref), [`EdgeRole`](@ref), [`InjectionRole`](@ref).
"""
abstract type ComponentRole end

"Components that are graph vertices in their own right, i.e. buses."
struct NodeRole <: ComponentRole end

"Components that connect two nodes: branches, transformers, switches, DC lines."
struct EdgeRole <: ComponentRole end

"""
Components attached to a single node: generators, loads, storage, shunts.

Following PowerPlots.jl, these become *extra* graph vertices joined to their bus by a
synthesized "connector" edge, rather than being folded into the bus. That way the layout
algorithm spaces them out and they can be styled, hovered and dragged independently.
"""
struct InjectionRole <: ComponentRole end

"""
    ComponentRef

A reference to one component instance: its type (`:bus`, `:branch`, ...) and its id within
that type. Vertices and edges of a [`PowerNetwork`](@ref) each carry a vector of these,
aligned with the vertex/edge ordering, so per-index plot attributes can be resolved back to
the component they came from.
"""
struct ComponentRef
    component::Symbol
    id::String
end

Base.show(io::IO, r::ComponentRef) = print(io, "$(r.component)[\"$(r.id)\"]")

# ---------------------------------------------------------------------------------------
# The backend interface.
#
# A backend supports PowerPlotsMakie by adding methods to these functions for its own data
# type. The generic builder in network.jl does the rest: vertex numbering, connector
# synthesis and attribute lookup are implemented once, against the interface.
# ---------------------------------------------------------------------------------------

"""
    component_types(data, role::ComponentRole) -> Vector{Symbol}

The component types in `data` that play `role`, in the order they should be drawn and
assigned palette colours.

Return every type the data model *may* contain; the builder skips those with no instances.
"""
function component_types end

"""
    component_ids(data, comp::Symbol) -> Vector{String}

The ids of all instances of component type `comp`, or an empty vector if there are none.

The order fixes the vertex and edge numbering of the resulting graph, so it must be stable
across calls on equal data — sort it.
"""
function component_ids end

"""
    component_field(data, comp::Symbol, id::AbstractString, field::Symbol)

The value of `field` for one component instance, or `missing` when that instance has no
such field.

Returning `missing` rather than throwing matters: power-system data is ragged (only solved
cases have `pf`, only some buses have coordinates), and the plotting code relies on
`missing` to decide that a component cannot be coloured by a given field.
"""
function component_field end

"""
    edge_endpoints(data, comp::Symbol, id::AbstractString) -> (from, to)

The ids of the two node components that edge component `id` connects.
"""
function edge_endpoints end

"""
    injection_bus(data, comp::Symbol, id::AbstractString) -> String

The id of the node component that injection `id` is attached to.
"""
function injection_bus end

"""
    reference_nodes(data) -> Vector{String}

Ids of node components that are natural roots of the network — slack/reference buses, or
the substation of a distribution feeder.

Used to root the radial layout. The default returns an empty vector, in which case the
layout falls back to a topological choice; backends should implement it when the data model
records the information (for PowerModels, `bus_type == 3`).
"""
reference_nodes(::Any) = String[]

"""
    node_coordinates(data, comp::Symbol, id::AbstractString) -> Union{Nothing,Point2}

Pre-existing coordinates for a node component, or `nothing` when it has none.

Networks that carry geographic or hand-authored positions are laid out by pinning these
nodes and solving for the rest, which is how PowerPlots.jl's `fixed = true` behaves. The
default returns `nothing` for every node, i.e. positions come purely from the layout.
"""
node_coordinates(::Any, ::Symbol, ::AbstractString) = nothing

"""
    supports(data) -> Bool

Whether a backend is loaded for `data`. Used only to produce a helpful error message.
"""
supports(data) = applicable(component_types, data, NodeRole())

function _assert_supported(data)
    supports(data) && return nothing
    throw(
        ArgumentError(
            """
            No PowerPlotsMakie backend is loaded for data of type $(typeof(data)).

            For PowerModels network dictionaries, load PowerModels to trigger the extension:

                using PowerModels, PowerPlotsMakie

            To support another data model, add methods for `component_types`, `component_ids`,
            `component_field`, `edge_endpoints` and `injection_bus`.
            """,
        ),
    )
end
