# Interactive layout with GLMakie.
#
# Run with:  julia --project=examples examples/interactive.jl
#
#   * drag a bus with the left mouse button to place it by hand
#   * drag from empty space to rubber-band a group of buses; they are ringed in blue and
#     move together as one when any of them is dragged
#   * press `r` to re-run the layout — dragged buses stay put, the rest settle around them
#   * press `u` to release every pinned bus
#
# Dragging pins, so `r` is the interesting part: it makes layout iterative rather than a
# one-shot call.
#
# The first run spends a while compiling GLMakie and this package before the window becomes
# responsive; that cost is Julia's, not the plot's. Once running, dragging redraws in about
# 1.5 ms and a re-layout of this network takes a few milliseconds.

using GLMakie
using PowerModels
using PowerPlotsMakie

PowerModels.silence()

casefile =
    joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", "case14.m")
case = PowerModels.parse_file(casefile)

fig = Figure(size = (900, 700))
ax = Axis(
    fig[1, 1],
    title = "case14 — drag buses or rubber-band a group; r re-layouts, u unpins",
    subtitle = "generators are squares, loads triangles; buses coloured by voltage",
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

screen = display(fig)

if !isinteractive()
    @info "Drag buses; press r to re-layout, u to unpin. Close the window to exit."
    wait(screen)
end
