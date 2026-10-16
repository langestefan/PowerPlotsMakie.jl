"Radius of the sphere Web Mercator projects onto, in metres (WGS84's semi-major axis)."
const WEB_MERCATOR_RADIUS = 6378137.0

"Latitude at which Web Mercator's square world ends, in degrees."
const WEB_MERCATOR_MAX_LAT = 85.0511287798066

"""
    web_mercator(p) -> Point2d

Longitude and latitude in degrees, `p = (lon, lat)`, to Web Mercator (EPSG:3857) in metres:
the projection web map tiles are drawn in. Latitudes beyond ±85.05°, where the projection's
square world ends, are clamped to it.

This is the default `projection` of [`powermap`](@ref), for networks whose coordinates are
longitude and latitude. Data in another coordinate system goes through Proj.jl instead,
e.g. from the Dutch RD New grid:

```julia
using Proj
rd = Proj.Transformation("EPSG:28992", "EPSG:3857"; always_xy = true)
powermap(case; projection = p -> rd(p[1], p[2]))
```
"""
function web_mercator(p)
    lon, lat =
        Float64(p[1]), clamp(Float64(p[2]), -WEB_MERCATOR_MAX_LAT, WEB_MERCATOR_MAX_LAT)
    return Point2d(
        WEB_MERCATOR_RADIUS * deg2rad(lon),
        WEB_MERCATOR_RADIUS * log(tan(π / 4 + deg2rad(lat) / 2)),
    )
end

"A coordinate from the data, in whatever shape the backend gives it, through `projection`."
_project(projection, p) = Point2f(projection(Point2d(p[1], p[2])))

"""
    powermap(data; provider, projection = web_mercator, padding = 0.05, fade = 0,
             attribution = true, user_agent, figure = (;), axis = (;), tiles = (;),
             kwargs...) -> FigureAxisPlot
    powermap!(ax, data; provider, projection = web_mercator, padding = 0.05, fade = 0,
              attribution = true, user_agent, tiles = (;), kwargs...) -> PowerPlot

Draw a network over a web map: tiles from `provider`, OpenStreetMap by default, downloaded
as the axis is zoomed and panned. The map version of the plots pandapower draws with
`simple_plotly(net, on_map = true)`.

Needs Tyler.jl, which supplies the tiles: `using Tyler` loads these methods. Providers come
from TileProviders.jl (`Tyler.TileProviders`), e.g. `OpenStreetMap(:DE)` for the German
style, or `Esri(:WorldGrayCanvas)` for a quieter backdrop.

Tiles are in Web Mercator, so the data's coordinates are projected into it with
`projection` — by default [`web_mercator`](@ref), which reads them as longitude and
latitude. Pass a function from point to point for any other coordinate system (see
[`web_mercator`](@ref) for RD New through Proj.jl). It is the plot's `projection`
attribute, applied to bus coordinates and line routes alike.

The axis starts on the network, with `padding` (a fraction of its size, default `0.05`)
around it. `fade` blends the tiles toward white, from `0` (as served) to `1` (blank), which
helps a dense network stand out against a busy map. `attribution = true` credits the
tiles' source in the bottom right corner, as the OpenStreetMap tile licence asks; pass a
string to say something else, or `false` to leave it off. `tiles` passes keywords to
`Tyler.Map`, `figure` and `axis` to the `Figure` and `Axis` that `powermap` makes, and
everything else to [`powerplot`](@ref).

Saving a figure waits for the tiles in view to arrive. Tiles are requested with a
User-Agent naming this package, `user_agent`, since the OpenStreetMap tile servers block
requests that do not say where they come from; they also ask that tiles not be fetched in
bulk. `user_agent = nothing` sends Tyler's default.

[`basemap`](@ref) returns the `Tyler.Map` behind a plot.
"""
function powermap end

@doc (@doc powermap) function powermap! end

"""
    basemap(plot) -> Union{Nothing,Tyler.Map}

The `Tyler.Map` drawing the tiles under a plot made by [`powermap`](@ref), or `nothing` for
a plot that has none. Use it to `wait` for the tiles, or with Tyler's own functions such as
`toggle_visibility!`.
"""
function basemap end

const _TYLER_HINT = "Load Tyler.jl first (`using Tyler`) to draw networks over a web map."

function _register_map_hint()
    Base.Experimental.register_error_hint(MethodError) do io, exc, argtypes, kwargs
        exc.f in (powermap, powermap!, basemap) && print(io, "\n", _TYLER_HINT)
    end
end
