@testsnippet ColorTools begin
    using PowerPlotsMakie
    using PowerPlotsMakie:
        COLOR_SCHEMES,
        COMPONENT_COLOR_ORDER,
        CONNECTOR_COLOR,
        MISSING_COLOR,
        ColorResult,
        assign_schemes,
        component_spec,
        infer_colormode,
        resolve_color,
        resolve_numeric
    using Colors: Colorant
    using Makie: RGBAf

    hexcolor(s) = RGBAf(parse(Colorant, s))
end

@testitem "Palette matches PowerPlots" tags = [:unit, :fast] setup = [ColorTools] begin
    # The first five schemes in rotation order, dark ends, as ported from
    # PowerPlots/src/core/options.jl:2-38.
    @test COMPONENT_COLOR_ORDER[1:4] == [:blues, :greens, :oranges, :reds]
    @test first(COLOR_SCHEMES[:blues]) ≈ hexcolor("#3182BD")
    @test last(COLOR_SCHEMES[:blues]) ≈ hexcolor("#C6DBEF")
    @test first(COLOR_SCHEMES[:greens]) ≈ hexcolor("#31A354")
    @test first(COLOR_SCHEMES[:oranges]) ≈ hexcolor("#E6550D")
    @test first(COLOR_SCHEMES[:reds]) ≈ hexcolor("#CB181D")
    @test all(s -> length(s) == 5, values(COLOR_SCHEMES))
    @test length(COMPONENT_COLOR_ORDER) == 16
end

@testitem "Scheme assignment follows node/edge/injection order" tags = [:unit, :fast] setup =
    [ColorTools, ToyBackend] begin
    net = powernetwork(ToyBackend.toy())
    schemes = assign_schemes(net)
    # bus -> blues, branch -> greens, gen -> oranges, load -> reds, as in PowerPlots.
    @test schemes[:bus] == :blues
    @test schemes[:branch] == :greens
    @test schemes[:gen] == :oranges
    @test schemes[:load] == :reds
    @test !haskey(schemes, :connector)   # connectors sit outside the rotation
end

@testitem "An absent component consumes no palette slot" tags = [:unit, :fast] setup =
    [ColorTools, ToyBackend] begin
    # With no loads, gen must still take the third slot rather than shifting.
    bare = ToyBackend.ToyNet(["A", "B"], ["l1" => ("A", "B")], ["g1" => "A"], [])
    schemes = assign_schemes(powernetwork(bare))
    @test schemes[:bus] == :blues
    @test schemes[:branch] == :greens
    @test schemes[:gen] == :oranges
    @test !haskey(schemes, :load)
end

@testitem "Default colour is the dark end of the scheme" tags = [:unit, :fast] setup =
    [ColorTools] begin
    # No instruction at all: PowerPlots colours by ComponentType, leaving one category per
    # component, and Vega picks the first entry of the range.
    r = resolve_color([1, 2, 3], NamedTuple(), :blues)
    @test r.kind === :constant
    @test all(==(hexcolor("#3182BD")), r.colors)
    @test length(r.colors) == 3
end

@testitem "A literal colour overrides the palette" tags = [:unit, :fast] setup =
    [ColorTools] begin
    for request in (:red, "red", RGBAf(1, 0, 0, 1))
        r = resolve_color([1, 2], (color = request,), :blues)
        @test r.kind === :constant
        @test all(==(RGBAf(1, 0, 0, 1)), r.colors)
    end
end

@testitem "Field with numbers gives a continuous ramp" tags = [:unit, :fast] setup =
    [ColorTools] begin
    r = resolve_color([0.0, 0.5, 1.0], (color = Field(:vm),), :blues)
    @test r.kind === :continuous
    @test r.field === :vm
    @test r.colorrange == (0.0, 1.0)
    # Ends of the data map to ends of the ramp.
    @test r.colors[1] ≈ first(COLOR_SCHEMES[:blues])
    @test r.colors[3] ≈ last(COLOR_SCHEMES[:blues])
    @test r.colors[2] != r.colors[1]
end

@testitem "colorrange overrides the data extrema" tags = [:unit, :fast] setup = [ColorTools] begin
    r = resolve_color([0.0, 1.0], (color = Field(:x), colorrange = (-1.0, 2.0)), :blues)
    @test r.colorrange == (-1.0, 2.0)
    # Neither value now sits at an end of the ramp.
    @test r.colors[1] != first(COLOR_SCHEMES[:blues])
    @test r.colors[2] != last(COLOR_SCHEMES[:blues])
end

@testitem "A constant field does not divide by zero" tags = [:unit, :fast] setup =
    [ColorTools] begin
    r = resolve_color([2.0, 2.0, 2.0], (color = Field(:x),), :blues)
    @test r.kind === :continuous
    @test all(isfinite, (r.colorrange[1], r.colorrange[2]))
    @test r.colorrange[1] < r.colorrange[2]
    @test all(==(r.colors[1]), r.colors)  # every value lands at the same point on the ramp
    @test all(c -> all(isfinite, (c.r, c.g, c.b)), r.colors)
end

@testitem "Field with categories gives a palette" tags = [:unit, :fast] setup = [ColorTools] begin
    r = resolve_color(["a", "b", "a", "c"], (color = Field(:kind),), :blues)
    @test r.kind === :categorical
    @test r.categories == ["a", "b", "c"]
    @test length(r.swatches) == 3
    @test r.colors[1] == r.colors[3]     # same category, same colour
    @test r.colors[1] != r.colors[2]
end

@testitem "Missing values get the missing colour" tags = [:unit, :fast] setup = [ColorTools] begin
    r = resolve_color([1.0, missing, 3.0], (color = Field(:x),), :blues)
    @test r.colors[2] == MISSING_COLOR
    c = resolve_color(["a", missing], (color = Field(:x),), :blues)
    @test c.colors[2] == MISSING_COLOR
end

@testitem "colormode overrides inference" tags = [:unit, :fast] setup = [ColorTools] begin
    # bus_type is an integer code: numeric, but meaning categories.
    values = [1, 1, 2, 3]
    @test infer_colormode(values) === :continuous
    @test infer_colormode(["a", "b"]) === :categorical
    @test infer_colormode([missing, missing]) === :categorical

    forced =
        resolve_color(values, (color = Field(:bus_type), colormode = :categorical), :blues)
    @test forced.kind === :categorical
    @test forced.categories == [1, 2, 3]
end

@testitem "An explicit palette wins over the scheme" tags = [:unit, :fast] setup =
    [ColorTools] begin
    r = resolve_color(["a", "b"], (color = Field(:k), palette = [:red, :blue]), :blues)
    @test r.swatches[1] == RGBAf(1, 0, 0, 1)
    @test r.swatches[2] == RGBAf(0, 0, 1, 1)
end

@testitem "A per-index colour vector passes through" tags = [:unit, :fast] setup =
    [ColorTools] begin
    r = resolve_color([1, 2], (color = [:red, :blue],), :blues)
    @test r.colors == [RGBAf(1, 0, 0, 1), RGBAf(0, 0, 1, 1)]
end

@testitem "resolve_numeric handles constants, vectors and fields" tags = [:unit, :fast] setup =
    [ColorTools] begin
    @test resolve_numeric([1, 2, 3], nothing, 7.0) == [7.0, 7.0, 7.0]
    @test resolve_numeric([1, 2, 3], 4, 7.0) == [4.0, 4.0, 4.0]
    @test resolve_numeric([1, 2, 3], [1, 2, 3], 7.0) == [1.0, 2.0, 3.0]

    scaled = resolve_numeric([0.0, 1.0], Field(:x), 7.0; range = (5.0, 25.0))
    @test scaled == [5.0, 25.0]
    # A field with no usable values falls back to the default rather than producing NaN.
    @test resolve_numeric([missing, missing], Field(:x), 7.0) == [7.0, 7.0]
end

@testitem "component_spec accepts Dicts and pair vectors" tags = [:unit, :fast] setup =
    [ColorTools] begin
    d = Dict(:bus => (color = :red,))
    @test component_spec(d, :bus) == (color = :red,)
    @test component_spec(d, :branch) == NamedTuple()

    v = [:bus => (color = :red,), :branch => (width = 2,)]
    @test component_spec(v, :branch) == (width = 2,)
    @test component_spec(v, :gen) == NamedTuple()

    @test component_spec(nothing, :bus) == NamedTuple()
end
