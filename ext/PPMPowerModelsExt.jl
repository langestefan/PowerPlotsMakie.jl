"""
    PPMPowerModelsExt

Backend for PowerModels.jl network dictionaries.

A PowerModels case is a `Dict{String,Any}` whose component tables are themselves dicts
keyed by string ids, so the whole backend is a handful of dictionary lookups. The only real
subtleties are the two ways an edge names its endpoints and the three ways an injection
names its bus.
"""
module PPMPowerModelsExt

import PowerModels
import PowerPlotsMakie as PPM
using PowerPlotsMakie: EdgeRole, InjectionRole, NodeRole

const NETWORK = Dict{String,<:Any}

# Component types by role. Types absent from a given case are skipped by the builder, so
# listing the full PowerModels vocabulary here costs nothing.
PPM.component_types(::NETWORK, ::NodeRole) = [:bus]
PPM.component_types(::NETWORK, ::EdgeRole) = [:branch, :dcline, :switch]
PPM.component_types(::NETWORK, ::InjectionRole) = [:gen, :load, :storage, :shunt]

_table(data::NETWORK, comp::Symbol) = get(data, string(comp), Dict{String,Any}())

function PPM.component_ids(data::NETWORK, comp::Symbol)
    ids = collect(keys(_table(data, comp)))
    isempty(ids) && return String[]
    # Numeric ids are the norm; sort them numerically so vertex order matches bus numbering
    # rather than "1", "10", "2". Fall back to lexicographic for non-numeric ids.
    nums = tryparse.(Int, ids)
    return any(isnothing, nums) ? sort(ids) : ids[sortperm(something.(nums))]
end

function PPM.component_field(data::NETWORK, comp::Symbol, id::AbstractString, field::Symbol)
    entry = get(_table(data, comp), String(id), nothing)
    entry === nothing && return missing
    return get(entry, string(field), missing)
end

"""
Endpoints come from `f_bus`/`t_bus` for branches, DC lines and switches. PowerModels'
transformers are branches with a tap, so they use the same keys; the `bus` vector form
belongs to PowerModelsDistribution and is handled here only so that a case carrying it does
not crash.
"""
function PPM.edge_endpoints(data::NETWORK, comp::Symbol, id::AbstractString)
    entry = get(_table(data, comp), String(id), nothing)
    entry === nothing && throw(KeyError("$comp[\"$id\"]"))
    if haskey(entry, "f_bus") && haskey(entry, "t_bus")
        return (string(entry["f_bus"]), string(entry["t_bus"]))
    elseif haskey(entry, "bus")
        buses = unique(entry["bus"])
        length(buses) == 2 || throw(
            ArgumentError(
                "$comp[\"$id\"] connects $(length(buses)) buses; only two-winding \
                 components can be drawn as a single edge",
            ),
        )
        return (string(buses[1]), string(buses[2]))
    end
    throw(ArgumentError("$comp[\"$id\"] has neither f_bus/t_bus nor bus"))
end

"Injections name their bus as `<comp>_bus` (`gen_bus`, `load_bus`, ...) or plain `bus`."
function PPM.injection_bus(data::NETWORK, comp::Symbol, id::AbstractString)
    entry = get(_table(data, comp), String(id), nothing)
    entry === nothing && throw(KeyError("$comp[\"$id\"]"))
    for key in ("$(comp)_bus", "bus")
        haskey(entry, key) && return string(entry[key])
    end
    throw(ArgumentError("$comp[\"$id\"] does not name a bus"))
end

"Reference (slack) buses are those with `bus_type == 3`."
function PPM.reference_nodes(data::NETWORK)
    return [id for (id, bus) in _table(data, :bus) if get(bus, "bus_type", 0) == 3]
end

"""
Honour hand-authored or geographic coordinates stored on the bus, using the same
`xcoord_1`/`ycoord_1` keys PowerPlots.jl writes and reads.
"""
function PPM.node_coordinates(data::NETWORK, comp::Symbol, id::AbstractString)
    entry = get(_table(data, comp), String(id), nothing)
    entry === nothing && return nothing
    x = get(entry, "xcoord_1", nothing)
    y = get(entry, "ycoord_1", nothing)
    (x === nothing || y === nothing) && return nothing
    return PPM.Point2f(x, y)
end

end # module
