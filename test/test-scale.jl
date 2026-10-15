@testsnippet ScaleTools begin
    using PowerPlotsMakie
    using PowerPlotsMakie: resolve_autoscale, REFERENCE_NODE_SIZE, EdgeRole
    using PowerModels
    using CairoMakie
    using Makie: Figure, Axis, Point2f, Vec2f

    CairoMakie.activate!(type = "png")
    PowerModels.silence()

    readcase(name) = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", name),
    )

    "A `k`×`k` grid of points one unit apart, so the spacing is exactly 1."
    grid(k) = Point2f[Point2f(i, j) for i = 0:(k-1) for j = 0:(k-1)]

    """
    The factor `autoscale_factor` should return for a `k`×`k` unit grid in a square
    viewport, worked out by hand rather than by calling the function under test.
    """
    function expected(k, side)
        pixels_per_unit = side / ((k - 1) * 1.1)
        return 0.4 * pixels_per_unit / REFERENCE_NODE_SIZE
    end
end

@testitem "Spacing is the median distance to the nearest neighbour" tags = [:unit, :fast] setup =
    [ScaleTools] begin
    @test nearest_neighbor_spacing(grid(5)) == 1.0
    @test nearest_neighbor_spacing(Point2f[Point2f(0, 0), Point2f(3, 4)]) == 5.0

    # Nothing to measure.
    @test nearest_neighbor_spacing(Point2f[]) == 0.0
    @test nearest_neighbor_spacing([Point2f(1, 1)]) == 0.0
    @test nearest_neighbor_spacing(fill(Point2f(1, 1), 4)) == 0.0

    # One near-coincident pair must not speak for the whole layout: that is what the
    # median buys over the minimum.
    crowded = vcat(grid(5), [Point2f(0, 0.001)])
    @test nearest_neighbor_spacing(crowded) == 1.0
end

@testitem "Spacing samples a bounded number of vertices" tags = [:unit, :fast] setup =
    [ScaleTools] begin
    points = grid(20)
    # Sampling is by a fixed stride, so it is deterministic and still lands on a
    # representative spread of the layout.
    @test nearest_neighbor_spacing(points; sample = 7) == 1.0
    @test nearest_neighbor_spacing(points; sample = 1) == 1.0
    @test nearest_neighbor_spacing(points) == nearest_neighbor_spacing(points; sample = 50)
end

@testitem "The factor follows the figure size" tags = [:unit, :fast] setup = [ScaleTools] begin
    points = grid(7)
    small = autoscale_factor(points, Vec2f(1000, 1000))
    @test small ≈ expected(7, 1000)
    # Twice the figure, twice everything in it.
    @test autoscale_factor(points, Vec2f(2000, 2000)) ≈ 2 * small

    # The tighter of the two directions is the one with the room to spare.
    @test autoscale_factor(points, Vec2f(2000, 1000)) ≈ small
end

@testitem "The factor follows the density" tags = [:unit, :fast] setup = [ScaleTools] begin
    sparse = autoscale_factor(grid(7), Vec2f(1000, 1000))
    dense = autoscale_factor(grid(13), Vec2f(1000, 1000))
    @test dense < sparse
    # Twice as many nodes across the same figure, half the size each.
    @test dense ≈ sparse / 2
end

@testitem "The factor is clamped at both ends" tags = [:unit, :fast] setup = [ScaleTools] begin
    # A handful of nodes in a large figure would otherwise be drawn as dinner plates.
    @test autoscale_factor(grid(3), Vec2f(1000, 1000)) == 0.07 * 1000 / REFERENCE_NODE_SIZE
    # And a large network in a thumbnail would vanish entirely.
    @test autoscale_factor(grid(7), Vec2f(20, 20)) == 3.0 / REFERENCE_NODE_SIZE
end

@testitem "Nothing to measure means no scaling" tags = [:unit, :fast] setup = [ScaleTools] begin
    @test autoscale_factor([Point2f(0, 0)], Vec2f(600, 400)) == 1.0
    @test autoscale_factor(grid(5), Vec2f(0, 0)) == 1.0
    # A layout that collapsed to a point has no extent to divide by.
    @test autoscale_factor(fill(Point2f(2, 2), 9), Vec2f(600, 400)) == 1.0
end

@testitem "autoscale takes four spellings" tags = [:unit, :fast] setup = [ScaleTools] begin
    points = grid(7)
    view = Vec2f(1000, 1000)
    auto = autoscale_factor(points, view)

    @test resolve_autoscale(:auto, points, view) == auto
    @test resolve_autoscale(true, points, view) == auto
    # `false` must not be read as the number zero, which would collapse the plot.
    @test resolve_autoscale(false, points, view) == 1.0
    @test resolve_autoscale(nothing, points, view) == 1.0
    @test resolve_autoscale(:off, points, view) == 1.0
    @test resolve_autoscale(1.5, points, view) == 1.5

    @test_throws ArgumentError resolve_autoscale("big", points, view)
end

@testitem "Every size in the plot scales together" tags = [:integration] setup =
    [ScaleTools] begin
    case = readcase("case14.m")
    for (i, (_, br)) in enumerate(sort(collect(case["branch"]); by = first))
        br["pf"] = 10.0 * i
    end

    f, ax, p = powerplot(case; flow = true, node_strokewidth = 2.0, selection = [1, 2])
    scale = p.autoscale_factor[]
    @test scale > 0

    @test p.gp_node_size[] ≈ p.node_style[].sizes .* scale
    @test p.gp_edge_width[] ≈ p.edge_style[].sizes .* scale
    @test p.gp_node_strokewidth[] ≈ 2.0 * scale
    @test p.gp_selection_strokewidth[] ≈ p.selection_strokewidth[] * scale
    @test collect(extrema(p.flow_markersize[])) ≈ [6.0 * scale, 18.0 * scale]
    # Overlays are multiples of the node they sit on, so they come along for free.
    @test p.selection_markersize[] ≈ p.gp_node_size[][1:2] .* p.selection_scale[]
end

@testitem "autoscale = false leaves sizes in pixels" tags = [:integration] setup =
    [ScaleTools] begin
    f, ax, p = powerplot(readcase("case14.m"); autoscale = false, node_strokewidth = 2.0)
    @test p.autoscale_factor[] == 1.0
    @test p.gp_node_size[] == p.node_style[].sizes
    @test p.gp_node_strokewidth[] == 2.0

    fixed = powerplot(readcase("case14.m"); autoscale = 3.0)
    @test fixed.plot.gp_node_size[] == fixed.plot.node_style[].sizes .* 3.0
end

@testitem "A bigger figure draws a bigger network" tags = [:integration] setup =
    [ScaleTools] begin
    case = readcase("case14.m")

    small = Figure(size = (600, 450))
    ps = powerplot!(Axis(small[1, 1]), case)
    big = Figure(size = (1400, 1050))
    pb = powerplot!(Axis(big[1, 1]), case)

    @test pb.autoscale_factor[] > ps.autoscale_factor[]
    @test first(pb.gp_node_size[]) > first(ps.gp_node_size[])
end

@testitem "Resizing the figure resizes its nodes" tags = [:integration] setup = [ScaleTools] begin
    f, ax, p = powerplot(readcase("case14.m"))
    before = p.autoscale_factor[]

    resize!(f, 1400, 1050)
    # The viewport belongs to the scene, not to the plot, so this only works because the
    # recipe keeps watching it.
    @test p.viewport_size[][1] > 600
    @test p.autoscale_factor[] > before
end

@testitem "Node sizes hold still while the layout moves" tags = [:integration] setup =
    [ScaleTools] begin
    f, ax, p = powerplot(readcase("case14.m"))
    factor = p.autoscale_factor[]
    sizes = copy(p.gp_node_size[])

    # A drag: positions written straight into `layout`, which is what the interaction
    # layer does on every mouse move.
    dragged = copy(p.node_pos[])
    dragged[1] = dragged[1] + Point2f(5, 5)
    p.layout = dragged
    @test p.autoscale_factor[] == factor
    @test p.gp_node_size[] == sizes

    # And a re-layout, which rearranges everything. Markers that jumped when the user
    # pressed the re-layout key would read as a bug, not as a feature.
    for algorithm in (:stress, :radial)
        p.layout = algorithm
        @test p.autoscale_factor[] == factor
        @test p.gp_node_size[] == sizes
    end
end

@testitem "A different network is measured afresh" tags = [:integration] setup =
    [ScaleTools] begin
    f, ax, p = powerplot(readcase("case14.m"))
    crowded = p.autoscale_factor[]

    p[1] = powernetwork(readcase("case5.m"))
    # Fewer buses in the same figure, so there is room for bigger ones.
    @test p.autoscale_factor[] > crowded

    p.autoscale = 2.0
    @test p.autoscale_factor[] == 2.0
end

@testitem "The legend swatch is the size of the marker it describes" tags = [:integration] setup =
    [ScaleTools] begin
    case = readcase("case14.m")
    net = powernetwork(case)
    f, ax, p = powerplot(case)

    entries = legend_entries(p)
    gen = only(filter(e -> e.component === :gen, entries))
    @test gen.size ≈ p.gp_node_size[][first(vertex_indices(net, :gen))]

    # A swatch bigger than Makie's 20 px patch would run over its own label.
    key = powerlegend!(f[1, 2], p)
    @test first(key.legend.patchsize[]) >= gen.size

    mktempdir() do dir
        path = joinpath(dir, "scaled.png")
        save(path, f)
        @test filesize(path) > 0
    end
end
