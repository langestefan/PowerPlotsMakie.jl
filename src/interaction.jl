"""
    LayoutState

Mutable positions plus the set of vertices the user has pinned.

This is the whole interaction model, and it is deliberately free of Makie: dragging,
pinning and re-running the layout are ordinary functions over this struct, so they can be
tested without a window. CI has no display, so anything that needed one would go untested.
The Makie event handlers below are a thin shell that translates mouse and key events into
these calls.
"""
mutable struct LayoutState
    positions::Vector{Point2f}
    pinned::Set{Int}
    selected::Set{Int}
end

LayoutState(positions::AbstractVector) =
    LayoutState(Point2f[Point2f(p) for p in positions], Set{Int}(), Set{Int}())

Base.copy(s::LayoutState) = LayoutState(copy(s.positions), copy(s.pinned), copy(s.selected))

"""
    drag!(state, idx, position) -> state

Move vertex `idx` to `position` and pin it there.

Dragging implies pinning: having placed a bus by hand, the user does not expect the next
re-layout to move it away again. Use [`unpin!`](@ref) to release it.
"""
function drag!(state::LayoutState, idx::Integer, position)
    checkbounds(state.positions, idx)
    state.positions[idx] = Point2f(position)
    push!(state.pinned, Int(idx))
    return state
end

"Pin vertex `idx` where it currently is."
function pin!(state::LayoutState, idx::Integer)
    checkbounds(state.positions, idx)
    push!(state.pinned, Int(idx))
    return state
end

"Release vertex `idx` so the next re-layout may move it."
function unpin!(state::LayoutState, idx::Integer)
    delete!(state.pinned, Int(idx))
    return state
end

"Release every pinned vertex."
function unpin_all!(state::LayoutState)
    empty!(state.pinned)
    return state
end

"Whether vertex `idx` is currently pinned."
ispinned(state::LayoutState, idx::Integer) = Int(idx) in state.pinned

# ---------------------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------------------

"Whether vertex `idx` is currently selected."
isselected(state::LayoutState, idx::Integer) = Int(idx) in state.selected

"""
    select!(state, indices) -> state

Replace the selection with `indices`.

Selection is independent of pinning: selecting a bus says what the next drag will move, not
where the layout may put it.
"""
function select!(state::LayoutState, indices)
    empty!(state.selected)
    for i in indices
        checkbounds(state.positions, i)
        push!(state.selected, Int(i))
    end
    return state
end

"""
    select_in!(state, rect) -> state

Select every vertex whose position lies inside `rect`, a `Rect2` in data coordinates.

This is the payload of a rubber-band selection, kept separate from the event handling so
that "which vertices does this rectangle cover" can be tested without a window.
"""
function select_in!(state::LayoutState, rect)
    empty!(state.selected)
    for (i, p) in enumerate(state.positions)
        p in rect && push!(state.selected, i)
    end
    return state
end

"Clear the selection."
function deselect_all!(state::LayoutState)
    empty!(state.selected)
    return state
end

"""
    drag_group!(state, origins, delta) -> state

Move every vertex in `origins` to its recorded position plus `delta`, pinning each.

`origins` maps vertex index to where it sat when the drag began. Anchoring to the start
rather than accumulating per-event deltas keeps a long drag from drifting, and keeps the
whole group rigid: every member moves by exactly the same amount.
"""
function drag_group!(state::LayoutState, origins::AbstractDict{Int,Point2f}, delta)
    d = Point2f(delta)
    for (i, origin) in origins
        checkbounds(state.positions, i)
        state.positions[i] = origin + d
        push!(state.pinned, i)
    end
    return state
end

"""
    relayout!(state, graph; algorithm = NetworkLayout.Stress) -> state

Re-run the layout from the current positions, holding pinned vertices exactly where they
are.

`algorithm` is a NetworkLayout *constructor*, not an instance, because the current
positions and pin set have to be baked into it: the algorithm is rebuilt as
`algorithm(; initialpos, pin)`. Only the iterative layouts — `Stress`, `Spring`, `SFDP` —
support pinning; the others silently ignore it, so passing e.g. `Shell` here will move
pinned vertices.

This is the operation that makes layout iterative: drag a few buses into place, re-run, and
the rest of the network settles around them.
"""
function relayout!(state::LayoutState, graph; algorithm = NetworkLayout.Stress)
    initialpos = Dict(i => state.positions[i] for i in eachindex(state.positions))
    pin = Dict(i => true for i in state.pinned)
    positions = algorithm(; initialpos = initialpos, pin = pin)(graph)
    for (i, p) in enumerate(positions)
        state.positions[i] = Point2f(p)
    end
    return state
end

# ---------------------------------------------------------------------------------------
# Makie wiring
#
# GraphMakie's own handlers cannot be used here. `GraphMakie.registration_setup!` locates
# its target with `filter(p -> p isa GraphPlot, parent.scene.plots)`, which searches only
# top-level scene plots; our GraphPlot is nested inside the PowerPlot recipe, so that
# filter finds nothing and indexing it throws. Makie's `register_interaction!`,
# `registration_setup!` and `process_interaction` are generic hooks with no-op defaults,
# so defining our own interaction types is both possible and free of type piracy.
# ---------------------------------------------------------------------------------------

"The GraphMakie plot nested inside a `powerplot`."
function graph_plot(p)
    for child in p.plots
        child isa GraphMakie.GraphPlot && return child
    end
    throw(ArgumentError("this plot contains no GraphPlot"))
end

"""
    NetworkInteraction

Drag-and-pin interaction for a `powerplot`.

Holds the [`LayoutState`](@ref) and the plot it drives. Dragging writes the updated
positions straight into the plot's `layout` attribute, which the recipe already treats as
"use these positions verbatim", so no special path is needed to display a hand-placed
layout.
"""
mutable struct NetworkInteraction{P}
    plot::P
    state::LayoutState
    "Vertex under the cursor when the button went down — see `process_interaction`."
    candidate::Union{Nothing,Int}
    "Vertex currently being dragged."
    dragging::Union{Nothing,Int}
    "Cursor position, in data coordinates, when the drag began."
    anchor::Union{Nothing,Point2f}
    "Where each vertex being dragged sat when the drag began."
    origins::Dict{Int,Point2f}
    """
    Whether the current press landed on a vertex.

    Unlike `candidate` this survives the button release, because the rubber-band rectangle
    is reported on release and has to know whether that gesture was a node drag.
    """
    began_on_node::Bool
    "Corner of the rubber band, in data coordinates, or `nothing` when not banding."
    band_start::Union{Nothing,Point2f}
    "The drawn rubber-band rectangle, and the plot showing it."
    band::Observable{Rect2f}
    band_plot::Any
    "Keys already acted on, so a held key does not repeat its action."
    held::Set{Makie.Keyboard.Button}
    algorithm::Any
end

"Push the current positions, selection and pin marks into the plot."
function apply!(i::NetworkInteraction)
    i.plot.layout = copy(i.state.positions)
    i.plot.selection = sort!(collect(i.state.selected))
    i.plot.pinned = sort!(collect(i.state.pinned))
    return i
end

"Axis-aligned rectangle spanning two corners, in either order."
function _corners_to_rect(a::Point2f, b::Point2f)
    lo = Point2f(min(a[1], b[1]), min(a[2], b[2]))
    hi = Point2f(max(a[1], b[1]), max(a[2], b[2]))
    return Rect2f(lo, hi - lo)
end

"Whether a selection modifier (shift or control) is currently held."
function _multiselect_held(axis)
    keys = Makie.events(axis.scene).keyboardstate
    return Makie.Keyboard.left_shift in keys ||
           Makie.Keyboard.right_shift in keys ||
           Makie.Keyboard.left_control in keys ||
           Makie.Keyboard.right_control in keys
end

"Add `idx` to the selection, or remove it if already there."
function _toggle!(state::LayoutState, idx::Int)
    idx in state.selected ? delete!(state.selected, idx) : push!(state.selected, idx)
    return state
end

"""
    relayout!(interaction) -> interaction

Re-run the layout from the plot's current positions, keeping dragged vertices pinned, and
display the result.
"""
function relayout!(i::NetworkInteraction)
    relayout!(i.state, _as_network(i.plot.network[]).graph; algorithm = i.algorithm)
    return apply!(i)
end

"""
    resync!(interaction) -> interaction

Adopt the plot's current vertex positions as the interaction's own.

Writing to the plot's `layout` attribute — switching routing algorithm from a menu, say —
recomputes the positions inside the recipe, which leaves the interaction still holding the
positions from before: the next drag would snap the whole network back to the old layout.
Call this after any such write to hand the new positions over.

Pins and the selection survive, minus any vertex the new layout does not have. Whether a
pin still *means* anything afterwards is the caller's business: `Stress`, `Spring` and
`SFDP` honour the plot's `pin` attribute, while the tree layouts have nowhere to put it and
will move a pinned bus regardless.
"""
function resync!(i::NetworkInteraction)
    positions = i.plot.node_pos[]
    n = length(positions)
    resize!(i.state.positions, n)
    for (k, p) in enumerate(positions)
        i.state.positions[k] = Point2f(p)
    end
    filter!(<=(n), i.state.pinned)
    filter!(<=(n), i.state.selected)
    return apply!(i)
end

"""
Translate mouse events into [`drag!`](@ref) calls.

The vertex is identified on `leftdown`, **not** on `leftdragstart`. `leftdragstart` fires
only once the pointer has already moved, by which time it is no longer over the node: with
the default marker size, picking still finds the node 3 px from its centre but has moved on
to a different plot by 6 px. Picking at drag-start therefore misses almost every drag.

`pick` forces a synchronous GPU readback, so it is confined to the `leftdown` branch rather
than run on every mouse event.
"""
function Makie.process_interaction(i::NetworkInteraction, event::Makie.MouseEvent, axis)
    if event.type === Makie.MouseEventTypes.leftdown
        # Still over the node here — record it in case this becomes a drag.
        nodeplot = GraphMakie.get_node_plot(graph_plot(i.plot))
        plt, idx = Makie.pick(axis.scene)
        hit =
            (plt === nodeplot && idx isa Integer && 1 <= idx <= length(i.state.positions)) ?
            Int(idx) : nothing
        i.candidate = hit
        i.began_on_node = hit !== nothing
        i.anchor = Point2f(event.data)
        i.band_start = nothing
        adding = _multiselect_held(axis)

        if hit === nothing
            # A press on empty space arms the rubber band. Hold shift or control to widen
            # an existing selection instead of starting a new one.
            i.band_start = Point2f(event.data)
            if !adding
                deselect_all!(i.state)
                apply!(i)
            end
        elseif adding
            # Shift/control click toggles one vertex in or out of the selection.
            _toggle!(i.state, hit)
            apply!(i)
        elseif !isselected(i.state, hit)
            # Pressing an unselected vertex selects just it, so a drag moves only that one.
            select!(i.state, (hit,))
            apply!(i)
        end
        return false                      # a plain click is not ours to consume
    elseif event.type === Makie.MouseEventTypes.leftdragstart
        if i.candidate !== nothing
            i.dragging = i.candidate
            # Move the whole selection when the grabbed vertex belongs to it.
            group = isselected(i.state, i.candidate) ? i.state.selected : Set(i.candidate)
            i.origins = Dict(j => i.state.positions[j] for j in group)
            return true
        elseif i.band_start !== nothing
            i.band_plot === nothing || (i.band_plot.visible = true)
            return true
        end
    elseif event.type === Makie.MouseEventTypes.leftdrag
        if i.dragging !== nothing && i.anchor !== nothing
            drag_group!(i.state, i.origins, Point2f(event.data) - i.anchor)
            apply!(i)
            return true
        elseif i.band_start !== nothing
            i.band[] = _corners_to_rect(i.band_start, Point2f(event.data))
            return true
        end
    elseif event.type === Makie.MouseEventTypes.leftdragstop ||
           event.type === Makie.MouseEventTypes.leftup
        banding =
            i.band_start !== nothing && i.band_plot !== nothing && i.band_plot.visible[]
        if banding
            rect = i.band[]
            keep = _multiselect_held(axis) ? copy(i.state.selected) : Set{Int}()
            select_in!(i.state, rect)
            union!(i.state.selected, keep)
            i.band_plot.visible = false
            apply!(i)
        end
        wasdragging = i.dragging !== nothing
        i.dragging = nothing
        i.candidate = nothing
        i.anchor = nothing
        i.band_start = nothing
        empty!(i.origins)
        return wasdragging || banding
    elseif event.type === Makie.MouseEventTypes.rightclick
        # Right-click a vertex to release just that pin.
        nodeplot = GraphMakie.get_node_plot(graph_plot(i.plot))
        plt, idx = Makie.pick(axis.scene)
        if plt === nodeplot && idx isa Integer && 1 <= idx <= length(i.state.positions)
            unpin!(i.state, Int(idx))
            apply!(i)
            return true
        end
    end
    return false
end

"""
Translate key events into re-layout and unpin.

`KeysEvent` fires on every change to the set of held keys, and a held key repeats. Acting
on "is `r` in the set" would therefore re-run the layout many times over while the key is
down — each run costs a few hundred milliseconds on a mid-sized network, so the window
would appear to hang. Only the transition from released to pressed counts.
"""
function Makie.process_interaction(i::NetworkInteraction, event::Makie.KeysEvent, _axis)
    handled = false
    for (key, action) in (
        Makie.Keyboard.r => (() -> relayout!(i)),
        Makie.Keyboard.u => (() -> unpin_all!(i.state)),
    )
        if key in event.keys
            key in i.held && continue     # still down from the previous event
            push!(i.held, key)
            action()
            handled = true
        else
            delete!(i.held, key)
        end
    end
    return handled
end

"""
    interactive!(ax, plot; algorithm = NetworkLayout.Stress, name = :powerplot) -> NetworkInteraction

Make a `powerplot` interactive:

  - drag a bus with the left mouse button to place it by hand;
  - drag from empty space to rubber-band a group of buses, which are then highlighted and
    move together as one when any of them is dragged;
  - shift- or control-click a bus to add it to (or remove it from) the selection by hand,
    and hold either while rubber-banding to widen the selection rather than replace it;
  - right-click a bus to release just that pin;
  - press `r` to re-run the layout around whatever is pinned, and `u` to release every pin.

Dragged buses are pinned, and every pinned bus carries a small dot.

Pass `rubberband = false` to leave the left-drag-on-empty-space gesture alone.

Interaction is opt-in, and GLMakie-first — a CairoMakie figure has no event loop to drive
it. Makie's own rectangle-zoom is deregistered, because it also claims left-drag and would
otherwise swallow every drag before it reached us.

```julia
using GLMakie, PowerModels, PowerPlotsMakie
f, ax, p = powerplot(case)
interactive!(ax, p)
```
"""
function interactive!(
    ax,
    plot;
    algorithm = NetworkLayout.Stress,
    name::Symbol = :powerplot,
    rubberband::Bool = true,
)
    state = LayoutState(plot.node_pos[])
    band = Observable(Rect2f(0, 0, 0, 0))

    # The rubber band is drawn here rather than by `Makie.select_rectangle`, which is
    # hard-wired to the left button with no way to rebind or gate it: it armed on every
    # press, so dragging a vertex also drew a selection rectangle. Owning the band lets it
    # arm only when the press missed every vertex.
    band_plot = if rubberband
        p = Makie.poly!(
            ax.scene,
            band;
            color = RGBAf(0.12, 0.44, 0.85, 0.08),
            strokecolor = RGBAf(0.12, 0.44, 0.85, 0.7),
            strokewidth = 1.5,
            visible = false,
            inspectable = false,
        )
        Makie.translate!(p, 0, 0, 100)     # keep it above the network
        p
    else
        nothing
    end

    interaction = NetworkInteraction(
        plot,
        state,
        nothing,
        nothing,
        nothing,
        Dict{Int,Point2f}(),
        false,
        nothing,
        band,
        band_plot,
        Set{Makie.Keyboard.Button}(),
        algorithm,
    )
    # Rectangle zoom also binds left-drag and would consume the event first.
    haskey(Makie.interactions(ax), :rectanglezoom) &&
        Makie.deregister_interaction!(ax, :rectanglezoom)
    Makie.register_interaction!(ax, name, interaction)
    return interaction
end
