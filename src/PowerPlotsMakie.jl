"""
    PowerPlotsMakie

Plot power-system networks with Makie.

A Makie port of [PowerPlots.jl](https://github.com/WISPO-POP/PowerPlots.jl), built on
GraphMakie and NetworkLayout. The data model is pluggable: any package can teach
PowerPlotsMakie about its networks by implementing the handful of functions in
`interface.jl`. Support for PowerModels.jl network dictionaries ships as a package
extension, loaded by `using PowerModels`.
"""
module PowerPlotsMakie

using Graphs: Graphs, nv, ne, edges, vertices, src, dst
using GeometryBasics: Point2f

# The topological backbone: an undirected graph that keeps parallel circuits distinct.
include("graph.jl")
# What a backend must implement, and the roles components play.
include("interface.jl")
# The canonical intermediate: data + graph + component references.
include("network.jl")

export PowerNetwork, powernetwork
export ComponentRef, ComponentRole, NodeRole, EdgeRole, InjectionRole
export PowerGraph, PowerEdge
export vertex_column, edge_column, vertex_components, edge_components
export vertex_indices, edge_indices, present_components

# Backend interface, exported so downstream packages can add methods without reaching into
# internals.
export component_types, component_ids, component_field
export edge_endpoints, injection_bus, reference_nodes, node_coordinates

end
