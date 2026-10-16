"""
Web map tiles under a power plot, from Tyler.jl: [`PowerPlotsMakie.powermap`](@ref).
"""
module PPMTylerExt

using PowerPlotsMakie
import PowerPlotsMakie as PPM
using Tyler: Tyler
using Makie: Makie, Axis, Figure, DataAspect, Rect2d, Point2f, translate!, text!
using Colors: mapc

const TileProviders = Tyler.TileProviders
const Downloads = Tyler.Downloads

"""
Who is asking for the tiles. The OpenStreetMap tile servers answer requests that carry only
a library's default User-Agent with an "Access blocked" image in place of the tile, so
every request says it comes from this package.
"""
const USER_AGENT = "PowerPlotsMakie.jl/$(pkgversion(PowerPlotsMakie)) (+https://github.com/langestefan/PowerPlotsMakie.jl)"

"""
A tile provider whose tiles are fetched with a User-Agent of our choosing. It carries the
wrapped provider's URL and options, which is all TileProviders and Tyler read from a
provider, and only changes the downloader Tyler picks for it.
"""
struct IdentifiedProvider <: TileProviders.AbstractProvider
    url::String
    options::Dict{Symbol,Any}
    user_agent::String
end

struct IdentifiedDownloader <: Tyler.AbstractDownloader
    inner::Tyler.ByteDownloader
    headers::Vector{Pair{String,String}}
end

Tyler.get_downloader(p::IdentifiedProvider) =
    IdentifiedDownloader(Tyler.ByteDownloader(), ["User-Agent" => p.user_agent])

# Tyler's own byte download, with the headers added.
function Tyler.download_tile_data(dl::IdentifiedDownloader, ::IdentifiedProvider, url)
    b = dl.inner
    Downloads.download(
        url,
        b.io;
        downloader = b.downloader,
        timeout = b.timeout,
        headers = dl.headers,
    )
    resize!(b.bytes, b.io.ptr - 1)
    copyto!(b.bytes, 1, b.io.data, 1, b.io.ptr - 1)
    seekstart(b.io)
    return b.bytes
end

"A plain URL-template provider, fetched as `user_agent`; anything else is left as it is."
_identified(p::TileProviders.Provider, user_agent::AbstractString) =
    IdentifiedProvider(p.url, p.options, String(user_agent))
_identified(p, ::Nothing) = p
_identified(p, _) = p

"Tyler draws its tiles at depths up to about 30; the network goes above all of them."
const NETWORK_DEPTH = 100

"The map behind each plot that has one, for [`PowerPlotsMakie.basemap`](@ref)."
const BASEMAPS = WeakKeyDict{PPM.PowerPlot,Tyler.Map}()

PPM.basemap(p::PPM.PowerPlot) = get(BASEMAPS, p, nothing)

function PPM.powermap(data; figure = (;), axis = (;), kwargs...)
    fig = Figure(; size = (800, 800), figure...)
    ax = Axis(fig[1, 1]; aspect = DataAspect(), axis...)
    Makie.hidedecorations!(ax)
    Makie.hidespines!(ax)
    p = PPM.powermap!(ax, data; kwargs...)
    return Makie.FigureAxisPlot(fig, ax, p)
end

function PPM.powermap!(
    ax::Axis,
    data;
    provider = TileProviders.OpenStreetMap(:Mapnik),
    projection = PPM.web_mercator,
    padding::Real = 0.05,
    attribution = true,
    user_agent = USER_AGENT,
    fade::Real = 0,
    tiles = (;),
    kwargs...,
)
    0 <= fade <= 1 || throw(ArgumentError("fade = $fade is not between 0 and 1"))
    p = PPM.powerplot!(ax, data; projection, kwargs...)
    translate!(p, 0, 0, NETWORK_DEPTH)

    fig = ax.parent
    fig isa Figure || throw(ArgumentError("powermap! needs an Axis that sits in a Figure"))
    extent = _padded_extent(p.node_pos[], padding)
    BASEMAPS[p] = Tyler.Map(
        extent,
        Tyler.web_mercator;
        figure = fig,
        axis = ax,
        provider = _identified(provider, user_agent),
        _fade_config(fade)...,
        tiles...,
    )

    credit = _attribution(attribution, provider)
    isempty(credit) ||
        text!(
            ax,
            1,
            0;
            text = credit,
            space = :relative,
            align = (:right, :bottom),
            offset = (-4, 3),
            fontsize = 10,
            color = (:black, 0.75),
            inspectable = false,
            xautolimits = false,
            yautolimits = false,
        ) |> t -> translate!(t, 0, 0, NETWORK_DEPTH + 1)
    return p
end

"Tiles blended `fade` of the way to white, so that the network stands out against them."
_fade_config(fade) =
    iszero(fade) ? (;) :
    (; plot_config = Tyler.PlotConfig(; preprocess = img -> _fade(img, Float32(fade))))

_fade(img::AbstractMatrix, fade) = map(c -> mapc(v -> v + fade * (1 - v), c), img)
_fade(data, _) = data

"The box around `points`, grown on every side by `padding` times its size."
function _padded_extent(points, padding)
    isempty(points) && throw(ArgumentError("powermap needs a network with coordinates"))
    xlo, xhi = extrema(q[1] for q in points)
    ylo, yhi = extrema(q[2] for q in points)
    # A single bus, or buses on one line, still get a map around them.
    w, h = max(xhi - xlo, 1.0), max(yhi - ylo, 1.0)
    dx, dy = padding * w, padding * h
    return Rect2d(xlo - dx, ylo - dy, w + 2dx, h + 2dy)
end

_attribution(credit::AbstractString, _) = String(credit)
_attribution(credit::Bool, provider) =
    credit ? _strip_html(string(get(provider.options, :attribution, ""))) : ""

"Attributions are written for the web, links and entities included; the plot shows text."
_strip_html(s) = replace(s, r"<[^>]*>" => "", "&copy;" => "©", "&amp;" => "&")

end
