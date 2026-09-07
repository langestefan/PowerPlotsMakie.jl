"""
    Field(name)

Marks a plot attribute as driven by a data field rather than given literally.

`color = :red` is a constant colour; `color = Field(:vm)` colours each component by its
voltage magnitude. The wrapper exists because a bare `Symbol` is ambiguous — `:red` is both
a colour name and a plausible field name. PowerPlots.jl avoids the ambiguity by splitting
the concept across two keyword arguments (`:color` and `:data`); marking the field is the
same idea with one attribute instead of two.

```julia
components = Dict(:bus => (color = Field(:vm), colormap = :viridis))
```
"""
struct Field
    name::Symbol
end

Base.show(io::IO, f::Field) = print(io, "Field(:$(f.name))")

# ---------------------------------------------------------------------------------------
# Palettes
#
# Ported from PowerPlots.jl (BSD-3-Clause, Board of Regents of the University of Wisconsin
# System), src/core/options.jl:2-38, so that a default plot keeps the colours users of that
# package will recognise. Each scheme is a five-stop ramp from dark to light.
# ---------------------------------------------------------------------------------------

const _SCHEME_ENDPOINTS = [
    :blues => ("#3182BD", "#C6DBEF"),
    :greens => ("#31A354", "#C7E9C0"),
    :oranges => ("#E6550D", "#FDD0A2"),
    :reds => ("#CB181D", "#FCBBA1"),
    :purples => ("#756BB1", "#DADAEB"),
    :browns => ("#8C6D31", "#E7CB94"),
    :pinks => ("#e7298a", "#fbb3cc"),
    :yellows => ("#ffc108", "#ffef79"),
    :lime => ("#8df33c", "#c8ff87"),
    :violet => ("#8f3f8f", "#d6a0d6"),
    :cyan => ("#00ffff", "#99ffff"),
    :magenta => ("#ff00ff", "#ff99ff"),
    :indigo => ("#4b0082", "#9b59b6"),
    :cherry => ("#ff0000", "#ff9999"),
    :teal => ("#2a8482", "#46e1d1"),
    :grays => ("#555555", "#FFFFFF"),
]

"Five-stop dark-to-light ramps, keyed by scheme name."
const COLOR_SCHEMES = Dict{Symbol,Vector{RGBAf}}(
    name => [RGBAf(c) for c in range(parse(Colorant, lo), parse(Colorant, hi); length = 5)]
    for (name, (lo, hi)) in _SCHEME_ENDPOINTS
)

"""
The order in which schemes are handed out to component types.

Matching PowerPlots.jl, a default PowerModels case comes out as bus = blues,
branch = greens, gen = oranges, load = reds.
"""
const COMPONENT_COLOR_ORDER = first.(_SCHEME_ENDPOINTS)

"Colour of the synthesized connector edges, which sit outside the palette rotation."
const CONNECTOR_COLOR = RGBAf(0.5, 0.5, 0.5, 1.0)

"Colour used where a component has no value for the field driving its colour."
const MISSING_COLOR = RGBAf(0.7, 0.7, 0.7, 1.0)

"""
    assign_schemes(net) -> Dict{Symbol,Symbol}

Hand out a colour scheme to every component type present in `net`.

Only component types that actually have instances consume a slot, so an absent component
does not shift the colours of the others — the behaviour of
`PowerPlots/src/core/utils.jl:16-36`, and the reason `present_components` exists. The
rotation runs over node types, then edge types, then injections. Connectors are excluded
and keep [`CONNECTOR_COLOR`](@ref).
"""
function assign_schemes(net::PowerNetwork)
    schemes = Dict{Symbol,Symbol}()
    i = 1
    for role in (NodeRole(), EdgeRole(), InjectionRole())
        for comp in present_components(net, role)
            schemes[comp] = COMPONENT_COLOR_ORDER[mod1(i, length(COMPONENT_COLOR_ORDER))]
            i += 1
        end
    end
    return schemes
end

"""
    ColorResult

Resolved colours for one component type, plus what a legend or colorbar would need to
describe them.

Everything is baked down to explicit `RGBAf` because the whole network is drawn by a single
`graphplot`, and Makie has no notion of a per-index colormap: components with different
colormaps can only coexist as literal colours. The legend metadata carried here is what
lets the colorbars be rebuilt afterwards.
"""
struct ColorResult
    colors::Vector{RGBAf}
    kind::Symbol                       # :constant, :categorical or :continuous
    field::Union{Nothing,Symbol}
    categories::Vector{Any}            # categorical: the distinct values, in order
    swatches::Vector{RGBAf}            # categorical: one colour per category
    colormap::Vector{RGBAf}            # continuous: the ramp
    colorrange::Tuple{Float64,Float64} # continuous: low and high
end

_constant_result(c, n) =
    ColorResult(fill(c, n), :constant, nothing, [], [c], [c], (0.0, 1.0))

"""
    infer_colormode(values) -> Symbol

Decide whether a field should be drawn with a continuous colormap or a categorical palette.

Real numbers get a colormap; anything else (strings, symbols, booleans) gets a palette.
PowerPlots makes the user say so via `data_type`; inferring it is right far more often than
not, and `colormode` overrides it when the guess is wrong — notably for integer codes such
as `bus_type`, which are numbers but mean categories.
"""
function infer_colormode(values)
    present = Iterators.filter(!ismissing, values)
    isempty(present) && return :categorical
    return all(v -> v isa Real, present) ? :continuous : :categorical
end

"""
    resolve_color(values, spec, scheme) -> ColorResult

Turn one component's colour specification into per-index colours.

`values` are the field values for that component's indices (only consulted when the spec
names a [`Field`](@ref)), `spec` is the user's per-component settings, and `scheme` is the
palette slot assigned by [`assign_schemes`](@ref).

Three modes, matching PowerPlots' three:

  - a literal colour, or anything Makie can parse as one, gives a constant colour;
  - `Field(f)` over non-numeric values gives categorical colours drawn across the scheme;
  - `Field(f)` over numbers gives a continuous ramp, with `colorrange` defaulting to the
    extrema of the data.

A vector of colours of the right length is passed through untouched, which is the usual
Makie escape hatch.
"""
function resolve_color(values, spec, scheme::Symbol)
    n = length(values)
    ramp = get(spec, :colormap, nothing)
    ramp = ramp === nothing ? COLOR_SCHEMES[scheme] : _as_ramp(ramp)
    request = get(spec, :color, nothing)

    # No instruction: take the darkest end of the assigned scheme. This reproduces the
    # PowerPlots default, where colouring by ComponentType leaves each component with a
    # single category and Vega picks the first entry of the scale range.
    request === nothing && return _constant_result(first(ramp), n)

    if request isa AbstractVector && length(request) == n
        return ColorResult(
            RGBAf.(to_color.(request)), :constant, nothing, [], RGBAf[], ramp, (0.0, 1.0),
        )
    end
    request isa Field || return _constant_result(RGBAf(to_color(request)), n)

    field = request.name
    mode = get(spec, :colormode, :auto)
    mode === :auto && (mode = infer_colormode(values))

    if mode === :continuous
        return _continuous_color(values, spec, ramp, field)
    else
        return _categorical_color(values, spec, ramp, field)
    end
end

function _continuous_color(values, spec, ramp, field)
    numeric = [v isa Real ? Float64(v) : NaN for v in values]
    finite = filter(isfinite, numeric)
    range_ = get(spec, :colorrange, nothing)
    lo, hi = if range_ !== nothing
        Float64(first(range_)), Float64(last(range_))
    elseif isempty(finite)
        0.0, 1.0
    else
        Float64(minimum(finite)), Float64(maximum(finite))
    end
    # A degenerate range would divide by zero; centre it instead so every value lands
    # mid-ramp rather than at an arbitrary end.
    lo == hi && ((lo, hi) = (lo - 0.5, hi + 0.5))

    colors = map(numeric) do v
        isfinite(v) ? _sample(ramp, clamp((v - lo) / (hi - lo), 0.0, 1.0)) : MISSING_COLOR
    end
    return ColorResult(colors, :continuous, field, [], RGBAf[], ramp, (lo, hi))
end

function _categorical_color(values, spec, ramp, field)
    palette = get(spec, :palette, nothing)
    categories = unique(skipmissing(values))
    try
        sort!(categories)
    catch
        # Values that do not define an order (mixed types) keep first-seen order.
    end
    k = length(categories)
    swatches = if palette !== nothing
        [RGBAf(to_color(c)) for c in Iterators.take(Iterators.cycle(palette), max(k, 1))]
    elseif k <= 1
        [first(ramp)]
    else
        [_sample(ramp, (i - 1) / (k - 1)) for i in 1:k]
    end

    lookup = Dict(c => swatches[i] for (i, c) in enumerate(categories))
    colors = [ismissing(v) ? MISSING_COLOR : lookup[v] for v in values]
    return ColorResult(
        colors, :categorical, field, collect(categories), swatches, ramp, (0.0, 1.0),
    )
end

"Sample a ramp at `t ∈ [0, 1]`, interpolating between its stops."
function _sample(ramp::Vector{RGBAf}, t::Real)
    length(ramp) == 1 && return only(ramp)
    x = clamp(t, 0.0, 1.0) * (length(ramp) - 1) + 1
    i = clamp(floor(Int, x), 1, length(ramp) - 1)
    f = Float32(x - i)
    a, b = ramp[i], ramp[i + 1]
    return RGBAf(
        a.r + f * (b.r - a.r),
        a.g + f * (b.g - a.g),
        a.b + f * (b.b - a.b),
        a.alpha + f * (b.alpha - a.alpha),
    )
end

_as_ramp(x::Symbol) = haskey(COLOR_SCHEMES, x) ? COLOR_SCHEMES[x] :
                      [RGBAf(c) for c in Makie.to_colormap(x)]
_as_ramp(x::AbstractVector) = [RGBAf(to_color(c)) for c in x]
_as_ramp(x) = [RGBAf(c) for c in Makie.to_colormap(x)]

"""
    resolve_numeric(values, request, default; range = (5, 25)) -> Vector{Float64}

Resolve a size or width attribute to one number per index.

Accepts a constant, a vector of the right length, or a [`Field`](@ref), which is mapped
linearly onto `range`. Data-driven sizes are new here: PowerPlots only ever sets a constant
`size`, leaving size-by-data to post-hoc spec editing.
"""
function resolve_numeric(values, request, default::Real; range = (5.0, 25.0))
    n = length(values)
    request === nothing && return fill(Float64(default), n)
    request isa AbstractVector && length(request) == n && return Float64.(request)
    request isa Real && return fill(Float64(request), n)
    request isa Field || return fill(Float64(default), n)

    numeric = [v isa Real ? Float64(v) : NaN for v in values]
    finite = filter(isfinite, numeric)
    isempty(finite) && return fill(Float64(default), n)
    lo, hi = minimum(finite), maximum(finite)
    lo == hi && return fill(Float64(last(range)), n)
    return [
        isfinite(v) ?
        first(range) + (last(range) - first(range)) * (v - lo) / (hi - lo) :
        Float64(default) for v in numeric
    ]
end

"""
    component_spec(components, comp) -> NamedTuple

The user's per-component settings for `comp`, or an empty NamedTuple.

Accepts the canonical `Dict(:bus => (...))` as well as a vector of pairs, since Makie
destroys NamedTuple-valued attributes during conversion and a `Dict` is the only nested
form that survives.
"""
component_spec(components::AbstractDict, comp::Symbol) =
    get(components, comp, NamedTuple())
component_spec(components::AbstractVector, comp::Symbol) =
    something(findfirst_spec(components, comp), NamedTuple())
component_spec(::Nothing, ::Symbol) = NamedTuple()
component_spec(_, ::Symbol) = NamedTuple()

function findfirst_spec(pairs::AbstractVector, comp::Symbol)
    for p in pairs
        p isa Pair && first(p) === comp && return last(p)
    end
    return nothing
end
