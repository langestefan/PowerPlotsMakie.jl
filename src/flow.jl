"""
    FlowArrows

Where to draw power-flow arrows, which way they point and how big they are.

One entry per drawn arrow, not per edge: branches with no flow value get none.
"""
struct FlowArrows
    positions::Vector{Point2f}
    rotations::Vector{Float32}
    sizes::Vector{Float64}
end

FlowArrows() = FlowArrows(Point2f[], Float32[], Float64[])

Base.length(a::FlowArrows) = length(a.positions)
Base.isempty(a::FlowArrows) = isempty(a.positions)

"""
    flow_field(flow) -> Union{Nothing,Symbol}

The data field a `flow` setting asks for.

`false` means no arrows, `true` means `:pf` — the active power leaving the from-bus, which
is what PowerModels writes back into a branch when a solution is merged into the network —
and a [`Field`](@ref) names the field outright.
"""
flow_field(flow::Bool) = flow ? :pf : nothing
flow_field(flow::Field) = flow.name
flow_field(flow::Symbol) = flow
flow_field(::Nothing) = nothing
flow_field(flow) = throw(
    ArgumentError(
        "flow = $(repr(flow)) is not understood; expected true, false or Field(:name)",
    ),
)

"""
    flow_arrows(net, positions, curve_distances, flow, sizerange) -> FlowArrows

Place an arrow at the midpoint of every branch carrying a flow value.

The arrow points from the from-bus to the to-bus where the value is positive and the other
way where it is negative, which is the sign convention PowerModels uses: `pf` is measured
leaving the from-bus. Magnitude is taken as `abs`, scaled linearly across `sizerange` over
the branches that have a value, so the arrows are comparable within one plot and never
comparable between two.

The arrow sits on the drawn path, not on the straight line between the buses: parallel
circuits are bowed apart, and an arrow at the chord midpoint would float off its own
circuit and onto its neighbour. Connectors never carry arrows — they are plumbing, and a
generator does not have a direction along its stub.
"""
function flow_arrows(
    net::PowerNetwork,
    positions::AbstractVector,
    curve_distances,
    flow,
    sizerange,
)
    field = flow_field(flow)
    field === nothing && return FlowArrows()

    idx = edge_indices(net, EdgeRole())
    isempty(idx) && return FlowArrows()
    values = edge_column(net, field)[idx]

    magnitudes = [v isa Real ? abs(Float64(v)) : NaN for v in values]
    finite = filter(isfinite, magnitudes)
    isempty(finite) && return FlowArrows()
    lo, hi = minimum(finite), maximum(finite)
    small, big = Float64(first(sizerange)), Float64(last(sizerange))

    edgelist = net.graph.edges
    out = FlowArrows()
    for (k, j) in enumerate(idx)
        m = magnitudes[k]
        isfinite(m) || continue
        e = edgelist[j]
        p1, p2 = Point2f(positions[src(e)]), Point2f(positions[dst(e)])
        # A branch whose ends coincide has no direction to point along.
        p1 ≈ p2 && continue

        d = curve_distances === nothing ? 0.0 : Float64(_at(curve_distances, j))
        point, tangent = _path_midpoint(p1, p2, d)
        angle = atan(tangent[2], tangent[1])
        values[k] < 0 && (angle += Float32(π))

        push!(out.positions, point)
        # `:utriangle` points at +y, a quarter turn ahead of an angle measured from +x.
        push!(out.rotations, Float32(angle - π / 2))
        push!(out.sizes, lo == hi ? big : small + (big - small) * (m - lo) / (hi - lo))
    end
    return out
end

_at(v::AbstractVector, i) = v[i]
_at(x, _) = x

"""
    _path_midpoint(p1, p2, curve_distance) -> (point, tangent)

The halfway point of the edge as GraphMakie actually draws it, and the direction of travel
there.

Straight edges are the easy case. A bowed edge is the cubic Bézier from
`GraphMakie.curved_path`, so ask GraphMakie for the curve rather than approximating it —
that way the arrow cannot drift off the line it belongs to if the curve formula changes.
"""
function _path_midpoint(p1::Point2f, p2::Point2f, curve_distance::Real)
    if iszero(curve_distance)
        return (p1 + p2) / 2, p2 - p1
    end
    path = GraphMakie.curved_path(p1, p2, curve_distance)
    return GraphMakie.interpolate(path, 0.5), GraphMakie.tangent(path, 0.5)
end
