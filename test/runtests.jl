using PowerPlotsMakie
using TestItemRunner

"""
Whether a window can be opened.

Test items tagged `:interactive` drive real mouse events through GLMakie, which needs a
display and a GL context. CI has neither, so they are skipped there and run locally. Every
other test — including the whole drag/pin/re-layout state machine — is headless by design
and always runs.
"""
const HAS_DISPLAY = haskey(ENV, "DISPLAY") || haskey(ENV, "WAYLAND_DISPLAY")

"""
Whether GLMakie can be loaded at all.

It is deliberately not a declared test dependency — see the `GL` snippet in
`test-interaction.jl` — so it is reached through the shared workspace manifest and may
simply not be installed. A checkout that has never instantiated `examples/` is a normal
state, not a failure.
"""
const HAS_GLMAKIE =
    Base.locate_package(
        Base.PkgId(Base.UUID("e9467ef8-e4e7-5192-8a1a-b1aee30e663a"), "GLMakie"),
    ) !== nothing

const RUN_INTERACTIVE = HAS_DISPLAY && HAS_GLMAKIE

RUN_INTERACTIVE || @info "Skipping test items tagged :interactive" HAS_DISPLAY HAS_GLMAKIE

@run_package_tests filter = ti -> (RUN_INTERACTIVE || !(:interactive in ti.tags)) verbose =
    true
