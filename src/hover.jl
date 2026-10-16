"""
    component_at(plot, picked, index) -> Union{Nothing,ComponentRef}
    component_at(plot, (picked, index)) -> Union{Nothing,ComponentRef}

The component drawn at `index` of the primitive plot `picked`, as returned by
`Makie.pick`, or `nothing` when that is not part of `plot`'s network or belongs to a hidden
group.

The network is drawn by GraphMakie's scatter and lines, whose indices are points of those
primitives rather than vertices and edges. This is the translation back, so a hover readout
or click handler can work with buses and branches:

```julia
on(events(fig).mouseposition) do _
    ref = component_at(p, pick(ax.scene))
    ref === nothing || (label.text = string(ref))
end
```
"""
function component_at(p::PowerPlot, picked, index)
    index isa Integer || return nothing
    net = _as_network(p.network[])
    gp = graph_plot(p)
    if picked === GraphMakie.get_node_plot(gp)
        1 <= index <= nv(net) || return nothing
        p.vertex_hidden[][index] && return nothing
        return net.vertices[index]
    end
    j = _route_layer_edge(p, picked, index)
    j === nothing && (j = _edge_at(GraphMakie.get_edge_plot(gp), picked, index))
    (j === nothing || !(1 <= j <= ne(net))) && return nothing
    p.edge_hidden[][j] && return nothing
    return net.edges[j]
end

component_at(p::PowerPlot, picked::Tuple) = component_at(p, picked...)
component_at(p::Makie.FigureAxisPlot, args...) = component_at(p.plot, args...)

"""
The edge a point of GraphMakie's edge lines belongs to.

GraphMakie draws all edges as one NaN-separated `lines` and records which points belong to
which edge in `ranges` — unless the edges have different line styles, in which case it
draws one `lines` per edge (`split_edgeplots`) and the plot itself says which edge it is.
"""
function _edge_at(edgeplot, picked, index)
    k = findfirst(c -> c === picked, edgeplot.plots)
    k === nothing && return nothing
    edgeplot.split_edgeplots[] && return k
    return findfirst(r -> index in r, edgeplot.ranges[])
end

"""
The edge a point of one of the route layers belongs to (see [`route_segments`](@ref)): the
layers are the plot's own `lines`, one per line style.
"""
function _route_layer_edge(p::PowerPlot, picked, index)
    # Makie converts a plot's `linestyle` into a dash pattern, so the style a layer stands
    # for is looked up by the plot rather than read back from it.
    plots = get(ROUTE_LAYER_PLOTS, p, nothing)
    plots === nothing && return nothing
    k = findfirst(q -> q === picked, plots)
    k === nothing && return nothing
    layer = get(p.route_layers[], k, nothing)
    (layer === nothing || !(1 <= index <= length(layer.edges))) && return nothing
    return layer.edges[index]
end

"""
    hover_text(plot, ref) -> String

The tooltip for component `ref`: which component it is, then one line per field in the
plot's `hover_fields` that the component has.
"""
function hover_text(p::PowerPlot, ref)
    ref === nothing && return ""
    text = string(ref)
    ref.component === CONNECTOR && return text
    net = _as_network(p.network[])
    for f in p.hover_fields[]
        v = component_field(net.data, ref.component, ref.id, f)
        ismissing(v) || (text *= "\n$f = $(_hover_value(v))")
    end
    return text
end

_hover_value(v::AbstractFloat) = string(round(v; sigdigits = 4))
_hover_value(v) = string(v)

"""
Give GraphMakie's node scatter and edge lines tooltips that name the component, for
Makie's `DataInspector`, which otherwise shows bare coordinates.

The label is set where each plot holds it: the node scatter has its own, while the edge
lines take theirs from the edge plot that draws them. Makie calls it with the primitive
under the cursor, which [`component_at`](@ref) translates back.
"""
function _attach_hover!(p::PowerPlot)
    gp = graph_plot(p)
    label = (picked, i, _) -> hover_text(p, component_at(p, picked, i))
    edgeplot = GraphMakie.get_edge_plot(gp)
    for t in (GraphMakie.get_node_plot(gp), edgeplot, edgeplot.plots...)
        haskey(t.attributes.inputs, :inspector_label) && (t.inspector_label = label)
    end
    return p
end
