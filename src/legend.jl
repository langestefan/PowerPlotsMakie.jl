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
    stroke = Float64(Makie.to_value(p.gp_node_strokewidth))
    # Swatch sizes are the drawn sizes, so a key next to an automatically scaled plot shows
    # markers the size of the markers it is describing.
    scale = Float64(Makie.to_value(p.autoscale_factor))
    for role in (NodeRole(), InjectionRole())
        for comp in present_components(net, role)
            _push_entry!(out, net, p.node_style[], comp, :node, components, stroke, scale)
        end
    end
    for comp in present_components(net, EdgeRole())
        _push_entry!(out, net, p.edge_style[], comp, :edge, components, stroke, scale)
    end
    _push_boundary_entry!(out, p, net, components, stroke)
    return out
end

"The boundary nodes' entry, listed as component `:boundary` when the plot marks any."
function _push_boundary_entry!(out, p, net, wanted, strokewidth)
    p.boundary[] || return out
    wanted === nothing || :boundary in wanted || return out
    idx = boundary_indices(net)
    isempty(idx) && return out
    i = first(idx)
    style = p.node_style[]
    color = style.colors[i]
    push!(
        out,
        LegendEntry(
            :boundary,
            :node,
            _constant_result(color, 0),
            style.markers[i],
            nothing,
            p.gp_node_size[][i],
            style.strokecolors[i],
            strokewidth,
        ),
    )
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
    scale::Float64,
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
            bundle.sizes[i] * scale,
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

"""
Room a swatch needs, in pixels.

Makie's default patch is 20 px square, which an automatically scaled plot's markers can
easily outgrow — and a swatch wider than its patch runs over the label beside it. Only ever
grows the patch, so a small plot keeps Makie's proportions.
"""
function _patchsize(entries)
    isempty(entries) && return (20.0f0, 20.0f0)
    biggest = maximum(e.size + 2 * e.strokewidth for e in entries)
    side = Float32(max(20.0, biggest + 4.0))
    return (side, side)
end

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
    powerlegend!(pos, plot; components = nothing, colorbar = (;),
                 group_title = nothing, group_labels = (v, n) -> group_label(v), kwargs...)

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

A grouped plot (see `group` in [`powerplot`](@ref)) gets a section of its own, first, with
one entry per group: a line and a marker in the group's colour. Clicking an entry hides
the group, and clicking again shows it — the entry and the plot's `hidden_groups` stay in
step whichever is changed. Right-click the legend to flip every group. `group_title`
replaces the section's title (by default the field's name), and `group_labels(value,
counts)` its labels, where `counts` is `(; nodes, edges)` for that group, e.g.
`group_labels = (v, n) -> "\$(group_label(v)) kV (\$(n.nodes) buses)"`.
"""
function powerlegend!(
    pos,
    p::PowerPlot;
    components = nothing,
    colorbar = (;),
    group_title = nothing,
    group_labels = (v, _) -> group_label(v),
    kwargs...,
)
    entries = legend_entries(p; components = components)
    grid = GridLayout(pos)
    elements, labels, titles = legend_groups(entries)
    section = _group_section(p, group_title, group_labels)
    if section !== nothing
        pushfirst!(elements, section.elements)
        pushfirst!(labels, section.labels)
        pushfirst!(titles, section.title)
    end

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
            patchsize = section === nothing ? _patchsize(entries) :
                        max.(_patchsize(entries), section.patchsize),
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

"""
    _group_section(plot, title, labels) -> Union{Nothing,NamedTuple}

The legend section for a grouped plot: one line-and-marker swatch per group, each linked to
a toggle so that clicking it hides the group.

Makie's `Legend` hides and shows *plots*, while a group is a subset of one plot. So every
group gets a stand-in: an empty, invisible-to-the-eye scatter whose `visible` is the
group's visibility. The legend toggles the stand-in as it would any plot, and the stand-in
writes the result into the plot's `hidden_groups`; a change to `hidden_groups` from code is
written back the other way, so the legend's dimmed entries always match the plot. The
stand-ins live in the figure's root scene, where an empty plot cannot disturb any axis'
limits.
"""
function _group_section(p::PowerPlot, title, labels)
    groups = p.groups[]
    (groups.field === nothing || isempty(groups.values)) && return nothing
    net = _as_network(p.network[])
    counts = group_counts(net, groups)
    scene = Makie.parent_scene(p)
    root = scene === nothing ? nothing : Makie.root(scene)

    sizes = p.gp_node_size[]
    widths_ = p.gp_edge_width[]
    strokes = p.node_style[].strokecolors
    strokewidth = Float64(Makie.to_value(p.gp_node_strokewidth))
    hidden = p.hidden_groups[]

    elements = Vector{Any}()
    proxies = Pair{Any,Any}[]
    biggest = 0.0
    for v in groups.values
        color = groups.colors[v]
        nodes = findall(
            i -> net.vertex_roles[i] isa NodeRole && isequal(groups.vertex[i], v),
            eachindex(groups.vertex),
        )
        edges_ = findall(
            j -> net.edge_roles[j] isa EdgeRole && isequal(groups.edge[j], v),
            eachindex(groups.edge),
        )
        proxy =
            root === nothing ? nothing :
            Makie.scatter!(
                root,
                Point2f[];
                visible = !any(h -> isequal(h, v), hidden),
                inspectable = false,
            )
        proxy === nothing || push!(proxies, v => proxy)
        swatch = Any[]
        if !isempty(edges_)
            push!(
                swatch,
                LineElement(;
                    color,
                    linewidth = widths_[first(edges_)],
                    plots = proxy === nothing ? Makie.Plot[] : Makie.Plot[proxy],
                ),
            )
        end
        if !isempty(nodes)
            i = first(nodes)
            biggest = max(biggest, sizes[i] + 2 * strokewidth)
            # Only one element of an entry may name the stand-in: the legend toggles each
            # plot once per element naming it, and two toggles cancel out.
            push!(
                swatch,
                MarkerElement(;
                    color,
                    marker = :circle,
                    markersize = sizes[i],
                    strokecolor = strokes[i],
                    strokewidth,
                    plots = (isempty(edges_) && proxy !== nothing) ? Makie.Plot[proxy] :
                            Makie.Plot[],
                ),
            )
        end
        push!(elements, swatch)
    end
    _link_group_toggles!(p, proxies)

    return (
        title = title === nothing ? string(groups.field) : string(title),
        elements = elements,
        labels = String[labels(v, counts[v]) for v in groups.values],
        patchsize = (Float32(max(20.0, biggest + 4.0)), Float32(max(20.0, biggest + 4.0))),
    )
end

function _link_group_toggles!(p::PowerPlot, proxies)
    isempty(proxies) && return
    obs(x) = Makie.ComputePipeline.get_observable!(x)
    for (_, proxy) in proxies
        on(obs(proxy.visible)) do _
            hidden = Any[v for (v, q) in proxies if !q.visible[]]
            isequal(hidden, collect(p.hidden_groups[])) || (p.hidden_groups = hidden)
            return
        end
    end
    on(obs(p.hidden_groups)) do hidden
        for (v, q) in proxies
            shown = !any(h -> isequal(h, v), hidden)
            q.visible[] == shown || (q.visible = shown)
        end
        return
    end
    return
end
