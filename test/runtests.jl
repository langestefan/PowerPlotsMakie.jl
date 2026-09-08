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

HAS_DISPLAY || @info "No display detected: skipping test items tagged :interactive"

@run_package_tests filter = ti -> (HAS_DISPLAY || !(:interactive in ti.tags)) verbose = true
