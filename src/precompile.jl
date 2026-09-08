"""
    _PrecompileFixture

A tiny network used only to exercise the plotting path during precompilation.

The first `powerplot` call in a fresh session spends around ten seconds compiling this
package together with GraphMakie and Makie's recipe machinery, which is most of the delay
before an interactive window becomes usable. Running the same path here moves that cost
into package precompilation, where it is paid once at install time instead of on every
startup.

It is a private backend rather than a `PowerModels` case because `PowerModels` is a weak
dependency and is not available while this package precompiles. The fixture implements the
same interface any backend does, so the code traced here is the code a real plot runs.
"""
struct _PrecompileFixture end

component_types(::_PrecompileFixture, ::NodeRole) = [:bus]
component_types(::_PrecompileFixture, ::EdgeRole) = [:branch]
component_types(::_PrecompileFixture, ::InjectionRole) = [:gen, :load]

function component_ids(::_PrecompileFixture, comp::Symbol)
    comp === :bus && return ["1", "2", "3"]
    # Two circuits between the same pair, so the parallel-edge path is compiled too.
    comp === :branch && return ["1", "2", "3"]
    comp === :gen && return ["1"]
    comp === :load && return ["1"]
    return String[]
end

function component_field(
    ::_PrecompileFixture,
    comp::Symbol,
    id::AbstractString,
    field::Symbol,
)
    field === :vm && comp === :bus && return 1.0 + parse(Int, id) / 100
    field === :kind && return isodd(parse(Int, id)) ? "a" : "b"
    return missing
end

function edge_endpoints(::_PrecompileFixture, ::Symbol, id::AbstractString)
    id == "3" && return ("2", "3")
    return ("1", "2")            # ids "1" and "2" are parallel circuits
end

injection_bus(::_PrecompileFixture, comp::Symbol, ::AbstractString) =
    comp === :gen ? "1" : "3"

reference_nodes(::_PrecompileFixture) = ["1"]

@setup_workload begin
    fixture = _PrecompileFixture()
    @compile_workload begin
        net = powernetwork(fixture)

        # A default plot, and the two data-driven colour modes.
        powerplot(net)
        powerplot(net; components = Dict(:bus => (color = Field(:vm),)))
        powerplot(
            net;
            components = Dict(:bus => (color = Field(:kind), colormode = :categorical)),
            node_size = 10,
        )

        # The interaction state machine, which is pure and cheap to trace.
        state = LayoutState(layout_positions(net))
        drag!(state, 1, Point2f(0.5, 0.5))
        select!(state, (1, 2))
        drag_group!(state, Dict(1 => Point2f(0, 0), 2 => Point2f(1, 1)), Point2f(0.1, 0.1))
        relayout!(state, net.graph)
    end
end
