# ---------------------------------------------------------------------------------------
# Automatic sizing.
#
# Every size in this package — `node_size`, `edge_width`, `flow_size`, the stroke widths —
# is a *design unit* rather than a pixel count. One factor scales all of them at once, so
# the proportions a theme or a caller sets are preserved while the absolute size follows
# the figure being drawn. That is the only way a plot can look the same on a 600 px preview
# and a 1600 px poster without every number being restated.
# ---------------------------------------------------------------------------------------

"The `node_size` a factor of 1 corresponds to, and so the size of an unscaled plot."
const REFERENCE_NODE_SIZE = 12.0

"A node's diameter as a fraction of the distance to its nearest neighbour."
const NODE_SPACING_FRACTION = 0.4

"Ceiling on a node's diameter, as a fraction of the shorter side of the viewport."
const MAX_NODE_VIEWPORT_FRACTION = 0.07

"Floor on a node's diameter. Below a few pixels a marker is not a marker."
const MIN_NODE_PIXELS = 3.0

"Makie's default `Axis` autolimit margin, 5% at each end, as a multiplier on the extent."
const AXIS_LIMIT_MARGIN = 1.1

"How many vertices [`nearest_neighbor_spacing`](@ref) measures."
const SPACING_SAMPLE = 512

function _median(v::Vector{Float64})
    isempty(v) && return 0.0
    s = sort(v)
    n = length(s)
    return isodd(n) ? s[(n+1)÷2] : (s[n÷2] + s[n÷2+1]) / 2
end

"""
    nearest_neighbor_spacing(positions; sample = SPACING_SAMPLE) -> Float64

The median distance from a vertex to its closest neighbour.

This is the length a node has to fit inside. A marker much bigger than it swallows its
neighbours; one much smaller leaves a diagram of bare line segments. The median rather than
the minimum, because one pair of nearly coincident buses should not shrink an entire plot.

At most `sample` vertices are measured — evenly spaced through the vertex list, so the
answer is deterministic — each against every vertex. That bounds the cost at `sample * N`
instead of `N^2`, which matters because this is recomputed while a node is being dragged.

Returns `0.0` for fewer than two vertices, and for a layout whose sampled vertices all sit
on top of one another.
"""
function nearest_neighbor_spacing(positions; sample::Int = SPACING_SAMPLE)
    n = length(positions)
    n < 2 && return 0.0
    stride = max(1, cld(n, sample))
    dists = Float64[]
    for i = 1:stride:n
        p = positions[i]
        px, py = Float64(p[1]), Float64(p[2])
        best = Inf
        for j = 1:n
            j == i && continue
            q = positions[j]
            d = (Float64(q[1]) - px)^2 + (Float64(q[2]) - py)^2
            d < best && (best = d)
        end
        isfinite(best) && push!(dists, sqrt(best))
    end
    return _median(dists)
end

"""
    autoscale_factor(positions, viewport) -> Float64

How much to multiply every design-unit size by, for a layout of `positions` drawn into a
viewport of `viewport` pixels.

Two things set it. **Density:** a node is drawn at [`NODE_SPACING_FRACTION`](@ref) of the
distance to its nearest neighbour, so a five-bus case gets big buses and a five-hundred-bus
case gets small ones, and neither is a wall of overlapping circles. **Figure size:** that
distance is measured in data units and converted with the pixels-per-unit the axis will
use, so doubling the figure doubles every size in it.

Zoom is deliberately *not* one of them. Markers stay put in pixels while the camera moves,
which is what makes zooming into a dense corner of a network useful — the buses separate
instead of growing with it. Neither is the layout: the recipe measures the positions but
does not track them, so dragging a bus or re-running the layout rearranges the network
without resizing anything in it.

The result is clamped: never below [`MIN_NODE_PIXELS`](@ref), never above
[`MAX_NODE_VIEWPORT_FRACTION`](@ref) of the viewport's shorter side. It falls back to `1.0`
— the unscaled look — whenever there is nothing to measure: a single vertex, a viewport of
zero size, or a layout that has collapsed to a point.
"""
function autoscale_factor(positions, viewport)
    length(positions) < 2 && return 1.0
    vw, vh = Float64(viewport[1]), Float64(viewport[2])
    (vw > 0 && vh > 0) || return 1.0

    xlo, xhi = extrema(p[1] for p in positions)
    ylo, yhi = extrema(p[2] for p in positions)
    extent_x, extent_y = Float64(xhi - xlo), Float64(yhi - ylo)

    # The axis fits the whole layout into the viewport, so the tighter of the two directions
    # is the one that decides how much room a node actually has.
    pixels_per_unit = min(
        extent_x > 0 ? vw / (extent_x * AXIS_LIMIT_MARGIN) : Inf,
        extent_y > 0 ? vh / (extent_y * AXIS_LIMIT_MARGIN) : Inf,
    )
    isfinite(pixels_per_unit) || return 1.0

    spacing = nearest_neighbor_spacing(positions)
    spacing > 0 || return 1.0

    ceiling = max(MAX_NODE_VIEWPORT_FRACTION * min(vw, vh), MIN_NODE_PIXELS)
    diameter =
        clamp(NODE_SPACING_FRACTION * spacing * pixels_per_unit, MIN_NODE_PIXELS, ceiling)
    return diameter / REFERENCE_NODE_SIZE
end

"""
    resolve_autoscale(request, positions, viewport) -> Float64

Turn the `autoscale` attribute into the number every size is multiplied by.

`:auto` (or `true`) measures the layout with [`autoscale_factor`](@ref); `false` and
`nothing` switch scaling off, leaving sizes in raw pixels; a number is used as given, so
`autoscale = 1.5` is "half again as big as usual" without touching any other attribute.
"""
resolve_autoscale(request::Bool, positions, viewport) =
    request ? autoscale_factor(positions, viewport) : 1.0
resolve_autoscale(request::Real, _, _) = Float64(request)
resolve_autoscale(::Nothing, _, _) = 1.0
function resolve_autoscale(request, positions, viewport)
    request === :auto && return autoscale_factor(positions, viewport)
    request === :off && return 1.0
    throw(
        ArgumentError(
            "autoscale must be :auto, :off, a Bool or a number, got $(repr(request))",
        ),
    )
end
