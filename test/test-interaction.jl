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
