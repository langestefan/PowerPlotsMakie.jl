"""
    powerplot(data; kwargs...)
    powerplot!(ax, data; kwargs...)

Plot a power-system network.

`data` is anything a loaded backend understands — a PowerModels network dictionary, say —
or a [`PowerNetwork`](@ref) built earlier with [`powernetwork`](@ref).

The whole network is drawn as a single GraphMakie `graphplot`: buses and injections are
vertices, branches and connectors are edges, and per-component styling is expressed as
per-index vectors. Parallel circuits keep their own identity, and are fanned apart by
`parallel_spread`.

# Styling

Role-level attributes apply to every component of that role:

  - nodes: `node_color`, `node_size`, `node_marker`, `node_strokewidth`, `node_strokecolor`
  - edges: `edge_color`, `edge_width`, `edge_linestyle`
  - connectors: `connector_color`, `connector_width`, `connector_linestyle`

each with the usual Makie colour companions (`*_colormap`, `*_colorrange`, `*_colormode`,
`*_palette`).

Per-component overrides go in `components`, keyed by component type:

```julia
powerplot(case;
    components = Dict(
        :bus    => (color = Field(:vm), colormap = :viridis),
        :branch => (color = Field(:rate_a), width = 3),
        :gen    => (color = :orange, marker = :rect),
    ),
)
```

A colour is constant unless it is wrapped in [`Field`](@ref), which names a data field to
colour by; numeric fields get a continuous ramp and everything else a categorical palette,
overridable with `colormode`.

Note that `components` must be a `Dict` (or a vector of pairs). A NamedTuple cannot be used
here: Makie converts NamedTuple-valued attributes to `Attributes` and the nested
per-component settings are lost in the process.
"""
@recipe(PowerPlot, network) do scene
    Attributes(
        # --- topology and geometry -----------------------------------------------------
        layout = :auto,
        pin = nothing,
        parallel_spread = 0.2,
        components = Dict{Symbol,Any}(),

        # --- nodes ---------------------------------------------------------------------
        node_color = nothing,
        node_size = 12.0,
        node_marker = :circle,
        node_strokewidth = 0.0,
        node_strokecolor = :black,
        node_colormap = nothing,
        node_colorrange = nothing,
        node_colormode = :auto,
        node_palette = nothing,

        # --- edges ---------------------------------------------------------------------
        edge_color = nothing,
        edge_width = 2.0,
        edge_linestyle = :solid,
        edge_colormap = nothing,
        edge_colorrange = nothing,
        edge_colormode = :auto,
        edge_palette = nothing,

        # --- connectors (injection stubs) ----------------------------------------------
        connector_color = nothing,
        connector_width = 1.0,
        connector_linestyle = :dash,

        # --- escape hatch --------------------------------------------------------------
        graphplot_attr = (;),
    )
end

_as_network(net::PowerNetwork) = net
_as_network(data) = powernetwork(data)

Makie.convert_arguments(::Type{<:PowerPlot}, net::PowerNetwork) = (net,)
Makie.convert_arguments(::Type{<:PowerPlot}, data) = (powernetwork(data),)

"""
    NodeStyle / EdgeStyle

Per-index style vectors for the vertices / edges of a network, together with the
[`ColorResult`](@ref)s they came from. The colour results are kept so that legends and
colorbars can be built later without redoing the resolution.
"""
struct StyleBundle
    colors::Vector{RGBAf}
    sizes::Vector{Float64}
    markers::Vector{Any}
    strokecolors::Vector{RGBAf}
    linestyles::Vector{Any}
    results::Dict{Symbol,ColorResult}
end

"""
    _collapse(v)

Return the single element if `v` is uniform, otherwise `v` itself.

Two reasons. Makie takes some attributes only as uniforms — `strokewidth` on a scatter is
rejected outright as a vector — and GraphMakie falls back to one `lines` plot per edge as
soon as `edge_linestyle` is non-scalar (`split_edgeplots`), which is wasted work when every
edge shares a style.
"""
_collapse(v::AbstractVector) = isempty(v) ? v : (all(x -> x == first(v), v) ? first(v) : v)

"Fetch `field` for the given indices of a vertex or edge column."
function _values(net, kind::Symbol, field, idx)
    field === nothing && return fill(missing, length(idx))
    col = kind === :node ? vertex_column(net, field) : edge_column(net, field)
    return col[idx]
end

"""
    _style(net, kind, defaults, components, schemes) -> StyleBundle

Resolve every styling attribute for one side of the graph into per-index vectors.

Components are resolved one type at a time, because the palette slot, the colour mode and
the colour range are all per-component: that is what lets buses be coloured by voltage on a
viridis ramp while branches are coloured categorically, inside a single `graphplot`.
"""
function _style(net::PowerNetwork, kind::Symbol, defaults, components, schemes)
    refs = kind === :node ? net.vertices : net.edges
    n = length(refs)

    colors = Vector{RGBAf}(undef, n)
    sizes = Vector{Float64}(undef, n)
    markers = Vector{Any}(undef, n)
    strokecolors = Vector{RGBAf}(undef, n)
    linestyles = Vector{Any}(undef, n)
    results = Dict{Symbol,ColorResult}()

    for comp in unique(r.component for r in refs)
        idx = findall(r -> r.component === comp, refs)
        base = comp === CONNECTOR ? defaults.connector : defaults.main
        spec = merge(base, component_spec(components, comp))

        colorfield = get(spec, :color, nothing) isa Field ? spec.color.name : nothing
        result = resolve_color(
            _values(net, kind, colorfield, idx), spec, get(schemes, comp, :grays),
        )
        colors[idx] = result.colors
        comp === CONNECTOR || (results[comp] = result)

        sizekey = kind === :node ? :size : :width
        sizereq = get(spec, sizekey, nothing)
        sizefield = sizereq isa Field ? sizereq.name : nothing
        sizes[idx] = resolve_numeric(
            _values(net, kind, sizefield, idx), sizereq, get(spec, :_default_size, 1.0),
        )

        markers[idx] .= Ref(get(spec, :marker, :circle))
        linestyles[idx] .= Ref(get(spec, :linestyle, :solid))
        strokecolors[idx] .= Ref(RGBAf(to_color(get(spec, :strokecolor, :black))))
    end

    return StyleBundle(colors, sizes, markers, strokecolors, linestyles, results)
end

function Makie.plot!(p::PowerPlot)
    # Vertex positions. This is the one genuinely reactive quantity: the interaction layer
    # re-runs the layout by writing to `layout`/`pin`, and everything downstream follows.
    map!(p.attributes, [:network, :layout, :pin], :node_pos) do net, layout, pin
        return layout_positions(_as_network(net); layout = layout, pin = pin)
    end

    map!(p.attributes, [:network, :parallel_spread], :curve_distances) do net, spread
        return parallel_offsets(_as_network(net).graph; spread = spread)
    end

    node_inputs = [
        :network, :components, :node_color, :node_size, :node_marker, :node_strokewidth,
        :node_strokecolor, :node_colormap, :node_colorrange, :node_colormode,
        :node_palette,
    ]
    map!(p.attributes, node_inputs, :node_style) do net, components, color, size, marker,
        strokewidth, strokecolor, colormap, colorrange, colormode, palette
        network = _as_network(net)
        main = (;
            color, size, marker, strokewidth, strokecolor, colormap, colorrange,
            colormode, palette, _default_size = 12.0,
        )
        return _style(
            network, :node, (main = main, connector = main), components,
            assign_schemes(network),
        )
    end

    edge_inputs = [
        :network, :components, :edge_color, :edge_width, :edge_linestyle, :edge_colormap,
        :edge_colorrange, :edge_colormode, :edge_palette, :connector_color,
        :connector_width, :connector_linestyle,
    ]
    map!(p.attributes, edge_inputs, :edge_style) do net, components, color, width,
        linestyle, colormap, colorrange, colormode, palette, ccolor, cwidth, clinestyle
        network = _as_network(net)
        main = (;
            color, width, linestyle, colormap, colorrange, colormode, palette,
            _default_size = 2.0,
        )
        connector = (;
            color = ccolor === nothing ? CONNECTOR_COLOR : ccolor,
            width = cwidth,
            linestyle = clinestyle,
            _default_size = 1.0,
        )
        return _style(
            network, :edge, (main = main, connector = connector), components,
            assign_schemes(network),
        )
    end

    map!(x -> x.colors, p.attributes, :node_style, :gp_node_color)
    map!(x -> x.sizes, p.attributes, :node_style, :gp_node_size)
    map!(x -> _collapse(x.markers), p.attributes, :node_style, :gp_node_marker)
    map!(x -> _collapse(x.strokecolors), p.attributes, :node_style, :gp_node_strokecolor)
    map!(x -> x.colors, p.attributes, :edge_style, :gp_edge_color)
    map!(x -> x.sizes, p.attributes, :edge_style, :gp_edge_width)
    map!(x -> _collapse(x.linestyles), p.attributes, :edge_style, :gp_edge_linestyle)

    graph = _as_network(p.network[]).graph
    graphplot!(
        p,
        graph;
        layout = p.node_pos,
        node_color = p.gp_node_color,
        node_size = p.gp_node_size,
        node_marker = p.gp_node_marker,
        # Makie takes scatter stroke width as a uniform, so this stays plot-level rather
        # than being resolved per component.
        node_strokewidth = p.node_strokewidth,
        node_strokecolor = p.gp_node_strokecolor,
        edge_color = p.gp_edge_color,
        edge_width = p.gp_edge_width,
        edge_linestyle = p.gp_edge_linestyle,
        curve_distance = p.curve_distances,
        # `automatic` bows only antiparallel edges of a *directed* graph, which would leave
        # parallel circuits drawn exactly on top of each other.
        curve_distance_usage = true,
        p.graphplot_attr[]...,
    )
    return p
end
