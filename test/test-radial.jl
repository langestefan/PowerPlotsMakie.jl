@testmodule Feeders begin
    using PowerPlotsMakie

    """
    A backend that describes a network purely by its shape, so a test can state the topology
    it wants and nothing else. Buses are numbered `1:nbus`; `gens` and `loads` name the bus
    each injection hangs off.
    """
    struct Feeder
        nbus::Int
        branches::Vector{Tuple{String,String}}
        gens::Vector{String}
        loads::Vector{String}
        roots::Vector{String}
        coords::Dict{String,Tuple{Float64,Float64}}
    end

    function Feeder(
        nbus,
        branches;
        gens = String[],
        loads = String[],
        roots = ["1"],
        coords = Dict{String,Tuple{Float64,Float64}}(),
    )
        return Feeder(nbus, branches, gens, loads, roots, coords)
    end

    PowerPlotsMakie.component_types(::Feeder, ::NodeRole) = [:bus]
    PowerPlotsMakie.component_types(::Feeder, ::EdgeRole) = [:branch]
    PowerPlotsMakie.component_types(::Feeder, ::InjectionRole) = [:gen, :load]

    function PowerPlotsMakie.component_ids(f::Feeder, comp::Symbol)
        comp === :bus && return string.(1:(f.nbus))
        comp === :branch && return string.(1:length(f.branches))
        comp === :gen && return string.(1:length(f.gens))
        comp === :load && return string.(1:length(f.loads))
        return String[]
    end

    PowerPlotsMakie.component_field(::Feeder, ::Symbol, ::AbstractString, ::Symbol) = missing
    PowerPlotsMakie.edge_endpoints(f::Feeder, ::Symbol, id) = f.branches[parse(Int, id)]
    PowerPlotsMakie.injection_bus(f::Feeder, comp::Symbol, id) =
        comp === :gen ? f.gens[parse(Int, id)] : f.loads[parse(Int, id)]
    PowerPlotsMakie.reference_nodes(f::Feeder) = f.roots
    PowerPlotsMakie.node_coordinates(f::Feeder, ::Symbol, id::AbstractString) =
        get(f.coords, id, nothing)

    "A chain of `n` buses, `1 - 2 - … - n`."
    chain(n; kwargs...) =
        Feeder(n, [(string(i), string(i + 1)) for i = 1:(n - 1)]; kwargs...)

    "A complete binary tree of `n` buses, child `i` hanging off bus `i ÷ 2`."
    binary(n; kwargs...) =
        Feeder(n, [(string(i ÷ 2), string(i)) for i = 2:n]; kwargs...)

    "The index of the vertex drawn for `comp[id]`."
    vertex(net, comp, id) = net.vertex_index[ComponentRef(comp, id)]

    "Positions of the bus vertices only, in bus order."
    buspos(net, pos) = [pos[vertex(net, :bus, string(i))] for i = 1:count_buses(net)]

    count_buses(net) = count(r -> r.component === :bus, net.vertices)
end

# ---------------------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------------------

@testitem "A forest of feeders is radial" tags = [:unit, :fast] setup = [Feeders] begin
    @test isradial(powernetwork(Feeders.chain(5)))
    @test isradial(powernetwork(Feeders.binary(15)))

    # Two islands are still a forest.
    islands = Feeders.Feeder(4, [("1", "2"), ("3", "4")])
    @test isradial(powernetwork(islands))
end

@testitem "A loop is not radial" tags = [:unit, :fast] setup = [Feeders] begin
    ring = Feeders.Feeder(4, [("1", "2"), ("2", "3"), ("3", "4"), ("4", "1")])
    @test !isradial(powernetwork(ring))
end

@testitem "Parallel circuits and self-loops are not radial" tags = [:unit, :fast] setup =
    [Feeders] begin
    # Collapsing the parallel pair would leave a tree, but two circuits between the same
    # buses are a loop in the network however the drawing chooses to route them.
    parallel = Feeders.Feeder(3, [("1", "2"), ("1", "2"), ("2", "3")])
    @test !isradial(powernetwork(parallel))

    selfloop = Feeders.Feeder(3, [("1", "2"), ("2", "3"), ("3", "3")])
    @test !isradial(powernetwork(selfloop))
end

@testitem "Injections do not count against radiality" tags = [:unit, :fast] setup =
    [Feeders] begin
    using Graphs
    # Every injection adds a vertex and a connector; counting them would make the whole
    # graph look like it has as many extra edges as it has injections.
    f = Feeders.chain(3; gens = ["1", "2"], loads = ["3", "3", "2"])
    net = powernetwork(f)
    @test nv(net) == 8 && ne(net) == 7
    sub, verts, extra = PowerPlotsMakie.node_subgraph(net)
    @test nv(sub) == 3 && ne(sub) == 2 && extra == 0
    @test verts == [1, 2, 3]
    @test isradial(net)
end

# ---------------------------------------------------------------------------------------
# Tree placement
# ---------------------------------------------------------------------------------------

@testitem "The reference bus roots the tree" tags = [:unit, :fast] setup = [Feeders] begin
    net = powernetwork(Feeders.binary(7))
    @test radial_tree(net).roots == [Feeders.vertex(net, :bus, "1")]

    pos = layout_positions(net; layout = :radial)
    bus = Feeders.buspos(net, pos)
    @test bus[1][2] == 0                      # root on the baseline
    @test all(p[2] < 0 for p in bus[2:end])   # everything else below it
end

@testitem "A root away from vertex 1 is renumbered" tags = [:unit, :fast] setup =
    [Feeders] begin
    # Buchheim insists the root is vertex 1; here it is vertex 3, so the wrapper has to
    # renumber the component rather than pass it straight through.
    net = powernetwork(Feeders.chain(5; roots = ["3"]))
    pos = layout_positions(net; layout = :radial)
    bus = Feeders.buspos(net, pos)

    @test bus[3][2] == 0
    @test bus[2][2] == bus[4][2] == -2        # one level down on either side
    @test bus[1][2] == bus[5][2] == -4
end

@testitem "Without a reference bus the best-connected one roots" tags = [:unit, :fast] setup =
    [Feeders] begin
    net = powernetwork(Feeders.chain(3; roots = String[]))
    @test isempty(radial_tree(net).roots)

    bus = Feeders.buspos(net, layout_positions(net; layout = :radial))
    @test bus[2][2] == 0                      # degree 2 beats the two leaves
    @test bus[1][2] == bus[3][2] == -2
end

@testitem "Depth is proportional to distance from the root" tags = [:unit, :fast] setup =
    [Feeders] begin
    net = powernetwork(Feeders.binary(15))
    bus = Feeders.buspos(net, layout_positions(net; layout = :radial))
    # Bus i sits at tree depth floor(log2(i)), and Buchheim's default node size puts two
    # units between levels.
    for i = 1:15
        @test bus[i][2] ≈ -2 * floor(Int, log2(i))
    end
end

@testitem "Islands are packed side by side" tags = [:unit, :fast] setup = [Feeders] begin
    islands = Feeders.Feeder(6, [("1", "2"), ("2", "3"), ("4", "5"), ("5", "6")])
    net = powernetwork(islands)
    bus = Feeders.buspos(net, layout_positions(net; layout = :radial))

    left = [p[1] for p in bus[1:3]]
    right = [p[1] for p in bus[4:6]]
    @test maximum(left) < minimum(right)      # no overlap
    # Each island is rooted independently — the second has no reference bus, so its
    # best-connected vertex roots it — and both roots sit on the same baseline.
    @test maximum(p[2] for p in bus[1:3]) == 0
    @test maximum(p[2] for p in bus[4:6]) == 0
    @test bus[1][2] == 0 && bus[5][2] == 0
end

@testitem "An isolated bus is placed rather than thrown at Buchheim" tags = [:unit, :fast] setup =
    [Feeders] begin
    # A one-node component makes Buchheim index into a parent that does not exist, so the
    # wrapper has to place it itself.
    lonely = Feeders.Feeder(3, [("1", "2")])
    net = powernetwork(lonely)
    bus = Feeders.buspos(net, layout_positions(net; layout = :radial))
    @test all(all(isfinite, p) for p in bus)
    @test bus[3][1] > maximum(p[1] for p in bus[1:2])
end

# ---------------------------------------------------------------------------------------
# Satellites
# ---------------------------------------------------------------------------------------

@testitem "An injection orbits its bus, away from the branches" tags = [:unit, :fast] setup =
    [Feeders] begin
    using Makie: Point2f
    net = powernetwork(Feeders.chain(2; loads = ["2"]))
    pos = layout_positions(net; layout = :radial)

    b2 = pos[Feeders.vertex(net, :bus, "2")]
    load = pos[Feeders.vertex(net, :load, "1")]
    # Bus 2's only branch runs upwards to bus 1, so the load hangs straight down.
    @test load ≈ b2 + Point2f(0, -0.7)
end

@testitem "Several injections fan out around one bus" tags = [:unit, :fast] setup =
    [Feeders] begin
    net = powernetwork(Feeders.chain(2; gens = ["2"], loads = ["2", "2"]))
    pos = layout_positions(net; layout = :radial)
    b2 = pos[Feeders.vertex(net, :bus, "2")]

    sats = [
        pos[Feeders.vertex(net, :gen, "1")],
        pos[Feeders.vertex(net, :load, "1")],
        pos[Feeders.vertex(net, :load, "2")],
    ]
    # All at the same distance, all at distinct angles, none on top of another.
    @test all(≈(0.7; atol = 1e-5), [hypot((s - b2)...) for s in sats])
    angles = sort([atan((s - b2)[2], (s - b2)[1]) for s in sats])
    @test allunique(angles)
    @test minimum(diff(angles)) > 0.5
end

@testitem "_widest_gap finds the free direction" tags = [:unit, :fast] begin
    using PowerPlotsMakie: _widest_gap

    @test _widest_gap(Float64[]) == (0.0, 2π)
    # One neighbour leaves everything else free.
    start, width = _widest_gap([0.0])
    @test start == 0.0 && width ≈ 2π
    # Parent above, child below: the gap is the half-circle starting at the child.
    start, width = _widest_gap([π / 2, -π / 2])
    @test start ≈ π / 2 && width ≈ π
    # The widest of three uneven gaps wins.
    start, width = _widest_gap([0.0, 0.3, 1.0])
    @test start ≈ 1.0 && width ≈ 2π - 1.0
end

# ---------------------------------------------------------------------------------------
# Selection through :auto
# ---------------------------------------------------------------------------------------

@testitem ":auto picks radial for a feeder and stress for a mesh" tags = [:unit, :fast] setup =
    [Feeders] begin
    feeder = powernetwork(Feeders.binary(7))
    @test layout_positions(feeder) == layout_positions(feeder; layout = :radial)

    ring = powernetwork(Feeders.Feeder(4, [("1", "2"), ("2", "3"), ("3", "4"), ("4", "1")]))
    @test layout_positions(ring) == layout_positions(ring; layout = :stress)
    @test layout_positions(ring) != layout_positions(ring; layout = :radial)
end

@testitem ":auto defers to coordinates and pins" tags = [:unit, :fast] setup = [Feeders] begin
    using Makie: Point2f
    # A radial network whose buses already carry coordinates must keep them: only the
    # iterative layouts can honour a partial answer, so :auto stays with Stress.
    coords = Dict("1" => (0.0, 0.0), "2" => (3.0, 1.0), "3" => (6.0, -1.0))
    net = powernetwork(Feeders.chain(3; loads = ["3"], coords = coords))
    pos = layout_positions(net)
    for (id, xy) in coords
        @test pos[Feeders.vertex(net, :bus, id)] == Point2f(xy)
    end

    # An explicit pin has the same effect on a network with no coordinates of its own.
    plain = powernetwork(Feeders.binary(7))
    @test layout_positions(plain; pin = [1]) != layout_positions(plain; layout = :radial)
end

@testitem "Radial can be forced onto a meshed network" tags = [:unit, :fast] setup =
    [Feeders] begin
    # The extra edges are not part of the rooted tree; they are simply drawn as chords
    # between the vertices the tree placed, so this must not throw.
    mesh = Feeders.Feeder(
        4,
        [("1", "2"), ("2", "3"), ("3", "4"), ("4", "1"), ("1", "3")];
        loads = ["3"],
    )
    net = powernetwork(mesh)
    pos = layout_positions(net; layout = :radial)
    @test length(pos) == 5
    @test all(all(isfinite, p) for p in pos)
    @test allunique(pos)
end

@testitem "An unknown layout name is rejected" tags = [:unit, :fast] setup = [Feeders] begin
    net = powernetwork(Feeders.chain(3))
    @test_throws ArgumentError layout_positions(net; layout = :spiral)
end
