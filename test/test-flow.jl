@testsnippet FlowTools begin
    using PowerPlotsMakie
    using PowerPlotsMakie: flow_arrows, flow_field, EdgeRole
    using PowerModels
    using CairoMakie
    using Graphs: src, dst, nv, ne
    using Makie: Point2f

    CairoMakie.activate!(type = "png")
    PowerModels.silence()

    readcase(name) = PowerModels.parse_file(
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", name),
    )

    """
    case5 with a made-up solution merged in.

    A raw MATPOWER case has no `pf`: PowerModels writes one into each branch only once a
    solution is applied, which is exactly when flow arrows become meaningful. The signs
    alternate so that direction can be checked, and the magnitudes are distinct so that
    scaling can be.
    """
    function solved_case5()
        case = readcase("case5.m")
        for (i, (_, br)) in enumerate(sort(collect(case["branch"]); by = first))
            br["pf"] = (iseven(i) ? -1.0 : 1.0) * 10.0 * i
        end
        return case
    end

    "Vertices in a row, one unit apart: every branch is horizontal and its midpoint exact."
    row(net) = Point2f[Point2f(i, 0) for i = 1:nv(net)]

    "The angle between two directions, in [0, π]."
    angledelta(a, b) = abs(rem(a - b, 2π, RoundNearest))
end

@testitem "flow_field understands the three spellings" tags = [:unit, :fast] setup =
    [FlowTools] begin
    @test flow_field(false) === nothing
    @test flow_field(nothing) === nothing
    # `pf` is the active power leaving the from-bus, which is what PowerModels writes back.
    @test flow_field(true) === :pf
    @test flow_field(Field(:qf)) === :qf
    @test flow_field(:qt) === :qt
    @test_throws ArgumentError flow_field("yes")
end

@testitem "An arrow sits mid-branch, pointing downstream" tags = [:unit, :fast] setup =
    [FlowTools] begin
    net = powernetwork(solved_case5())
    pos = row(net)
    arrows = flow_arrows(net, pos, 0.0, true, (6.0, 18.0))

    idx = edge_indices(net, EdgeRole())
    @test length(arrows) == length(idx)

    for (k, j) in enumerate(idx)
        e = net.graph.edges[j]
        p1, p2 = pos[src(e)], pos[dst(e)]
        @test arrows.positions[k] ≈ (p1 + p2) / 2

        flow = edge_column(net, :pf)[j]
        along = atan((p2-p1)[2], (p2-p1)[1])
        # A negative flow leaves by the to-bus, so the arrow turns around.
        expected = along + (flow < 0 ? π : 0.0)
        # `:utriangle` points at +y, a quarter turn ahead of an angle measured from +x.
        @test angledelta(arrows.rotations[k], expected - π / 2) < 1e-5
    end
end

@testitem "Magnitude sets the arrow size" tags = [:unit, :fast] setup = [FlowTools] begin
    net = powernetwork(solved_case5())
    arrows = flow_arrows(net, row(net), 0.0, true, (4.0, 20.0))

    @test extrema(arrows.sizes) == (4.0, 20.0)
    # Size follows |pf|, so the ordering of the two must agree.
    mags = [abs(edge_column(net, :pf)[j]) for j in edge_indices(net, EdgeRole())]
    @test sortperm(arrows.sizes) == sortperm(mags)
end

@testitem "Equal magnitudes all take the top of the range" tags = [:unit, :fast] setup =
    [FlowTools] begin
    case = readcase("case5.m")
    for (_, br) in case["branch"]
        br["pf"] = -3.0
    end
    arrows =
        flow_arrows(powernetwork(case), row(powernetwork(case)), 0.0, true, (4.0, 20.0))
    @test all(==(20.0), arrows.sizes)
end

@testitem "A branch with no value gets no arrow" tags = [:unit, :fast] setup = [FlowTools] begin
    case = solved_case5()
    dropped = first(sort(collect(keys(case["branch"]))))
    delete!(case["branch"][dropped], "pf")
    net = powernetwork(case)

    arrows = flow_arrows(net, row(net), 0.0, true, (6.0, 18.0))
    @test length(arrows) == length(edge_indices(net, EdgeRole())) - 1

    # A case with no solution at all asks for nothing.
    plain = powernetwork(readcase("case5.m"))
    @test isempty(flow_arrows(plain, row(plain), 0.0, true, (6.0, 18.0)))
end

@testitem "Connectors never carry arrows" tags = [:unit, :fast] setup = [FlowTools] begin
    net = powernetwork(solved_case5())
    arrows = flow_arrows(net, row(net), 0.0, true, (6.0, 18.0))
    # Every branch has an arrow and nothing else does: a generator has no direction along
    # its stub.
    @test length(arrows) == length(edge_indices(net, EdgeRole()))
    @test length(arrows) < ne(net)
end

@testitem "An arrow on a bowed circuit leaves the chord" tags = [:unit, :fast] setup =
    [FlowTools] begin
    net = powernetwork(solved_case5())
    pos = row(net)
    curves = fill(0.3, ne(net))
    arrows = flow_arrows(net, pos, curves, true, (6.0, 18.0))

    for (k, j) in enumerate(edge_indices(net, EdgeRole()))
        e = net.graph.edges[j]
        chord = (pos[src(e)] + pos[dst(e)]) / 2
        # Parallel circuits are drawn apart; an arrow at the chord midpoint would sit off
        # its own line, and on a busy plot next to a different one.
        @test arrows.positions[k] ≉ chord
        @test hypot((arrows.positions[k] - chord)...) ≈ 0.3 rtol = 1e-3
    end
end

@testitem "The recipe draws arrows only when asked" tags = [:integration] setup =
    [FlowTools] begin
    case = solved_case5()
    net = powernetwork(case)

    f, ax, p = powerplot(case)
    @test isempty(p.flow_pos[])

    f2, ax2, p2 = powerplot(case; flow = true)
    @test length(p2.flow_pos[]) == length(edge_indices(net, EdgeRole()))
    @test length(p2.flow_rotation[]) == length(p2.flow_pos[])
    @test all(isfinite, p2.flow_markersize[])

    # The arrows follow the layout like everything else.
    f3, ax3, p3 = powerplot(case; flow = true, flow_size = (10.0, 30.0), layout = :stress)
    @test extrema(p3.flow_markersize[]) == (10.0, 30.0)

    mktempdir() do dir
        path = joinpath(dir, "flow.png")
        save(path, f2)
        @test filesize(path) > 0
    end
end
