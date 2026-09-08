"""
    LegendEntry

One component type's contribution to a plot's key.

Carries the [`ColorResult`](@ref) the plot was drawn with, plus the marker or line style
that component was given, so that a legend swatch looks like the thing it describes rather
than like a generic blob.
"""
struct LegendEntry
    component::Symbol
    role::Symbol            # :node or :edge — which style bundle it came from
    result::ColorResult
    marker::Any             # nodes only
    linestyle::Any          # edges only
    size::Float64           # markersize for nodes, linewidth for edges
    strokecolor::RGBAf      # nodes only
    strokewidth::Float64    # nodes only
end

"""
    legend_entries(plot; components = nothing) -> Vector{LegendEntry}

The component types `plot` draws that can be described in a key, in drawing order: node
components, then injections, then edges.

`components` restricts the result to the named component types. Two kinds of component are
never listed: the synthesized connectors, which are plumbing rather than data, and any
component whose colour was given as an explicit per-index vector, since a list of colours
has no single swatch to stand for it.

The entries are a snapshot. Restyling the plot afterwards updates the colours a
[`powercolorbar!`](@ref) shows, but not which entries exist — rebuild the key for that.
"""
function legend_entries(p::PowerPlot; components = nothing)
    net = _as_network(p.network[])
    out = LegendEntry[]
    # Stroke width is a scatter uniform, so it is plot-level rather than per component.
    stroke = Float64(Makie.to_value(p.node_strokewidth))
    for role in (NodeRole(), InjectionRole())
        for comp in present_components(net, role)
            _push_entry!(out, net, p.node_style[], comp, :node, components, stroke)
        end
    end
    for comp in present_components(net, EdgeRole())
        _push_entry!(out, net, p.edge_style[], comp, :edge, components, stroke)
    end
    return out
end

legend_entries(p::Makie.FigureAxisPlot; kwargs...) = legend_entries(p.plot; kwargs...)

function _push_entry!(
    out,
    net,
    bundle::StyleBundle,
    comp::Symbol,
    role::Symbol,
    wanted,
    strokewidth::Float64,
)
    wanted === nothing || comp in wanted || return out
    result = get(bundle.results, comp, nothing)
    # `:explicit` colours came in as a per-index vector: there is nothing to label.
    (result === nothing || result.kind === :explicit) && return out
    idx = role === :node ? vertex_indices(net, comp) : edge_indices(net, comp)
    isempty(idx) && return out
    i = first(idx)
    push!(
        out,
        LegendEntry(
            comp,
            role,
            result,
            role === :node ? bundle.markers[i] : nothing,
            role === :edge ? bundle.linestyles[i] : nothing,
            bundle.sizes[i],
            bundle.strokecolors[i],
            strokewidth,
        ),
    )
    return out
end

"""
A swatch shaped like the component it stands for: a marker for nodes, a line for edges.

The stroke comes along for the ride, because an academic figure draws its generators as an
open marker and a white swatch on a white legend is no swatch at all.
"""
_swatch(e::LegendEntry, color) =
    e.role === :node ?
    MarkerElement(;
        color = color,
        marker = e.marker,
        markersize = e.size,
        strokecolor = e.strokecolor,
        strokewidth = e.strokewidth,
    ) : LineElement(; color = color, linestyle = e.linestyle, linewidth = e.size)

"Title Makie gives the group of components drawn in a single flat colour."
const COMPONENT_GROUP_TITLE = "component"

"""
    legend_groups(entries) -> (elements, labels, titles)

Arrange entries into the grouped form `Legend` takes.

Components drawn in one flat colour share a single group — that group *is* the key to what
each colour means, and is the whole legend of a default plot. Every categorically coloured
component then gets its own group, titled with the field driving it, so that two components
coloured by different fields cannot be mistaken for one scale.
"""
function legend_groups(entries::Vector{LegendEntry})
    elements = Vector{Vector{Any}}()
    labels = Vector{Vector{String}}()
    titles = String[]

    flat_el, flat_lb = Any[], String[]
    for e in entries
        r = e.result
        if r.kind === :constant
            push!(flat_el, _swatch(e, first(r.swatches)))
            push!(flat_lb, string(e.component))
        elseif r.kind === :categorical
            push!(elements, Any[_swatch(e, c) for c in r.swatches])
            push!(labels, String[string(v) for v in r.categories])
            push!(titles, "$(e.component) ($(r.field))")
        end
    end

    if !isempty(flat_el)
        pushfirst!(elements, flat_el)
        pushfirst!(labels, flat_lb)
        pushfirst!(titles, COMPONENT_GROUP_TITLE)
    end
    return elements, labels, titles
end

"""
    powercolorbar!(pos, plot, component; kwargs...) -> Colorbar

A `Colorbar` for one continuously coloured component of `plot`.

`pos` is a grid position, e.g. `fig[1, 2]`. The bar follows the plot: restyle the
component and its colormap and limits update with it. `kwargs` go to `Colorbar`, so the
default label can be replaced with `label = "voltage (pu)"` and so on.

```julia
f, ax, p = powerplot(case; components = Dict(:bus => (color = Field(:vm),)))
powercolorbar!(f[1, 2], p, :bus)
```

Throws if `component` is not drawn with a continuous colour scale — there is nothing for a
colorbar to show.
"""
function powercolorbar!(pos, p::PowerPlot, component::Symbol; kwargs...)
    entry = nothing
    for e in legend_entries(p)
        e.component === component && (entry = e; break)
    end
    entry === nothing &&
        throw(ArgumentError("$(repr(component)) is not a component of this plot"))
    entry.result.kind === :continuous || throw(
        ArgumentError(
            "$(repr(component)) is coloured $(entry.result.kind), not continuously; " *
            "a colorbar needs a colour scale",
        ),
    )

    bundle = entry.role === :node ? p.node_style : p.edge_style
    fallback = entry.result
    track(f) = Makie.lift(b -> f(get(b.results, component, fallback)), bundle)
    return Colorbar(
        pos;
        colormap = track(r -> r.colormap),
        limits = track(r -> r.colorrange),
        label = "$(component) ($(entry.result.field))",
        kwargs...,
    )
end

powercolorbar!(pos, p::Makie.FigureAxisPlot, component::Symbol; kwargs...) =
    powercolorbar!(pos, p.plot, component; kwargs...)

"""
    powerlegend!(pos, plot; components = nothing, colorbar = (;), kwargs...)

Build the complete key for `plot` at `pos`: one `Legend` describing every component drawn
in a flat or categorical colour, and a `Colorbar` under it for each component drawn with a
continuous colour scale.

`pos` is a grid position (`fig[1, 2]`) or a `Figure`, in which case a new column is added
to its right. Makie builds none of this automatically — a plot that packs four component
types into a single `graphplot` needs to be told what its colours mean.

Returns `(; grid, legend, colorbars)`. `legend` is `nothing` when every component is
coloured continuously, and `colorbars` is empty when none is.

```julia
f, ax, p = powerplot(case;
    components = Dict(:bus => (color = Field(:vm), colormap = :viridis)))
powerlegend!(f[1, 2], p)
```

`components` restricts the key to the named component types, which is how a single
component is suppressed; leaving the call out altogether suppresses the lot. `kwargs` go
to `Legend` and `colorbar` to every `Colorbar`.
"""
function powerlegend!(pos, p::PowerPlot; components = nothing, colorbar = (;), kwargs...)
    entries = legend_entries(p; components = components)
    grid = GridLayout(pos)
    elements, labels, titles = legend_groups(entries)

    row = 0
    legend = nothing
    if !isempty(elements)
        row += 1
        # Without this the legend is stretched to fill its share of the column, which for
        # a two-entry key means a lot of white space between the swatches.
        legend = Legend(
            grid[row, 1],
            elements,
            labels,
            titles;
            tellheight = true,
            valign = :top,
            kwargs...,
        )
    end

    colorbars = Colorbar[]
    for e in entries
        e.result.kind === :continuous || continue
        row += 1
        push!(colorbars, powercolorbar!(grid[row, 1], p, e.component; colorbar...))
    end

    return (grid = grid, legend = legend, colorbars = colorbars)
end

powerlegend!(pos, p::Makie.FigureAxisPlot; kwargs...) = powerlegend!(pos, p.plot; kwargs...)

# A bare `Figure` means "put the key somewhere sensible": a new column on the right.
powerlegend!(fig::Makie.Figure, p::PowerPlot; kwargs...) =
    powerlegend!(fig[:, end+1], p; kwargs...)
powerlegend!(fig::Makie.Figure, p::Makie.FigureAxisPlot; kwargs...) =
    powerlegend!(fig[:, end+1], p.plot; kwargs...)
