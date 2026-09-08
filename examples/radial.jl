# Interactive layout of a radial distribution feeder with GLMakie.
#
# Run with:  julia --project=examples examples/radial.jl
#
#   * drag a bus with the left mouse button to place it by hand
#   * drag from empty space to rubber-band a group of buses; they are ringed in blue and
#     move together as one when any of them is dragged
#   * shift- or control-click a bus to add or remove it from the selection by hand; hold
#     either while rubber-banding to widen the selection instead of replacing it
#   * right-click a bus to release just that pin
#   * press `r` to relax the layout — pinned buses stay put, the rest settle around them
#   * press `u` to release every pinned bus
#
# This network is a tree, so `layout = :auto` detects it (`isradial`) and lays it out with
# `RadialTree`, a wrapper around NetworkLayout's Buchheim: the substation sits at the top
# and depth in the drawing is depth in the feeder. Compare it with `layout = :stress`,
# which is what `:auto` falls back to for a meshed network — the tree structure is still
# there, but you have to trace it.
#
# One thing to know about `r` here. Buchheim is a one-shot layout with no notion of an
# initial position or a pinned node, so re-layout uses `Stress` seeded from wherever the
# buses currently are. That means `r` *relaxes* the tree rather than redrawing it: the
# structure loosens into a force-directed shape, holding whatever you have pinned. It is
# a genuinely useful second step — lay the tree out, pin the buses whose place you care
# about, then relax the rest — but it is not a way to get the tree back. For that,
# re-run the script.
#
# There is no PowerModels here: the feeder below is described by implementing five
# functions of the backend interface, which is all it takes to make any data type
# plottable.

using GLMakie
using PowerPlotsMakie

# ---------------------------------------------------------------------------------------
# A 17-bus MV feeder: a substation, a trunk, and three laterals.
# ---------------------------------------------------------------------------------------

"""
The feeder as a list of paths — each entry is a run of buses joined end to end, which is
how a feeder is actually described: a trunk out of the substation and three laterals, two
of which branch again.
"""
const PATHS = [
    ["SS", "T1", "T2"],              # substation transformer and trunk
    ["T2", "A1", "A2", "A3"],        # lateral A
    ["A2", "A4"],
    ["T2", "B1", "B2", "B3"],        # lateral B
    ["B1", "B4", "B5"],
    ["T2", "C1", "C2", "C3"],        # lateral C
    ["C2", "C4", "C5"],
]

const BRANCHES = [(p[i], p[i+1]) for p in PATHS for i = 1:(length(p)-1)]

const LOAD_BUSES = ["A3", "A4", "B2", "B3", "B5", "C3", "C5"]
const GEN_BUSES = ["SS", "A2", "C4"]      # grid infeed plus two embedded generators

"""
Per-unit voltage, falling with distance from the substation.

Real enough for the plot to say something: colouring the buses by it shows the voltage
drop along each lateral, which is the thing a feeder diagram is usually drawn to show.
"""
function bus_voltages(branches, root)
    depth = Dict(root => 0)
    changed = true
    while changed                          # the feeder is tiny; repeated sweeps are plenty
        changed = false
        for (f, t) in branches
            for (a, b) in ((f, t), (t, f))
                if haskey(depth, a) && !haskey(depth, b)
                    depth[b] = depth[a] + 1
                    changed = true
                end
            end
        end
    end
    return Dict(bus => 1.03 - 0.011 * d for (bus, d) in depth)
end

"A feeder described only by its topology, plus a voltage per bus."
struct Feeder
    branches::Vector{Tuple{String,String}}
    loads::Vector{String}
    gens::Vector{String}
    vm::Dict{String,Float64}
    buses::Vector{String}
end

function Feeder(branches, loads, gens)
    buses = String[]
    for (f, t) in branches, b in (f, t)
        b in buses || push!(buses, b)
    end
    return Feeder(branches, loads, gens, bus_voltages(branches, first(buses)), buses)
end

# The whole backend: five functions, plus two optional ones.
PowerPlotsMakie.component_types(::Feeder, ::NodeRole) = [:bus]
PowerPlotsMakie.component_types(::Feeder, ::EdgeRole) = [:branch]
PowerPlotsMakie.component_types(::Feeder, ::InjectionRole) = [:gen, :load]

function PowerPlotsMakie.component_ids(f::Feeder, comp::Symbol)
    comp === :bus && return f.buses
    comp === :branch && return string.(1:length(f.branches))
    comp === :gen && return f.gens
    comp === :load && return f.loads
    return String[]
end

function PowerPlotsMakie.component_field(f::Feeder, comp::Symbol, id, field::Symbol)
    comp === :bus && field === :vm && return f.vm[id]
    return missing
end

PowerPlotsMakie.edge_endpoints(f::Feeder, ::Symbol, id) = f.branches[parse(Int, id)]
PowerPlotsMakie.injection_bus(::Feeder, ::Symbol, id) = id      # injections are named
PowerPlotsMakie.reference_nodes(f::Feeder) = [first(f.buses)]   # the substation roots it

# ---------------------------------------------------------------------------------------

net = powernetwork(Feeder(BRANCHES, LOAD_BUSES, GEN_BUSES))
@info "Feeder built" net radial = isradial(net)

fig = Figure(size = (1000, 760))
ax = Axis(
    fig[1, 1],
    title = "A radial feeder — drag or rubber-band buses; right-click unpins, r relaxes",
    subtitle = "buses coloured by voltage; rings mark the selection, dots mark pinned buses",
)
hidedecorations!(ax)
hidespines!(ax)

plt = powerplot!(
    ax,
    net;
    layout = :auto,                 # detects the tree and reaches for RadialTree
    node_size = 17,
    components = Dict(
        :bus => (color = Field(:vm), colormap = :viridis),
        :gen => (color = :seagreen, marker = :rect, size = 14),
        :load => (color = :crimson, marker = :utriangle, size = 13),
    ),
)

interaction = interactive!(ax, plt)

screen = display(fig)

if !isinteractive()
    @info "Drag buses; press r to relax the layout, u to unpin. Close the window to exit."
    wait(screen)
end
