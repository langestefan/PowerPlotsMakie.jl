"""
Per-component styling for [`academic_theme`](@ref)'s monochrome mode.

Greyscale can only carry so much: four shades are already hard to tell apart in print, so
the components are separated by *shape* and *line style* first and by shade second. The
shapes follow one-line diagram convention as far as plain Makie markers allow — a generator
is an open circle, a load a filled triangle pointing away from the bus, a shunt a diamond.

Covers the taxonomy the PowerModels backend supplies plus the other names in the interface;
an unlisted component type still gets its colour from the usual palette rotation, so a
custom backend is not left invisible, just not monochrome.
"""
const ACADEMIC_COMPONENTS = Dict{Symbol,Any}(
    # Nodes.
    :bus => (color = "#1a1a1a", marker = :circle, size = 9.0, strokecolor = "#1a1a1a"),

    # Edges. Width and dash pattern do the work; all of them are near-black.
    :branch => (color = "#1a1a1a", width = 1.6),
    :line => (color = "#1a1a1a", width = 1.6),
    :transformer => (color = "#1a1a1a", width = 2.2),
    :dcline => (color = "#1a1a1a", width = 1.6, linestyle = :dashdot),
    :switch => (color = "#595959", width = 1.2, linestyle = :dot),

    # Injections. An open marker reads as a source, a filled one as a sink.
    :gen => (color = "#ffffff", marker = :circle, size = 11.0, strokecolor = "#1a1a1a"),
    :generator =>
        (color = "#ffffff", marker = :circle, size = 11.0, strokecolor = "#1a1a1a"),
    :voltage_source =>
        (color = "#ffffff", marker = :hexagon, size = 12.0, strokecolor = "#1a1a1a"),
    :solar =>
        (color = "#ffffff", marker = :utriangle, size = 11.0, strokecolor = "#1a1a1a"),
    :load =>
        (color = "#404040", marker = :dtriangle, size = 10.0, strokecolor = "#1a1a1a"),
    :shunt =>
        (color = "#8c8c8c", marker = :diamond, size = 9.0, strokecolor = "#1a1a1a"),
    :storage =>
        (color = "#8c8c8c", marker = :rect, size = 9.0, strokecolor = "#1a1a1a"),
)

"""
    academic_theme(; monochrome = true, font = "TeX Gyre Pagella Makie", fontsize = 11)

A Makie `Theme` for figures headed for a paper.

Print-weight strokes, a serif face, no axis furniture — a network diagram's coordinates
mean nothing, so ticks and grid lines are noise — and, by default, a monochrome palette in
which components are told apart by shape and line style rather than by hue, so the figure
survives being printed in black and white.

```julia
with_theme(academic_theme()) do
    f, ax, p = powerplot(case)
    powerlegend!(f[1, 2], p)
    save("network.pdf", f)
end
```

`monochrome = false` keeps the default colour palette and changes only the typography and
the furniture. The font must be one Makie can find; the default ships with Makie, so it is
available wherever the package is.

The theme sets ordinary Makie attributes, so it composes: pass your own on top with
`merge(Theme(...), academic_theme())`, or override per plot as usual. Axis decorations are
switched off rather than removed, so `Axis(f[1, 1]; xticksvisible = true)` brings them back
for a plot that really is drawn in geographic coordinates.
"""
function academic_theme(;
    monochrome::Bool = true,
    font::AbstractString = "TeX Gyre Pagella Makie",
    fontsize::Real = 11,
)
    hidden = (
        xgridvisible = false,
        ygridvisible = false,
        xticksvisible = false,
        yticksvisible = false,
        xticklabelsvisible = false,
        yticklabelsvisible = false,
        leftspinevisible = false,
        rightspinevisible = false,
        topspinevisible = false,
        bottomspinevisible = false,
    )

    powerplot_theme = if monochrome
        (
            node_size = 9.0,
            node_strokewidth = 0.8,
            node_strokecolor = "#1a1a1a",
            edge_width = 1.6,
            connector_color = "#8c8c8c",
            connector_width = 0.9,
            # Solid stubs: a dashed connector reads as a circuit of its own on paper.
            connector_linestyle = :solid,
            flow_color = "#1a1a1a",
            flow_size = (5.0, 13.0),
            component_defaults = ACADEMIC_COMPONENTS,
        )
    else
        (
            node_strokewidth = 0.8,
            edge_width = 1.6,
            connector_width = 0.9,
            connector_linestyle = :solid,
        )
    end

    return Makie.Theme(;
        fontsize = fontsize,
        fonts = (; regular = font, bold = font, italic = font, bold_italic = font),
        figure_padding = 6,
        backgroundcolor = :white,
        Axis = (; backgroundcolor = :white, titlesize = fontsize + 1, hidden...),
        Legend = (
            framevisible = false,
            padding = (4, 4, 4, 4),
            rowgap = 1,
            titlegap = 3,
            groupgap = 8,
        ),
        Colorbar = (size = 8, spinewidth = 0.8, ticklabelpad = 3),
        PowerPlot = powerplot_theme,
    )
end
