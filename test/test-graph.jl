@testsnippet ParallelCase begin
    using Graphs
    using PowerPlotsMakie:
        PowerGraph, PowerEdge, multiplicity, simple_graph, parallel_offsets

    # Four buses in a ring, with two parallel circuits between buses 1 and 2.
    pairs = [(1, 2), (1, 2), (2, 3), (3, 4), (4, 1)]
    g = PowerGraph(4, pairs)
end

@testitem "PowerGraph keeps parallel circuits distinct" tags = [:unit, :fast] setup =
    [ParallelCase] begin
    @test nv(g) == 4
    # Five electrical circuits, not the four a SimpleGraph would collapse them to.
    @test ne(g) == 5
    @test length(collect(edges(g))) == 5
    @test multiplicity.(collect(edges(g))) == [1, 2, 1, 1, 1]
    @test simple_graph(g) isa Graphs.SimpleGraph
    @test ne(simple_graph(g)) == 4
end

@testitem "PowerGraph adjacency is deduplicated" tags = [:unit, :fast] setup =
    [ParallelCase] begin
    # Regression test. Pushing parallel edges into the adjacency list makes
    # `adjacency_matrix` emit duplicate structural entries and makes `degree` count a
    # parallel circuit twice, which silently distorts every layout.
    A = adjacency_matrix(g)
    @test length(A.nzval) == 8
    @test all(==(1), A.nzval)
    @test A[1, 2] == 1
    @test degree(g) == [2, 2, 2, 2]
    @test is_connected(g)
    @test all(allunique, g.fadj)
end

@testitem "PowerGraph satisfies the Graphs interface" tags = [:unit, :fast] setup =
    [ParallelCase] begin
    @test eltype(g) == Int
    @test Graphs.edgetype(g) == PowerEdge
    @test !is_directed(g)
    @test vertices(g) == 1:4
    @test has_vertex(g, 1) && !has_vertex(g, 5)
    @test has_edge(g, 1, 2) && has_edge(g, 2, 1)
    @test !has_edge(g, 1, 3)
    @test sort(outneighbors(g, 1)) == [2, 4]
    @test outneighbors(g, 1) == inneighbors(g, 1)
    # Graph algorithms used by layout and radial detection must work unchanged.
    @test length(dijkstra_shortest_paths(g, 1).dists) == 4
    @test !isempty(bfs_tree(g, 1).fadjlist)
end

@testitem "PowerEdge reversal and identity" tags = [:unit, :fast] begin
    using PowerPlotsMakie: PowerEdge
    using Graphs: src, dst
    e = PowerEdge(1, 2, 2)
    @test src(e) == 1 && dst(e) == 2
    @test reverse(e) == e            # undirected: same circuit either way round
    @test src(reverse(e)) == 2
    @test hash(reverse(e)) == hash(e)
    @test PowerEdge(1, 2, 1) != PowerEdge(1, 2, 2)
end

@testitem "parallel_offsets fans only parallel circuits" tags = [:unit, :fast] setup =
    [ParallelCase] begin
    off = parallel_offsets(g; spread = 0.2)
    @test length(off) == ne(g)
    # The two circuits between 1 and 2 are pushed to opposite sides...
    @test off[1] ≈ -0.2
    @test off[2] ≈ 0.2
    # ...while single circuits stay straight.
    @test all(iszero, off[3:5])

    # An odd-sized group keeps its middle circuit straight.
    g3 = PowerGraph(2, [(1, 2), (1, 2), (1, 2)])
    @test parallel_offsets(g3; spread = 0.3) ≈ [-0.3, 0.0, 0.3]
end

@testitem "PowerGraph rejects out-of-range endpoints" tags = [:unit, :fast] begin
    using PowerPlotsMakie: PowerGraph
    @test_throws ArgumentError PowerGraph(2, [(1, 3)])
    @test_throws ArgumentError PowerGraph(2, [(0, 1)])
end
