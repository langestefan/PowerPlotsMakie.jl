@testmodule ToyBackend begin
    using PowerPlotsMakie

    """
    A deliberately minimal data model, unrelated to PowerModels, that exists to prove the
    backend interface is genuinely pluggable: implementing five functions is enough to make
    an arbitrary data type plottable.
    """
    struct ToyNet
        buses::Vector{String}
        # id => (from, to)
        branches::Vector{Pair{String,Tuple{String,String}}}
        # id => bus
        gens::Vector{Pair{String,String}}
        loads::Vector{Pair{String,String}}
    end

    PowerPlotsMakie.component_types(::ToyNet, ::NodeRole) = [:bus]
    PowerPlotsMakie.component_types(::ToyNet, ::EdgeRole) = [:branch]
    PowerPlotsMakie.component_types(::ToyNet, ::InjectionRole) = [:gen, :load]

    function PowerPlotsMakie.component_ids(n::ToyNet, comp::Symbol)
        comp === :bus && return n.buses
        comp === :branch && return first.(n.branches)
        comp === :gen && return first.(n.gens)
        comp === :load && return first.(n.loads)
        return String[]
    end

    function PowerPlotsMakie.component_field(n::ToyNet, comp::Symbol, id, field::Symbol)
        comp === :bus && field === :vm && return 1.0 + findfirst(==(id), n.buses) / 100
        comp === :branch && field === :pf && return length(id) * 1.0
        return missing
    end

    function PowerPlotsMakie.edge_endpoints(n::ToyNet, ::Symbol, id)
        return last(n.branches[findfirst(p -> first(p) == id, n.branches)])
    end

    function PowerPlotsMakie.injection_bus(n::ToyNet, comp::Symbol, id)
        table = comp === :gen ? n.gens : n.loads
        return last(table[findfirst(p -> first(p) == id, table)])
    end

    PowerPlotsMakie.reference_nodes(n::ToyNet) = [first(n.buses)]

    "Three buses, a parallel pair of branches A-B, one gen on A and one load on C."
    toy() = ToyNet(
        ["A", "B", "C"],
        ["l1" => ("A", "B"), "l2" => ("A", "B"), "l3" => ("B", "C")],
        ["g1" => "A"],
        ["d1" => "C"],
    )
end

@testitem "A custom backend is enough to build a network" tags = [:unit, :fast] setup = [
    ToyBackend,
] begin
    using Graphs
    net = powernetwork(ToyBackend.toy())

    @test nv(net) == 5          # 3 buses + gen + load
    @test ne(net) == 5          # 3 branches + 2 connectors
    @test net.vertices == [
        ComponentRef(:bus, "A"), ComponentRef(:bus, "B"), ComponentRef(:bus, "C"),
        ComponentRef(:gen, "g1"), ComponentRef(:load, "d1"),
    ]
    @test edge_components(net) == [:branch, :branch, :branch, :connector, :connector]
    @test vertex_components(net) == [:bus, :bus, :bus, :gen, :load]
end

@testitem "Vertices are ordered nodes first, then injections" tags = [:unit, :fast] setup = [
    ToyBackend,
] begin
    net = powernetwork(ToyBackend.toy())
    nodes = vertex_indices(net, NodeRole())
    injections = vertex_indices(net, InjectionRole())
    @test nodes == [1, 2, 3]
    @test injections == [4, 5]
    # The ordering underpins the palette rotation, so it must not drift.
    @test maximum(nodes) < minimum(injections)
end

@testitem "Connectors join each injection to its bus" tags = [:unit, :fast] setup = [
    ToyBackend,
] begin
    using Graphs: src, dst, edges
    net = powernetwork(ToyBackend.toy())
    conn = edge_indices(net, InjectionRole())
    @test length(conn) == 2
    e = collect(edges(net.graph))
    # gen g1 sits on bus A (vertex 1) and is itself vertex 4
    @test (src(e[conn[1]]), dst(e[conn[1]])) == (1, 4)
    # load d1 sits on bus C (vertex 3) and is itself vertex 5
    @test (src(e[conn[2]]), dst(e[conn[2]])) == (3, 5)
end

@testitem "Parallel branches survive the build" tags = [:unit, :fast] setup = [ToyBackend] begin
    using PowerPlotsMakie: multiplicity, parallel_offsets
    using Graphs: edges
    net = powernetwork(ToyBackend.toy())
    e = collect(edges(net.graph))
    # l1 and l2 both run A-B and must remain two separate drawable edges.
    @test multiplicity(e[1]) == 1
    @test multiplicity(e[2]) == 2
    @test net.edges[1].id == "l1"
    @test net.edges[2].id == "l2"
    off = parallel_offsets(net.graph)
    @test off[1] < 0 < off[2]
    @test iszero(off[3])
end

@testitem "Column lookup yields per-index vectors with missing" tags = [:unit, :fast] setup = [
    ToyBackend,
] begin
    using Graphs
    net = powernetwork(ToyBackend.toy())

    vm = vertex_column(net, :vm)
    @test length(vm) == nv(net)
    @test vm[1:3] == [1.01, 1.02, 1.03]
    @test all(ismissing, vm[4:5])       # injections have no voltage magnitude

    pf = edge_column(net, :pf)
    @test length(pf) == ne(net)
    @test pf[1:3] == [2.0, 2.0, 2.0]
    @test all(ismissing, pf[4:5])       # connectors are synthetic, never queried

    # `:component` is the implicit field every component has, and the default colour field.
    @test vertex_column(net, :component) == vertex_components(net)
end

@testitem "present_components skips empty component types" tags = [:unit, :fast] setup = [
    ToyBackend,
] begin
    net = powernetwork(ToyBackend.toy())
    @test present_components(net, NodeRole()) == [:bus]
    @test present_components(net, EdgeRole()) == [:branch]
    @test present_components(net, InjectionRole()) == [:gen, :load]

    # A network with no loads must not leave a hole in the list, because palette slots are
    # handed out only to components that are actually present.
    bare = ToyBackend.ToyNet(["A", "B"], ["l1" => ("A", "B")], ["g1" => "A"], [])
    @test present_components(powernetwork(bare), InjectionRole()) == [:gen]
end

@testitem "Unsupported data gives an actionable error" tags = [:unit, :fast] begin
    @test_throws ArgumentError powernetwork(42)
    err = try
        powernetwork(42)
    catch e
        sprint(showerror, e)
    end
    @test occursin("No PowerPlotsMakie backend is loaded", err)
    @test occursin("using PowerModels", err)
end
