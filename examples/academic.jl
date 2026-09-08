# A figure for a paper: DC power flow on the IEEE 14-bus case, drawn in the academic theme.
#
# Run with:  julia --project=examples examples/academic.jl
#
# Nothing here is interactive. CairoMakie writes vector output, the theme takes the colour
# out and the axis furniture off, and the arrows say where the power goes — which is the
# whole point of plotting a solved case rather than a topology.
#
# The flows are a real DC power flow, not an invention: `compute_basic_dc_pf` solves for
# the bus voltage angles and `calc_branch_flow_dc` turns those into branch flows, both by
# linear algebra alone, so this example needs no optimizer.

using CairoMakie
using PowerModels
using PowerPlotsMakie

PowerModels.silence()

casefile =
    joinpath(dirname(pathof(PowerModels)), "..", "test", "data", "matpower", "case14.m")

# `make_basic_network` renumbers everything into the contiguous form the basic solvers
# expect, which is also what makes `bus[string(i)]` line up with the angle vector below.
case = PowerModels.make_basic_network(PowerModels.parse_file(casefile))

angles = PowerModels.compute_basic_dc_pf(case)
for (i, angle) in enumerate(angles)
    case["bus"][string(i)]["va"] = angle
end
PowerModels.update_data!(case, PowerModels.calc_branch_flow_dc(case))

fig = with_theme(academic_theme()) do
    fig = Figure(size = (660, 420))
    ax = Axis(fig[1, 1], title = "IEEE 14-bus test case, DC power flow")

    plot = powerplot!(
        ax,
        case;
        # `true` is shorthand for `Field(:pf)`: active power leaving the from-bus, which is
        # what `update_data!` has just written into every branch.
        flow = true,
        components = Dict(:bus => (color = Field(:vm), colormap = :grays)),
    )

    # One legend for the components, one colorbar for the voltages.
    powerlegend!(fig[1, 2], plot)
    return fig
end

out = joinpath(tempdir(), "powerplotsmakie-academic.pdf")
save(out, fig)
save(replace(out, ".pdf" => ".png"), fig; px_per_unit = 3)
@info "wrote the figure" out
