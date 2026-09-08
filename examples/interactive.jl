# Interactive layout with GLMakie.
#
# Run with:  julia --project=examples examples/interactive.jl
#
#   * drag a bus with the left mouse button to place it by hand
#   * drag from empty space to rubber-band a group of buses; they are ringed in blue and
#     move together as one when any of them is dragged
#   * shift- or control-click a bus to add or remove it from the selection by hand; hold
#     either while rubber-banding to widen the selection instead of replacing it
#   * right-click a bus to release just that pin
#   * press `r` to re-run the layout — pinned buses stay put, the rest settle around them
#   * press `u` to release every pinned bus
#   * pick a routing algorithm from the menu below the plot to re-route from scratch
#
# Dragging pins a bus, and every pinned bus carries a small dark dot. That is what makes
# `r` interesting: layout becomes iterative rather than a one-shot call.
#
# The first run spends a while compiling GLMakie and this package before the window becomes
# responsive; that cost is Julia's, not the plot's. Once running, dragging redraws in about
# 1.5 ms and a re-layout of this network takes a few milliseconds.

using GLMakie
using NetworkLayout
using PowerModels
using PowerPlotsMakie

PowerModels.silence()

casename = "case30"
casefile =
    joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", "$casename.m")
case = PowerModels.parse_file(casefile)

fig = Figure(size = (900, 700))
ax = Axis(
    fig[1, 1],
    title = "$casename — drag or rubber-band buses; right-click unpins, r re-layouts",
    subtitle = "rings mark the selection, dots mark pinned buses",
)
hidedecorations!(ax)
hidespines!(ax)

plt = powerplot!(
    ax,
    case;
    node_size = 16,
    components = Dict(
        :bus => (color = Field(:vm), colormap = :viridis),
        :gen => (color = :seagreen, marker = :rect, size = 14),
        :load => (color = :crimson, marker = :utriangle, size = 12),
        :shunt => (color = :slateblue, marker = :diamond, size = 10),
    ),
)

interaction = interactive!(ax, plt)

# ---------------------------------------------------------------------------------------
# Routing algorithm selector
#
# Choosing an algorithm re-routes from scratch: every pin is released and the network is
# laid out afresh, which is what you want from a menu that says "lay this out differently".
# `r` stays incremental — it relaxes from wherever the buses are now, holding the pins —
# and it follows the menu for the algorithms that can hold one. Buchheim cannot: it has no
# notion of an initial position or a fixed node, so a tree layout leaves `r` relaxing with
# Stress.
#
# Each option is a (layout, relaxer) pair: what to pass to the plot's `layout` attribute,
# and the constructor `r` should rebuild with afterwards.
# ---------------------------------------------------------------------------------------

# Makie reads a menu option as (label, value) only when it is a 2-tuple; a `label => value`
# pair is handed back whole, label and all.
const LAYOUTS = [
    ("auto (detect)", (:auto, NetworkLayout.Stress)),
    ("radial (Buchheim)", (:radial, NetworkLayout.Stress)),
    ("stress", (:stress, NetworkLayout.Stress)),
    ("spring", (NetworkLayout.Spring(), NetworkLayout.Spring)),
    ("SFDP", (NetworkLayout.SFDP(), NetworkLayout.SFDP)),
]

controls = fig[2, 1] = GridLayout(tellwidth = false)
Label(controls[1, 1], "routing algorithm:"; halign = :right)
menu = Menu(controls[1, 2]; options = LAYOUTS, default = 1, width = 220)

on(menu.selection) do (layout, relaxer)
    unpin_all!(interaction.state)
    deselect_all!(interaction.state)
    plt.pin = Int[]
    plt.layout = layout
    interaction.algorithm = relaxer
    # The interaction is still holding the positions from the old layout until told
    # otherwise; without this the next drag would snap the network back to them.
    resync!(interaction)
    autolimits!(ax)
end

screen = display(fig)

if !isinteractive()
    @info "Drag buses; press r to re-layout, u to unpin. Close the window to exit."
    wait(screen)
end
