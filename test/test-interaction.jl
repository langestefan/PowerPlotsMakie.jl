@testsnippet InteractionTools begin
    using PowerPlotsMakie
    using PowerPlotsMakie: PowerGraph, LayoutState
    using Makie: Point2f
    using NetworkLayout

    "A ring of six vertices, enough for a layout to have something to do."
    ring() = PowerGraph(6, [(1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 1)])
    ringstate() =
        LayoutState([Point2f(cos(t), sin(t)) for t in range(0, 2π; length = 7)[1:6]])
end

@testitem "drag! moves and pins" tags = [:unit, :fast] setup = [InteractionTools] begin
    s = ringstate()
    @test isempty(s.pinned)
    drag!(s, 3, Point2f(5, 5))
    @test s.positions[3] == Point2f(5, 5)
    # Dragging implies pinning: a hand-placed bus must survive the next re-layout.
    @test ispinned(s, 3)
    @test !ispinned(s, 1)
end

@testitem "pin, unpin and unpin_all" tags = [:unit, :fast] setup = [InteractionTools] begin
    s = ringstate()
    pin!(s, 1)
    pin!(s, 2)
    @test ispinned(s, 1) && ispinned(s, 2)
    unpin!(s, 1)
    @test !ispinned(s, 1) && ispinned(s, 2)
    unpin_all!(s)
    @test isempty(s.pinned)
    # Unpinning something that was never pinned is not an error.
    @test unpin!(s, 4) === s
end

@testitem "drag! checks bounds" tags = [:unit, :fast] setup = [InteractionTools] begin
    s = ringstate()
    @test_throws BoundsError drag!(s, 99, Point2f(0, 0))
    @test_throws BoundsError pin!(s, 0)
end

@testitem "copy leaves the original alone" tags = [:unit, :fast] setup = [InteractionTools] begin
    s = ringstate()
    t = copy(s)
    drag!(t, 1, Point2f(9, 9))
    @test s.positions[1] != Point2f(9, 9)
    @test isempty(s.pinned)
end

@testitem "relayout! holds pinned vertices exactly" tags = [:unit, :fast] setup =
    [InteractionTools] begin
    s = ringstate()
    g = ring()
    drag!(s, 1, Point2f(10, 0))
    drag!(s, 4, Point2f(-10, 0))
    pinned = copy(s.positions)

    relayout!(s, g)

    # Pinned vertices must not have shifted by even a float.
    @test s.positions[1] == pinned[1]
    @test s.positions[4] == pinned[4]
    # ...and the free ones must actually have been solved for.
    free = [2, 3, 5, 6]
    @test any(i -> s.positions[i] != pinned[i], free)
    @test all(i -> all(isfinite, s.positions[i]), 1:6)
end

@testitem "relayout! with nothing pinned still runs" tags = [:unit, :fast] setup =
    [InteractionTools] begin
    s = ringstate()
    relayout!(s, ring())
    @test length(s.positions) == 6
    @test all(p -> all(isfinite, p), s.positions)
end

@testitem "relayout! accepts other iterative algorithms" tags = [:unit, :fast] setup =
    [InteractionTools] begin
    for algorithm in (NetworkLayout.Stress, NetworkLayout.Spring, NetworkLayout.SFDP)
        s = ringstate()
        drag!(s, 2, Point2f(4, 4))
        relayout!(s, ring(); algorithm = algorithm)
        # Pinning is supported by exactly these three layouts.
        @test s.positions[2] == Point2f(4, 4)
    end
end

@testitem "select! replaces the selection" tags = [:unit, :fast] setup = [InteractionTools] begin
    s = ringstate()
    @test isempty(s.selected)
    select!(s, [1, 3])
    @test isselected(s, 1) && isselected(s, 3) && !isselected(s, 2)
    select!(s, [2])                       # replaces, does not add
    @test isselected(s, 2) && !isselected(s, 1)
    deselect_all!(s)
    @test isempty(s.selected)
    @test_throws BoundsError select!(s, [99])
    # Selection is orthogonal to pinning.
    select!(s, [1])
    @test isempty(s.pinned)
end

@testitem "select_in! picks the vertices inside a rectangle" tags = [:unit, :fast] setup =
    [InteractionTools] begin
    using Makie: Rect2f
    s = LayoutState([Point2f(0, 0), Point2f(1, 0), Point2f(5, 5), Point2f(-3, 2)])
    select_in!(s, Rect2f(-0.5, -0.5, 2.0, 2.0))     # origin + widths
    @test sort(collect(s.selected)) == [1, 2]
    # A second rectangle replaces rather than accumulates.
    select_in!(s, Rect2f(4.0, 4.0, 2.0, 2.0))
    @test sort(collect(s.selected)) == [3]
    # An empty region clears it.
    select_in!(s, Rect2f(100.0, 100.0, 1.0, 1.0))
    @test isempty(s.selected)
end

@testitem "drag_group! moves a group rigidly" tags = [:unit, :fast] setup =
    [InteractionTools] begin
    s = ringstate()
    origins = Dict(1 => s.positions[1], 3 => s.positions[3])
    before = copy(s.positions)
    drag_group!(s, origins, Point2f(2, -1))

    @test s.positions[1] == before[1] + Point2f(2, -1)
    @test s.positions[3] == before[3] + Point2f(2, -1)
    # Relative geometry of the group is preserved exactly.
    @test s.positions[3] - s.positions[1] ≈ before[3] - before[1]
    # Everything else is untouched, and the moved ones are pinned.
    @test s.positions[2] == before[2]
    @test ispinned(s, 1) && ispinned(s, 3) && !ispinned(s, 2)
end

@testitem "drag_group! anchors to origins, so repeated drags do not drift" tags =
    [:unit, :fast] setup = [InteractionTools] begin
    s = ringstate()
    origins = Dict(1 => s.positions[1])
    start = s.positions[1]
    # Successive events during one drag all measure from the same origin.
    for d in (Point2f(1, 0), Point2f(2, 0), Point2f(3, 0))
        drag_group!(s, origins, d)
    end
    @test s.positions[1] == start + Point2f(3, 0)
end

@testitem "The plot exposes a selection highlight" tags = [:integration] begin
    using PowerPlotsMakie
    using PowerModels
    using CairoMakie
    using Makie: Point2f

    CairoMakie.activate!(type = "png")
    PowerModels.silence()
    case = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", "case5.m"),
    )

    f, ax, p = powerplot(case; selection = [2, 4])
    @test length(p.selection_pos[]) == 2
    @test p.selection_pos[] == p.node_pos[][[2, 4]]
    # The ring is drawn larger than the node it marks.
    @test all(p.selection_markersize[] .> p.gp_node_size[][[2, 4]])

    # Selection is reactive.
    p.selection = Int[]
    @test isempty(p.selection_pos[])

    # Out-of-range indices are dropped rather than throwing.
    p.selection = [1, 9999]
    @test length(p.selection_pos[]) == 1
end

@testitem "interactive! keeps plot selection in step" tags = [:integration] begin
    using PowerPlotsMakie
    using PowerPlotsMakie: apply!
    using PowerModels
    using CairoMakie
    using Makie: Point2f, Rect2f

    CairoMakie.activate!(type = "png")
    PowerModels.silence()
    case = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", "case5.m"),
    )
    fig = Figure()
    ax = Axis(fig[1, 1])
    plt = powerplot!(ax, case)
    it = interactive!(ax, plt)

    select!(it.state, [1, 2])
    apply!(it)
    @test plt.selection[] == [1, 2]
    @test length(plt.selection_pos[]) == 2

    # Moving a selected group keeps their relative positions and shifts only them.
    before = copy(plt.node_pos[])
    drag_group!(it.state, Dict(1 => before[1], 2 => before[2]), Point2f(1, 1))
    apply!(it)
    after = plt.node_pos[]
    @test after[1] == before[1] + Point2f(1, 1)
    @test after[2] == before[2] + Point2f(1, 1)
    @test all(i -> after[i] == before[i], 3:length(before))
end

@testitem "The plot marks pinned vertices" tags = [:integration] begin
    using PowerPlotsMakie
    using PowerModels
    using CairoMakie

    CairoMakie.activate!(type = "png")
    PowerModels.silence()
    case = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", "case5.m"),
    )

    f, ax, p = powerplot(case; pinned = [1, 3])
    @test length(p.pinned_pos[]) == 2
    @test p.pinned_pos[] == p.node_pos[][[1, 3]]
    # The dot sits inside the node rather than ringing it.
    @test all(p.pinned_markersize[] .< p.gp_node_size[][[1, 3]])

    p.pinned = Int[]
    @test isempty(p.pinned_pos[])
end

@testitem "Dragging marks the vertex as pinned in the plot" tags = [:integration] begin
    using PowerPlotsMakie
    using PowerPlotsMakie: apply!
    using PowerModels
    using CairoMakie
    using Makie: Point2f

    CairoMakie.activate!(type = "png")
    PowerModels.silence()
    case = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", "case5.m"),
    )
    fig = Figure()
    ax = Axis(fig[1, 1])
    plt = powerplot!(ax, case)
    it = interactive!(ax, plt)

    @test isempty(plt.pinned[])
    drag!(it.state, 2, Point2f(5, 5))
    apply!(it)
    @test plt.pinned[] == [2]

    unpin!(it.state, 2)
    apply!(it)
    @test isempty(plt.pinned[])
end

@testitem "Right-click releases one pin" tags = [:interactive] begin
    using PowerPlotsMakie
    using PowerModels
    using GLMakie
    import GLMakie.Makie
    using GLMakie.Makie: Mouse, MouseButtonEvent, events, Point2f

    PowerModels.silence()
    case = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", "case5.m"),
    )
    fig = Figure()
    ax = Axis(fig[1, 1])
    plt = powerplot!(ax, case)
    it = interactive!(ax, plt)
    screen = display(GLMakie.Screen(visible = false), fig)
    Makie.colorbuffer(screen)

    pin!(it.state, 1)
    pin!(it.state, 2)
    PowerPlotsMakie.apply!(it)
    @test plt.pinned[] == [1, 2]

    origin = Point2f(Makie.to_value(ax.scene.viewport).origin)
    target =
        Tuple(Point2f(Makie.project(ax.scene, plt.node_pos[][1])) + origin + Point2f(3, 3))
    e = events(fig.scene)
    e.mouseposition[] = target
    e.mousebutton[] = MouseButtonEvent(Mouse.right, Mouse.press)
    e.mousebutton[] = MouseButtonEvent(Mouse.right, Mouse.release)

    # Only the vertex under the cursor is released.
    @test !ispinned(it.state, 1)
    @test ispinned(it.state, 2)
    @test plt.pinned[] == [2]
end

@testitem "Shift-click extends the selection" tags = [:interactive] begin
    using PowerPlotsMakie
    using PowerModels
    using GLMakie
    import GLMakie.Makie
    using GLMakie.Makie: Mouse, MouseButtonEvent, Keyboard, KeyEvent, events, Point2f

    PowerModels.silence()
    case = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", "case5.m"),
    )
    fig = Figure()
    ax = Axis(fig[1, 1])
    plt = powerplot!(ax, case)
    it = interactive!(ax, plt)
    screen = display(GLMakie.Screen(visible = false), fig)
    Makie.colorbuffer(screen)

    origin = Point2f(Makie.to_value(ax.scene.viewport).origin)
    at(i) =
        Tuple(Point2f(Makie.project(ax.scene, plt.node_pos[][i])) + origin + Point2f(3, 3))
    e = events(fig.scene)
    click(i) = begin
        e.mouseposition[] = at(i)
        e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.press)
        e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.release)
    end

    click(1)
    @test sort(collect(it.state.selected)) == [1]

    # Plain click on another vertex replaces the selection...
    click(2)
    @test sort(collect(it.state.selected)) == [2]

    # ...while shift-click adds to it, and clicking again removes it.
    e.keyboardbutton[] = KeyEvent(Keyboard.left_shift, Keyboard.press)
    click(1)
    @test sort(collect(it.state.selected)) == [1, 2]
    click(1)
    @test sort(collect(it.state.selected)) == [2]
    e.keyboardbutton[] = KeyEvent(Keyboard.left_shift, Keyboard.release)
end

@testitem "A synthetic rubber band selects and moves a group" tags = [:interactive] begin
    # The `select_rectangle` wiring can only be checked through the real event pipeline:
    # it listens on raw mouse observables, not on our interaction.
    using PowerPlotsMakie
    using PowerModels
    using GLMakie
    import GLMakie.Makie
    using GLMakie.Makie: Mouse, MouseButtonEvent, events, Point2f

    PowerModels.silence()
    case = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", "case5.m"),
    )
    fig = Figure()
    ax = Axis(fig[1, 1])
    plt = powerplot!(ax, case)
    it = interactive!(ax, plt)
    screen = display(GLMakie.Screen(visible = false), fig)
    Makie.colorbuffer(screen)

    pos = copy(plt.node_pos[])
    origin = Point2f(Makie.to_value(ax.scene.viewport).origin)
    topx(p) = Tuple(Point2f(Makie.project(ax.scene, p)) + origin)

    # Sweep a band across the whole axis, corner to corner. The gesture has to stay inside
    # the viewport: `select_rectangle` ignores a press made outside the scene, so a start
    # point computed from the data extent would fall outside and arm nothing.
    vp = Makie.to_value(ax.scene.viewport)
    corner = Point2f(vp.origin)
    far = corner + Point2f(vp.widths)
    e = events(fig.scene)
    e.mouseposition[] = Tuple(corner + Point2f(3, 3))
    e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.press)
    for f in (0.3, 0.7, 1.0)
        e.mouseposition[] = Tuple(corner + f * (far - corner - Point2f(6, 6)))
    end
    e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.release)

    @test !it.began_on_node                    # the gesture started on empty space
    @test length(it.state.selected) == length(pos)
    @test plt.selection[] == collect(1:length(pos))
    @test length(plt.selection_pos[]) == length(pos)

    # Now drag one member of that selection: the whole group must move together.
    before = copy(plt.node_pos[])
    start = topx(before[1])
    e.mouseposition[] = start
    e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.press)
    @test it.began_on_node                     # this one did land on a vertex
    for k = 1:3
        e.mouseposition[] = (start[1] + 20k, start[2] + 20k)
    end
    e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.release)

    after = plt.node_pos[]
    delta = after[1] - before[1]
    @test delta != Point2f(0, 0)               # it actually moved
    # Rigid: every vertex shifted by the same amount.
    @test all(i -> after[i] - before[i] ≈ delta, eachindex(after))
end

@testitem "A synthetic mouse drag moves a bus" tags = [:interactive] begin
    # Drives the real Makie event pipeline rather than calling `drag!` directly. The
    # earlier tests exercised only the state machine, which is exactly why a bug in the
    # event handling (picking at `leftdragstart`, after the pointer has left the node)
    # went unnoticed. Needs GLMakie: CairoMakie has no picking.
    using PowerPlotsMakie
    using PowerModels
    using GLMakie
    import GLMakie.Makie
    using GLMakie.Makie: Mouse, MouseButtonEvent, events, Point2f

    PowerModels.silence()
    case = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", "case5.m"),
    )

    fig = Figure()
    ax = Axis(fig[1, 1])
    plt = powerplot!(ax, case)
    it = interactive!(ax, plt)
    screen = display(GLMakie.Screen(visible = false), fig)
    # Picking reads back the GPU pick buffer, which only exists once a frame has been
    # drawn. Without this the pick silently finds nothing and no drag ever starts.
    Makie.colorbuffer(screen)

    before = copy(plt.node_pos[])
    origin = Point2f(Makie.to_value(ax.scene.viewport).origin)
    # Aim a few pixels off centre: picking is exact there, and it is where a real pointer
    # lands anyway.
    target = Tuple(Point2f(Makie.project(ax.scene, before[1])) + origin + Point2f(3, 3))

    e = events(fig.scene)
    e.mouseposition[] = target
    e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.press)
    for k = 1:4
        e.mouseposition[] = (target[1] + 15k, target[2] + 15k)
    end
    e.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.release)

    after = copy(plt.node_pos[])
    @test after[1] != before[1]           # the bus actually moved
    @test 1 in it.state.pinned            # and dragging pinned it
    @test it.dragging === nothing         # drag released cleanly
    @test it.candidate === nothing
    # Dragging a vertex must not also draw a selection rectangle. `Makie.select_rectangle`
    # armed on every press regardless of what was under the cursor, so it did.
    @test !it.band_plot.visible[]
    @test it.band_start === nothing
    # Only the dragged bus moved.
    @test all(i -> after[i] == before[i], 2:length(before))
end

@testitem "A held key does not repeat its action" tags = [:integration] begin
    using PowerPlotsMakie
    using PowerPlotsMakie: NetworkInteraction, LayoutState
    using CairoMakie
    import CairoMakie.Makie
    using CairoMakie.Makie: Point2f, Keyboard, KeysEvent
    using PowerModels

    CairoMakie.activate!(type = "png")
    PowerModels.silence()
    case = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", "case5.m"),
    )
    fig = Figure()
    ax = Axis(fig[1, 1])
    plt = powerplot!(ax, case)
    it = interactive!(ax, plt)

    pin!(it.state, 1)
    # `u` held down: KeysEvent fires repeatedly, but only the first press should act.
    @test Makie.process_interaction(it, KeysEvent(Set([Keyboard.u])), ax)
    @test isempty(it.state.pinned)
    pin!(it.state, 2)
    @test !Makie.process_interaction(it, KeysEvent(Set([Keyboard.u])), ax)
    @test 2 in it.state.pinned            # still pinned: the repeat was ignored
    # Releasing re-arms it.
    Makie.process_interaction(it, KeysEvent(Set{Keyboard.Button}()), ax)
    @test Makie.process_interaction(it, KeysEvent(Set([Keyboard.u])), ax)
    @test isempty(it.state.pinned)
end

@testitem "interactive! registers and drives the plot" tags = [:integration] begin
    using PowerPlotsMakie
    using PowerPlotsMakie: graph_plot, apply!
    using PowerModels
    using CairoMakie
    using Makie: Point2f
    import GraphMakie

    CairoMakie.activate!(type = "png")
    PowerModels.silence()
    case = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", "case5.m"),
    )

    fig = Figure()
    ax = Axis(fig[1, 1])
    plt = powerplot!(ax, case)
    it = interactive!(ax, plt)

    @test haskey(Makie.interactions(ax), :powerplot)
    # Rectangle zoom also binds left-drag and would consume the event first.
    @test !haskey(Makie.interactions(ax), :rectanglezoom)
    @test graph_plot(plt) isa GraphMakie.GraphPlot

    # Dragging writes straight through to the displayed positions.
    drag!(it.state, 1, Point2f(7, 7))
    apply!(it)
    @test plt.node_pos[][1] == Point2f(7, 7)

    # ...and survives a re-layout.
    relayout!(it)
    @test plt.node_pos[][1] == Point2f(7, 7)
    @test length(plt.node_pos[]) == length(it.state.positions)
end

@testitem "resync! adopts positions from a new layout" tags = [:integration] begin
    using PowerPlotsMakie
    using PowerModels
    using CairoMakie
    using Makie: Point2f

    CairoMakie.activate!(type = "png")
    PowerModels.silence()
    case = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", "case5.m"),
    )
    fig = Figure()
    ax = Axis(fig[1, 1])
    plt = powerplot!(ax, case)
    it = interactive!(ax, plt)

    drag!(it.state, 1, Point2f(42, 42))
    PowerPlotsMakie.apply!(it)

    # Switching routing algorithm recomputes the positions inside the recipe, and the
    # interaction is left holding the old ones until it is told otherwise.
    plt.layout = :radial
    stale = copy(it.state.positions)
    fresh = plt.node_pos[]
    @test stale != fresh

    resync!(it)
    @test it.state.positions == Point2f[Point2f(p) for p in fresh]
    @test ispinned(it.state, 1)          # pins survive; honouring them is the layout's job

    # And the plot follows the interaction again, rather than the discarded layout.
    drag!(it.state, 2, Point2f(7, 7))
    PowerPlotsMakie.apply!(it)
    @test plt.node_pos[][2] == Point2f(7, 7)
    @test plt.node_pos[][3] == fresh[3]
end
