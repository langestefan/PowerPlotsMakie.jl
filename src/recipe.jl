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

# Sizing

Sizes are *design units*, not pixels. `autoscale` multiplies all of them — node sizes, edge
and connector widths, flow arrows, stroke widths — by a single factor, so a plot keeps its
proportions while its absolute size follows the figure it is drawn into and the density of
the network it is drawing. A five-bus case gets big buses, a five-hundred-bus case small
ones, and doubling the figure doubles everything in it.

Two things deliberately leave it alone. Zoom: nodes stay put in pixels as the camera moves,
so zooming into a crowded corner separates them instead of magnifying them. And the layout:
dragging a bus or re-running the layout rearranges the network without resizing anything in
it, so the plot does not change weight under the interaction keys. The factor is remeasured
when the network changes, when the figure is resized, and when `autoscale` is set.

`autoscale = false` turns it off and leaves every size in raw pixels; a number, such as
`autoscale = 1.4`, scales the whole plot by hand. `autoscale_min` is the smallest node
diameter, in pixels, the automatic factor will go down to: on a dense geographic network
the measured spacing alone would leave markers too small to tell apart. See [`autoscale_factor`](@ref) for how
the automatic factor is arrived at.

# Flow arrows

`flow = true` draws an arrow along every branch that has a `pf` value — which a PowerModels
case has once a solution has been merged into it — pointing the way the power goes and
sized by how much of it there is. `flow = Field(:qf)` follows a different field. See
[`flow_arrows`](@ref) for the geometry, and `flow_color`, `flow_marker` and `flow_size` for
the styling.

# Routes

A branch whose data carries a route — [`edge_coordinates`](@ref), which for PowerModels is
a `coordinates` list of `[x, y]` pairs on the branch — is drawn along it instead of as a
straight line, from its from-bus through the route's points to its to-bus. `routes = :auto`
does this only when every bus has coordinates of its own, since a route means nothing on a
computed layout; `true` and `false` force it either way. Parallel circuits with routes are
not fanned apart: two circuits sharing a corridor are drawn on top of each other, as they
run. `route_radius` rounds the corners, in data units; `0` draws straight segments and
`nothing` a smooth spline through the points.

Changing `routes` or `route_radius` on a plot that already exists takes effect at the next
change of the node positions: GraphMakie redraws its edges when the positions or curves
change, but not when only `waypoints` or `waypoint_radius` does.

# Groups

`group = Field(:base_kv)` sorts the network into groups by a node field — voltage level,
zone, owner — and colours every bus, branch and injection by its group, so one plot shows a
multi-level network the way a map does. Branches and injections inherit the group of the
buses they hang off; a transformer between two groups belongs to neither and keeps its
component colour. `group_palette` sets the colours: a `Dict` from value to colour such as
`Dict(380 => :firebrick, 150 => :steelblue)`, a vector, or a colormap name. A component given
a colour of its own in `components` or a role-level attribute is not recoloured.

`hidden_groups` lists groups not to draw; edges into a hidden group are hidden with it.
[`powerlegend!`](@ref) gives each group an entry that toggles it on click. See
[`network_groups`](@ref) for the rules.

# Boundary nodes

Buses a backend reports through [`boundary_nodes`](@ref) — where the modelled network meets
the equivalent of the grid around it — are drawn with `boundary_marker`, `boundary_color`
and `boundary_scale` times their size, and get their own legend entry. `boundary = false`
draws them like any other bus.

# Hover

With Makie's `DataInspector` attached (`DataInspector(fig)`), hovering a bus or branch shows
which component it is, followed by the fields named in `hover_fields`, e.g.
`hover_fields = [:name, :base_kv, :vm]`. [`component_at`](@ref) answers the same question
for hand-rolled readouts.

`component_defaults` takes the same shape and sits underneath `components`, which is where
a theme puts its per-component styling — see [`academic_theme`](@ref). Setting `components`
overrides it component by component rather than wholesale.

Note that both must be a `Dict` (or a vector of pairs). A NamedTuple cannot be used here:
Makie converts NamedTuple-valued attributes to `Attributes` and the nested per-component
settings are lost in the process.
"""
@recipe(PowerPlot, network) do scene
    Attributes(
        # --- topology and geometry -----------------------------------------------------
        layout = :auto,
        pin = nothing,
        parallel_spread = 0.2,
        routes = :auto,
        route_radius = 0.0,
        components = Dict{Symbol,Any}(),
        component_defaults = Dict{Symbol,Any}(),

        # --- groups --------------------------------------------------------------------
        group = nothing,
        group_palette = nothing,
        hidden_groups = Any[],

        # --- boundary nodes ------------------------------------------------------------
        boundary = true,
        boundary_marker = :diamond,
        boundary_color = :black,
        boundary_scale = 1.2,

        # --- hover ---------------------------------------------------------------------
        hover_fields = Symbol[],

        # --- sizing --------------------------------------------------------------------
        autoscale = :auto,
        autoscale_min = MIN_NODE_PIXELS,

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

        # --- flow arrows ---------------------------------------------------------------
        flow = false,
        flow_color = :black,
        flow_marker = :utriangle,
        flow_size = (6.0, 18.0),

        # --- selection highlight -------------------------------------------------------
        selection = Int[],
        selection_color = :dodgerblue,
        selection_strokewidth = 2.5,
        selection_scale = 1.7,

        # --- pinned marker -------------------------------------------------------------
        pinned = Int[],
        pinned_color = :black,
        pinned_strokecolor = :white,
        pinned_strokewidth = 1.0,
        pinned_scale = 0.4,

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

"A style bundle's sizes in pixels — see [`autoscale_factor`](@ref)."
_scaled_sizes(bundle::StyleBundle, scale::Real) = bundle.sizes .* scale

"Fetch `field` for the given indices of a vertex or edge column."
function _values(net, kind::Symbol, field, idx)
    field === nothing && return fill(missing, length(idx))
    col = kind === :node ? vertex_column(net, field) : edge_column(net, field)
    return col[idx]
end

"""
    _style(net, kind, defaults, presets, components, schemes; groups) -> StyleBundle

Resolve every styling attribute for one side of the graph into per-index vectors.

Components are resolved one type at a time, because the palette slot, the colour mode and
the colour range are all per-component: that is what lets buses be coloured by voltage on a
viridis ramp while branches are coloured categorically, inside a single `graphplot`.

Three layers, each overriding the one before: the role-level attributes, then `presets`
(the `component_defaults` a theme supplies), then the caller's own `components`. The middle
layer exists so that a theme can say what a generator looks like without a caller who
restyles the buses silently discarding it.

A component given no colour at any layer is coloured by its group when the plot is grouped
(see [`network_groups`](@ref)), and its [`ColorResult`](@ref) becomes `:group`: the group
key in the legend then describes it, and the component key leaves it out. Members of the
component that belong to no group keep the component's own colour.
"""
function _style(
    net::PowerNetwork,
    kind::Symbol,
    defaults,
    presets,
    components,
    schemes;
    groups::NetworkGroups = NetworkGroups(net),
)
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
        spec = merge(base, component_spec(presets, comp), component_spec(components, comp))

        colorfield = get(spec, :color, nothing) isa Field ? spec.color.name : nothing
        result = resolve_color(
            _values(net, kind, colorfield, idx),
            spec,
            get(schemes, comp, :grays),
        )
        colors[idx] = result.colors
        if groups.field !== nothing && get(spec, :color, nothing) === nothing
            keys_ = kind === :node ? groups.vertex : groups.edge
            grouped = filter(i -> !ismissing(keys_[i]), idx)
            for i in grouped
                colors[i] = groups.colors[keys_[i]]
            end
            if length(grouped) == length(idx)
                result = ColorResult(
                    colors[idx],
                    :group,
                    groups.field,
                    [],
                    RGBAf[],
                    result.colormap,
                    (0.0, 1.0),
                )
            end
        end
        comp === CONNECTOR || (results[comp] = result)

        sizekey = kind === :node ? :size : :width
        sizereq = get(spec, sizekey, nothing)
        sizefield = sizereq isa Field ? sizereq.name : nothing
        sizes[idx] = resolve_numeric(
            _values(net, kind, sizefield, idx),
            sizereq,
            get(spec, :_default_size, 1.0),
        )

        markers[idx] .= Ref(get(spec, :marker, :circle))
        linestyles[idx] .= Ref(get(spec, :linestyle, :solid))
        strokecolors[idx] .= Ref(RGBAf(to_color(get(spec, :strokecolor, :black))))
    end

    return StyleBundle(colors, sizes, markers, strokecolors, linestyles, results)
end

"""
    _mark_boundary!(bundle, indices, color, marker, scale) -> bundle

Restyle the boundary vertices: their own marker and colour, and `scale` times their size,
so that the edge of the model stands out from the buses inside it whatever those are
coloured by.
"""
function _mark_boundary!(bundle::StyleBundle, indices, color, marker, scale)
    c = RGBAf(to_color(color))
    for i in indices
        bundle.colors[i] = c
        bundle.markers[i] = marker
        bundle.sizes[i] *= scale
    end
    return bundle
end

"Vertex indices of the boundary nodes of `net`; see [`boundary_nodes`](@ref)."
function boundary_indices(net::PowerNetwork)
    ids = Set(string.(boundary_nodes(net.data)))
    isempty(ids) && return Int[]
    return [
        i for
        (i, r) in enumerate(net.vertices) if net.vertex_roles[i] isa NodeRole && r.id in ids
    ]
end

"`colors` with the alpha of every index in `mask` set to zero."
function _hide(colors::AbstractVector{RGBAf}, mask::AbstractVector{Bool})
    any(mask) || return colors
    out = copy(colors)
    for i in eachindex(out)
        mask[i] && (out[i] = RGBAf(out[i].r, out[i].g, out[i].b, 0))
    end
    return out
end

"The drawing area in pixels, or a zero size when the plot has no scene to ask."
_viewport_size(::Nothing) = Vec2f(0, 0)
_viewport_size(scene::Makie.Scene) = Vec2f(widths(scene.viewport[]))

function Makie.plot!(p::PowerPlot)
    # Vertex positions. This is the one genuinely reactive quantity: the interaction layer
    # re-runs the layout by writing to `layout`/`pin`, and everything downstream follows.
    map!(p.attributes, [:network, :layout, :pin], :node_pos) do net, layout, pin
        return layout_positions(_as_network(net); layout = layout, pin = pin)
    end

    # How big everything is drawn. The viewport belongs to the scene rather than to the
    # plot, so it is fed into the compute graph by hand and kept current for as long as the
    # plot lives — that is what makes sizes follow a resized window or a larger `Figure`.
    scene = Makie.parent_scene(p)
    Makie.ComputePipeline.add_input!(p.attributes, :viewport_size, _viewport_size(scene))
    if scene !== nothing
        on(p, scene.viewport) do viewport
            p.viewport_size = Vec2f(widths(viewport))
            return
        end
    end

    # The factor is measured from the positions, but it deliberately does *not* list them
    # as an input. Node sizes must hold still while the layout moves: re-running the layout
    # or dragging a bus is a change of arrangement, not a change of what is being drawn,
    # and markers that jump when the user presses the re-layout key read as a bug. So the
    # positions are read here rather than depended on, and the factor is remeasured only
    # when the network, the viewport or `autoscale` itself changes.
    map!(
        p.attributes,
        [:autoscale, :autoscale_min, :network, :viewport_size],
        :autoscale_factor,
    ) do request, min_pixels, _, viewport
        return resolve_autoscale(request, p.node_pos[], viewport; min_pixels)
    end

    # Groups, and what hiding some of them hides.
    map!(p.attributes, [:network, :group, :group_palette], :groups) do net, group, palette
        return network_groups(_as_network(net), group; palette)
    end
    map!(
        hidden_masks,
        p.attributes,
        [:groups, :hidden_groups],
        [:vertex_hidden, :edge_hidden],
    )

    map!(p.attributes, [:network, :parallel_spread], :curve_distances) do net, spread
        return parallel_offsets(_as_network(net).graph; spread = spread)
    end

    # Routes are looked up once per network; laying them between the buses follows the
    # positions, so a dragged bus keeps its lines attached.
    map!(p.attributes, [:network, :routes], :edge_routes) do net, routes
        network = _as_network(net)
        return _use_routes(routes, network) ? edge_routes(network) :
               Dict{Int,Vector{Point2f}}()
    end
    map!(
        p.attributes,
        [:network, :edge_routes, :node_pos],
        :edge_waypoints,
    ) do net, routes, pos
        return route_waypoints(_as_network(net), routes, pos)
    end

    node_inputs = [
        :network,
        :components,
        :component_defaults,
        :node_color,
        :node_size,
        :node_marker,
        :node_strokewidth,
        :node_strokecolor,
        :node_colormap,
        :node_colorrange,
        :node_colormode,
        :node_palette,
        :groups,
        :boundary,
        :boundary_marker,
        :boundary_color,
        :boundary_scale,
    ]
    map!(
        p.attributes,
        node_inputs,
        :node_style,
    ) do net,
    components,
    presets,
    color,
    size,
    marker,
    strokewidth,
    strokecolor,
    colormap,
    colorrange,
    colormode,
    palette,
    groups,
    boundary,
    bmarker,
    bcolor,
    bscale
        network = _as_network(net)
        main = (;
            color,
            size,
            marker,
            strokewidth,
            strokecolor,
            colormap,
            colorrange,
            colormode,
            palette,
            _default_size = 12.0,
        )
        bundle = _style(
            network,
            :node,
            (main = main, connector = main),
            presets,
            components,
            assign_schemes(network);
            groups,
        )
        boundary &&
            _mark_boundary!(bundle, boundary_indices(network), bcolor, bmarker, bscale)
        return bundle
    end

    edge_inputs = [
        :network,
        :components,
        :component_defaults,
        :edge_color,
        :edge_width,
        :edge_linestyle,
        :edge_colormap,
        :edge_colorrange,
        :edge_colormode,
        :edge_palette,
        :connector_color,
        :connector_width,
        :connector_linestyle,
        :groups,
    ]
    map!(
        p.attributes,
        edge_inputs,
        :edge_style,
    ) do net,
    components,
    presets,
    color,
    width,
    linestyle,
    colormap,
    colorrange,
    colormode,
    palette,
    ccolor,
    cwidth,
    clinestyle,
    groups
        network = _as_network(net)
        main = (;
            color,
            width,
            linestyle,
            colormap,
            colorrange,
            colormode,
            palette,
            _default_size = 2.0,
        )
        connector = (;
            color = ccolor === nothing ? CONNECTOR_COLOR : ccolor,
            width = cwidth,
            linestyle = clinestyle,
            _default_size = 1.0,
        )
        return _style(
            network,
            :edge,
            (main = main, connector = connector),
            presets,
            components,
            assign_schemes(network);
            groups,
        )
    end

    # Hidden groups are drawn fully transparent rather than removed, so the vertex and edge
    # numbering — which everything else indexes by — stays the same while they are hidden.
    map!(p.attributes, [:node_style, :vertex_hidden], :gp_node_color) do style, hidden
        return _hide(style.colors, hidden)
    end
    map!(x -> _collapse(x.markers), p.attributes, :node_style, :gp_node_marker)
    map!(p.attributes, [:node_style, :vertex_hidden], :gp_node_strokecolor) do style, hidden
        # Always one colour per node, never collapsed to a uniform: the compute graph fixes
        # an output's type on first use, and hiding a group turns a uniform ring into a
        # per-node one.
        return _hide(style.strokecolors, hidden)
    end
    map!(p.attributes, [:edge_style, :edge_hidden], :gp_edge_color) do style, hidden
        return _hide(style.colors, hidden)
    end
    map!(x -> _collapse(x.linestyles), p.attributes, :edge_style, :gp_edge_linestyle)

    # Design units become pixels here, and nowhere else. Scaling at the very last step keeps
    # the style resolution — which is the expensive part — independent of the layout, so a
    # drag re-scales the sizes without re-resolving every component's colour.
    map!(_scaled_sizes, p.attributes, [:node_style, :autoscale_factor], :gp_node_size)
    map!(_scaled_sizes, p.attributes, [:edge_style, :autoscale_factor], :gp_edge_width)
    map!(*, p.attributes, [:node_strokewidth, :autoscale_factor], :gp_node_strokewidth)

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
        node_strokewidth = p.gp_node_strokewidth,
        edge_color = p.gp_edge_color,
        edge_width = p.gp_edge_width,
        edge_linestyle = p.gp_edge_linestyle,
        curve_distance = p.curve_distances,
        # `automatic` bows only antiparallel edges of a *directed* graph, which would leave
        # parallel circuits drawn exactly on top of each other.
        curve_distance_usage = true,
        # A route overrules the curve: GraphMakie draws an edge with waypoints through them.
        waypoints = p.edge_waypoints,
        waypoint_radius = p.route_radius,
        visible = p.visible,
        p.graphplot_attr[]...,
    )
    _forward_visibility!(p)
    _link_node_strokecolor!(p)
    _attach_hover!(p)

    # Flow arrows, drawn over the branches they describe. Nothing is computed unless
    # `flow` asks for it, so a plot of a case with no solution pays nothing.
    map!(
        p.attributes,
        [
            :network,
            :node_pos,
            :curve_distances,
            :edge_waypoints,
            :edge_hidden,
            :flow,
            :flow_size,
            :autoscale_factor,
        ],
        :flow_arrows,
    ) do net, pos, curves, waypoints, hidden, flow, sizerange, scale
        scaled = (first(sizerange) * scale, last(sizerange) * scale)
        return flow_arrows(_as_network(net), pos, curves, flow, scaled; waypoints, hidden)
    end
    map!(a -> a.positions, p.attributes, :flow_arrows, :flow_pos)
    map!(a -> a.rotations, p.attributes, :flow_arrows, :flow_rotation)
    map!(a -> a.sizes, p.attributes, :flow_arrows, :flow_markersize)
    scatter!(
        p,
        p.flow_pos;
        rotation = p.flow_rotation,
        markersize = p.flow_markersize,
        marker = p.flow_marker,
        color = p.flow_color,
        visible = p.visible,
    )

    # Selection highlight: a ring drawn over each selected vertex.
    #
    # A ring rather than a thicker node stroke, because Makie takes scatter `strokewidth`
    # as a uniform — it cannot vary per point, so the selected nodes could not be given a
    # heavier outline than the rest within the same scatter. An overlay sidesteps that and
    # keeps the underlying node styling untouched.
    map!(p.attributes, [:node_pos, :selection], :selection_pos) do pos, sel
        return Point2f[pos[i] for i in _selected_indices(sel, length(pos))]
    end
    map!(
        p.attributes,
        [:gp_node_size, :selection, :selection_scale],
        :selection_markersize,
    ) do sizes, sel, scale
        idx = _selected_indices(sel, length(sizes))
        return Float64[sizes[i] * scale for i in idx]
    end
    map!(
        *,
        p.attributes,
        [:selection_strokewidth, :autoscale_factor],
        :gp_selection_strokewidth,
    )
    scatter!(
        p,
        p.selection_pos;
        markersize = p.selection_markersize,
        color = RGBAf(0, 0, 0, 0),
        strokecolor = p.selection_color,
        strokewidth = p.gp_selection_strokewidth,
        visible = p.visible,
    )

    # Pinned marker: a small dot at the centre of every vertex the layout may not move.
    # Dark with a light outline so it stays legible against both ends of a colour ramp.
    map!(p.attributes, [:node_pos, :pinned], :pinned_pos) do pos, pinned
        return Point2f[pos[i] for i in _selected_indices(pinned, length(pos))]
    end
    map!(
        p.attributes,
        [:gp_node_size, :pinned, :pinned_scale],
        :pinned_markersize,
    ) do sizes, pinned, scale
        idx = _selected_indices(pinned, length(sizes))
        return Float64[sizes[i] * scale for i in idx]
    end
    map!(*, p.attributes, [:pinned_strokewidth, :autoscale_factor], :gp_pinned_strokewidth)
    scatter!(
        p,
        p.pinned_pos;
        markersize = p.pinned_markersize,
        color = p.pinned_color,
        strokecolor = p.pinned_strokecolor,
        strokewidth = p.gp_pinned_strokewidth,
        visible = p.visible,
    )
    return p
end

"""
Selected indices in a stable order, dropping any that are out of range.

`selection` may be a `Set`, whose iteration order is unspecified; positions and marker
sizes are built in two separate computations and would otherwise not line up.
"""
_selected_indices(selection, n) = sort!([Int(i) for i in selection if 1 <= i <= n])

"""
    _forward_visibility!(p)

Make hiding a `powerplot` hide everything it draws.

The recipe hands `visible` to each plot it creates, but GraphMakie does not pass it on to
the scatter and lines inside its `graphplot`, so a `powerplot` toggled off — by a legend
entry, say — would keep drawing its network. The setting is copied down by hand to every
plot under the `graphplot` that holds its own.
"""
function _forward_visibility!(p::PowerPlot)
    gp = graph_plot(p)
    on(p, Makie.ComputePipeline.get_observable!(p.visible)) do v
        foreach(c -> _set_visible!(c, v), gp.plots)
        return
    end
    return p
end

function _set_visible!(plot, v)
    haskey(plot.attributes.inputs, :visible) && plot.visible[] != v && (plot.visible = v)
    foreach(c -> _set_visible!(c, v), plot.plots)
    return
end

"""
    _link_node_strokecolor!(p)

Keep the node scatter's stroke colour equal to the resolved `gp_node_strokecolor`.

GraphMakie's `graphplot` has no `node_strokecolor`: a keyword of that name is dropped, and
its scatter draws Makie's default black ring whatever the plot asked for. So the colour is
written onto the scatter directly, and again whenever it changes — which it does when a
group is hidden, since a hidden node's ring has to go with it.
"""
function _link_node_strokecolor!(p::PowerPlot)
    nodes = GraphMakie.get_node_plot(graph_plot(p))
    nodes.strokecolor = p.gp_node_strokecolor[]
    on(p, Makie.ComputePipeline.get_observable!(p.gp_node_strokecolor)) do c
        nodes.strokecolor = c
        return
    end
    return p
end
