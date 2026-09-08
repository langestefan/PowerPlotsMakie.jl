"""
    fixed_positions(net) -> Dict{Int,Point2f}

Coordinates already carried by the data, keyed by vertex index.

Networks with geographic or hand-authored positions expose them through
[`node_coordinates`](@ref). Only node components are consulted; injections are placed by
the layout around whatever bus they hang off.
"""
function fixed_positions(net::PowerNetwork)
    out = Dict{Int,Point2f}()
    for (i, ref) in enumerate(net.vertices)
        net.vertex_roles[i] isa NodeRole || continue
        p = node_coordinates(net.data, ref.component, ref.id)
        p === nothing || (out[i] = Point2f(p))
    end
    return out
end

"""
    layout_positions(net; layout = :auto, pin = nothing) -> Vector{Point2f}

Position every vertex of `net`.

`layout` accepts:

  - `:auto` — pick an algorithm for this network: [`RadialTree`](@ref) when the buses and
    branches form a forest ([`isradial`](@ref)), `Stress` otherwise. Data-supplied
    coordinates or an explicit `pin` force `Stress`, since it is the choice that can honour
    them;
  - `:radial` — a [`RadialTree`](@ref) rooted at the reference buses, whether or not the
    network is a forest;
  - `:stress` — stress majorization, honouring `pin`;
  - a NetworkLayout algorithm, e.g. `Stress()` or `Spring(; C = 3)`;
  - a vector of points, one per vertex, used as given;
  - any callable `graph -> positions`.

`pin` names vertices that must not move, as a collection of indices or a `Dict` of
`index => Bool`. Vertices whose coordinates come from the data are pinned automatically,
which is how PowerPlots.jl's `fixed = true` behaves — the difference being that here the
pinning is expressed through NetworkLayout's own `pin` support rather than a bespoke
layout, so it works with `Spring`, `Stress` and `SFDP` alike.
"""
function layout_positions(net::PowerNetwork; layout = :auto, pin = nothing)
    n = nv(net)

    if layout isa AbstractVector
        length(layout) == n || throw(
            ArgumentError(
                "layout has $(length(layout)) positions but the network has $n vertices",
            ),
        )
        return Point2f[Point2f(p) for p in layout]
    end

    fixed = fixed_positions(net)
    pinned = _pin_dict(pin, fixed, n)
    algorithm = _layout_algorithm(net, layout, fixed, pinned)
    return Point2f[Point2f(p) for p in algorithm(net.graph)]
end

"Normalise the many spellings of `pin` into what NetworkLayout wants."
function _pin_dict(pin, fixed::Dict{Int,Point2f}, n::Int)
    out = Dict{Int,Bool}()
    # Data-supplied coordinates are pinned by default; an explicit `pin` can add to them.
    for i in keys(fixed)
        out[i] = true
    end
    pin === nothing && return out
    if pin isa AbstractDict
        for (k, v) in pin
            v === false ? delete!(out, k) : (out[k] = true)
        end
    else
        for i in pin
            1 <= i <= n || throw(ArgumentError("pinned vertex $i is out of range"))
            out[i] = true
        end
    end
    return out
end

function _layout_algorithm(net, layout, fixed, pinned)
    if layout === :auto
        # Coordinates from the data, or vertices the caller wants held, are a layout that
        # already exists in part; only the iterative algorithms can build around one.
        free = isempty(fixed) && isempty(pinned)
        layout = free && isradial(net) ? :radial : :stress
    end

    if layout === :radial
        return radial_tree(net)
    elseif layout === :stress
        return isempty(fixed) && isempty(pinned) ? NetworkLayout.Stress() :
               NetworkLayout.Stress(; initialpos = fixed, pin = pinned)
    elseif layout isa NetworkLayout.AbstractLayout
        # An explicitly constructed algorithm is taken at its word: the caller has already
        # said what it wants, including any initialpos/pin of its own.
        return layout
    elseif layout isa Symbol
        throw(
            ArgumentError(
                "unknown layout $(repr(layout)); expected :auto, :radial, :stress or an algorithm",
            ),
        )
    end
    return layout
end
