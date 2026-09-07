@testsnippet MatpowerCases begin
    using PowerModels
    using PowerPlotsMakie
    using Graphs

    PowerModels.silence()

    "Path to a MATPOWER case shipped with PowerModels."
    casepath(name) =
        joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", name)
    readcase(name) = PowerModels.parse_file(casepath(name))
end

@testitem "PowerModels case5 builds the expected graph" tags = [:integration] setup =
    [MatpowerCases] begin
    net = powernetwork(readcase("case5.m"))

    @test length(vertex_indices(net, NodeRole())) == 5        # buses
    @test length(edge_indices(net, EdgeRole())) == 7          # branches
    @test length(vertex_indices(net, :gen)) == 5
    @test length(vertex_indices(net, :load)) == 3
    # Every injection gets exactly one connector.
    @test length(edge_indices(net, InjectionRole())) ==
          length(vertex_indices(net, InjectionRole()))
    @test nv(net) == 13
    @test ne(net) == 15
    @test present_components(net, EdgeRole()) == [:branch]
end

@testitem "Bus ids sort numerically, not lexicographically" tags = [:integration] setup =
    [MatpowerCases] begin
    net = powernetwork(readcase("case5.m"))
    buses = [r.id for r in net.vertices if r.component === :bus]
    # case5 has a bus "10": a lexicographic sort would put it before "2".
    @test buses == ["1", "2", "3", "4", "10"]
end

@testitem "Parallel circuits are preserved from real cases" tags = [:integration] setup =
    [MatpowerCases] begin
    using PowerPlotsMakie: multiplicity
    for (name, expected) in ("case5.m" => 1, "case14.m" => 0, "case24.m" => 4)
        net = powernetwork(readcase(name))
        extra = count(e -> multiplicity(e) > 1, edges(net.graph))
        @test extra == expected
    end
end

@testitem "Reference bus is the slack bus" tags = [:integration] setup = [MatpowerCases] begin
    @test reference_nodes(readcase("case5.m")) == ["4"]
    @test reference_nodes(readcase("case14.m")) == ["1"]
    @test reference_nodes(readcase("case24.m")) == ["13"]
end

@testitem "Fields resolve, with missing for absent data" tags = [:integration] setup =
    [MatpowerCases] begin
    net = powernetwork(readcase("case5.m"))

    vm = vertex_column(net, :vm)
    @test all(!ismissing, vm[vertex_indices(net, :bus)])
    @test all(ismissing, vm[vertex_indices(net, InjectionRole())])

    # An unsolved case has no power flow results anywhere.
    @test all(ismissing, edge_column(net, :pf))
    # Connectors are synthetic and never carry component data.
    @test all(ismissing, edge_column(net, :rate_a)[edge_indices(net, InjectionRole())])
end

@testitem "Switches and DC lines become edges" tags = [:integration] setup = [MatpowerCases] begin
    sw = powernetwork(readcase("case5_sw.m"))
    @test :switch in present_components(sw, EdgeRole())

    dc = powernetwork(readcase("case5_dc.m"))
    @test :dcline in present_components(dc, EdgeRole())
end

@testitem "Storage becomes an injection" tags = [:integration] setup = [MatpowerCases] begin
    net = powernetwork(readcase("case5_strg.m"))
    @test :storage in present_components(net, InjectionRole())
    @test !isempty(vertex_indices(net, :storage))
end

@testitem "Pre-existing bus coordinates are picked up" tags = [:integration] setup =
    [MatpowerCases] begin
    case = readcase("case5.m")
    @test node_coordinates(case, :bus, "1") === nothing
    case["bus"]["1"]["xcoord_1"] = 3.0
    case["bus"]["1"]["ycoord_1"] = -1.5
    p = node_coordinates(case, :bus, "1")
    @test p !== nothing
    @test (p[1], p[2]) == (3.0f0, -1.5f0)
end
