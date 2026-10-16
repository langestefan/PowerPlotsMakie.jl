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
using GeometryBasics: Point2f, Point2d, Vec2f, widths
using Colors: Colorant, RGB
using Makie:
    Makie,
    Attributes,
    Colorbar,
    GridLayout,
    Legend,
    LineElement,
    MarkerElement,
    Observable,
    on,
    RGBAf,
    Rect2f,
    scatter!,
    to_color,
    @recipe
using GraphMakie: GraphMakie, graphplot!
import NetworkLayout
using PrecompileTools: @compile_workload, @setup_workload

# The topological backbone: an undirected graph that keeps parallel circuits distinct.
include("graph.jl")
# What a backend must implement, and the roles components play.
include("interface.jl")
# The canonical intermediate: data + graph + component references.
include("network.jl")
# Palettes and the resolution of colour/size specifications into per-index vectors.
include("attributes.jl")
# Turning design units into pixels for the figure at hand.
include("scale.jl")
# Radial detection and the Buchheim tree layout.
include("radial.jl")
# Projecting the data's coordinates, and the web-map entry points Tyler.jl fills in.
include("maps.jl")
# Vertex positioning, pinning and pre-existing coordinates.
include("layouts.jl")
# Edge routes from the data, laid between the drawn node positions.
include("routes.jl")
# Grouping vertices and edges by a node field, for colouring and hiding.
include("groups.jl")
# Power-flow arrow geometry.
include("flow.jl")
# The Makie recipe itself.
include("linestyles.jl")

include("recipe.jl")
# Which component is under the mouse, and the hover tooltip.
include("hover.jl")
# Legends and colorbars, which Makie builds for no plot automatically.
include("legend.jl")
# The academic preset.
include("theme.jl")
# Opt-in dragging, pinning and re-layout.
include("interaction.jl")
# Warm the plotting path at build time rather than on first use.
include("precompile.jl")

export powerplot, powerplot!, Field
export powerlegend!, powercolorbar!, legend_entries, legend_groups, LegendEntry
export flow_arrows, flow_field, FlowArrows
export autoscale_factor, nearest_neighbor_spacing
export academic_theme, ACADEMIC_COMPONENTS
export interactive!, relayout!, resync!, LayoutState
export drag!, drag_group!, pin!, unpin!, unpin_all!, ispinned
export select!, select_in!, deselect_all!, isselected
export PowerNetwork, powernetwork
export ComponentRef, ComponentRole, NodeRole, EdgeRole, InjectionRole
export PowerGraph, PowerEdge
export RadialTree, isradial, radial_tree, layout_positions
export edge_routes, route_waypoints
export web_mercator, powermap, powermap!, basemap
export LinestyleResult, resolve_linestyles, RouteLayer, route_segments, segment_styled_edges
export NetworkGroups, network_groups, group_label, group_counts, hidden_masks
export component_at, hover_text
export vertex_column, edge_column, vertex_components, edge_components
export vertex_indices, edge_indices, present_components

# Backend interface, exported so downstream packages can add methods without reaching into
# internals.
export component_types, component_ids, component_field
export edge_endpoints, injection_bus, reference_nodes, boundary_nodes
export node_coordinates, edge_coordinates

__init__() = _register_map_hint()

end
