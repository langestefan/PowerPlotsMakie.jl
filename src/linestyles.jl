"""
    LinestyleResult

How one component's line style was resolved from a data field: the distinct values found,
in order, and the style each is drawn in. Kept with the style bundle so that a legend can
say what the dashes mean.
"""
struct LinestyleResult
    field::Symbol
    values::Vector{Any}
    styles::Vector{Any}
end

"Styles handed out in turn to the values of a field when no mapping is given."
const LINESTYLE_CYCLE = Any[:solid, :dash, :dot, :dashdot, :dashdotdot]

"""
    resolve_linestyles(values, field, request) -> (; styles, segments, result)

Line styles for a component styled by a data field, `linestyle = Field(field)`.

`values` holds the field for each edge. A scalar picks the edge's style. A vector holds one
value per segment of the edge's route — a line that runs overhead, then underground, then
overhead again — and is kept in `segments` for [`route_segments`](@ref) to draw; the edge's
own style is then that of its most common value, which is what it is drawn in where it has
no route to follow. `missing` is drawn solid.

`request` maps values to styles: a `Dict` such as `Dict("cable" => :dash)`, matched as
`isequal` with numbers compared by value, or a vector handed out over the sorted values.
`nothing` draws `false` solid and `true` dashed for a `Bool` field, and otherwise hands out
[`LINESTYLE_CYCLE`](@ref). Values a `Dict` does not name are drawn solid.
"""
function resolve_linestyles(values::AbstractVector, field::Symbol, request)
    distinct = Any[]
    for v in values, x in (v isa AbstractVector ? v : (v,))
        ismissing(x) || any(d -> isequal(d, x), distinct) || push!(distinct, x)
    end
    distinct = sort!(distinct; by = _sortkey)
    styles_ = Any[_linestyle_for(v, k, distinct, request) for (k, v) in enumerate(distinct)]
    lookup(x) = ismissing(x) ? :solid : styles_[findfirst(d -> isequal(d, x), distinct)]

    styles = Vector{Any}(undef, length(values))
    segments = Vector{Union{Nothing,Vector{Any}}}(nothing, length(values))
    for (i, v) in enumerate(values)
        if v isa AbstractVector
            segments[i] = Any[lookup(x) for x in v]
            styles[i] = isempty(v) ? :solid : _most_common(segments[i])
        else
            styles[i] = lookup(v)
        end
    end
    return (; styles, segments, result = LinestyleResult(field, distinct, styles_))
end

_sortkey(v::Real) = (0, Float64(v), "")
_sortkey(v) = (1, 0.0, string(v))

function _linestyle_for(v, k, distinct, request)
    if request isa AbstractDict
        for (key, style) in request
            (isequal(key, v) || (key isa Real && v isa Real && key == v)) && return style
        end
        return :solid
    elseif request isa AbstractVector
        return request[mod1(k, length(request))]
    elseif request === nothing
        all(x -> x isa Bool, distinct) && return v ? :dash : :solid
        return LINESTYLE_CYCLE[mod1(k, length(LINESTYLE_CYCLE))]
    end
    throw(
        ArgumentError(
            "linestyles = $(repr(request)) is not understood; expected a Dict from value " *
            "to line style, a vector of line styles or nothing",
        ),
    )
end

function _most_common(xs)
    best, n = first(xs), 0
    for x in unique(xs)
        c = count(y -> isequal(y, x), xs)
        c > n && ((best, n) = (x, c))
    end
    return best
end

"""
    RouteLayer

The stretches of route drawn in one line style: NaN-separated polylines, with a colour, a
width and the edge index for every point, so that hovering a point finds its branch.
"""
struct RouteLayer
    points::Vector{Point2f}
    colors::Vector{RGBAf}
    widths::Vector{Float32}
    edges::Vector{Int}
end

RouteLayer() = RouteLayer(Point2f[], RGBAf[], Float32[], Int[])

"""
    segment_styled_edges(style, routes) -> BitVector

Which edges are drawn stretch by stretch: those with a style per route segment and a route
with exactly that many segments. A mismatch means the values do not describe the route
being drawn, and the edge is drawn whole in its most common style instead.
"""
function segment_styled_edges(style, routes::AbstractDict)
    out = falses(length(style.linestyles))
    for (j, segs) in style.segment_linestyles
        route = get(routes, j, nothing)
        route === nothing || (out[j] = length(segs) == length(route) - 1)
    end
    return out
end

"""
    route_segments(net, style, routes, mask, positions, colors, widths) -> Dict{Any,RouteLayer}

The edges flagged in `mask`, drawn stretch by stretch: each route from its from-node,
through its points, to its to-node — the path GraphMakie would draw — cut wherever the line
style changes, one [`RouteLayer`](@ref) per style.

The hop from a node to the first point of its route takes the style of the route's first
segment, and likewise at the far end, so a cable that runs into its substation is dashed
all the way in.
"""
function route_segments(
    net::PowerNetwork,
    style,
    routes::AbstractDict,
    mask::AbstractVector{Bool},
    positions::AbstractVector,
    colors::AbstractVector,
    widths::AbstractVector,
)
    layers = Dict{Any,RouteLayer}()
    nan = Point2f(NaN, NaN)
    for j in findall(mask)
        e = net.graph.edges[j]
        p1, p2 = Point2f(positions[src(e)]), Point2f(positions[dst(e)])
        via, segs = _route_path(routes[j], p1, p2, style.segment_linestyles[j])
        path = vcat([p1], via, [p2])
        c, w = colors[j], Float32(widths[j])
        k = 1
        while k <= length(segs)
            # A run of segments in one style is drawn as one polyline, so dashes flow on
            # across the route's vertices instead of restarting at each.
            stop = k
            while stop < length(segs) && isequal(segs[stop+1], segs[k])
                stop += 1
            end
            layer = get!(RouteLayer, layers, segs[k])
            for q = k:(stop+1)
                push!(layer.points, path[q])
            end
            push!(layer.points, nan)
            n = stop - k + 3
            append!(layer.colors, fill(c, n))
            append!(layer.widths, fill(w, n))
            append!(layer.edges, fill(j, n))
            k = stop + 1
        end
    end
    return layers
end
