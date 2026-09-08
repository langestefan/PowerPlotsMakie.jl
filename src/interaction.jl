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
end

LayoutState(positions::AbstractVector) =
    LayoutState(Point2f[Point2f(p) for p in positions], Set{Int}())

Base.copy(s::LayoutState) = LayoutState(copy(s.positions), copy(s.pinned))

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
    "Keys already acted on, so a held key does not repeat its action."
    held::Set{Makie.Keyboard.Button}
    algorithm::Any
end

"Push the current positions into the plot."
function apply!(i::NetworkInteraction)
    i.plot.layout = copy(i.state.positions)
    return i
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
        i.candidate =
            (plt === nodeplot && idx isa Integer && 1 <= idx <= length(i.state.positions)) ?
            Int(idx) : nothing
        return false                      # a plain click is not ours to consume
    elseif event.type === Makie.MouseEventTypes.leftdragstart
        if i.candidate !== nothing
            i.dragging = i.candidate
            return true
        end
    elseif event.type === Makie.MouseEventTypes.leftdrag
        if i.dragging !== nothing
            drag!(i.state, i.dragging, Point2f(event.data))
            apply!(i)
            return true
        end
    elseif event.type === Makie.MouseEventTypes.leftdragstop ||
           event.type === Makie.MouseEventTypes.leftup
        wasdragging = i.dragging !== nothing
        i.dragging = nothing
        i.candidate = nothing
        return wasdragging
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

Make a `powerplot` interactive: drag buses with the left mouse button, press `r` to re-run
the layout around whatever you have pinned, and `u` to release every pin.

Interaction is opt-in, and GLMakie-first — a CairoMakie figure has no event loop to drive
it. Makie's own rectangle-zoom is deregistered, because it also claims left-drag and would
otherwise swallow every drag before it reached us.

```julia
using GLMakie, PowerModels, PowerPlotsMakie
f, ax, p = powerplot(case)
interactive!(ax, p)
```
"""
function interactive!(ax, plot; algorithm = NetworkLayout.Stress, name::Symbol = :powerplot)
    state = LayoutState(plot.node_pos[])
    interaction = NetworkInteraction(
        plot,
        state,
        nothing,
        nothing,
        Set{Makie.Keyboard.Button}(),
        algorithm,
    )
    # Rectangle zoom also binds left-drag and would consume the event first.
    haskey(Makie.interactions(ax), :rectanglezoom) &&
        Makie.deregister_interaction!(ax, :rectanglezoom)
    Makie.register_interaction!(ax, name, interaction)
    return interaction
end
