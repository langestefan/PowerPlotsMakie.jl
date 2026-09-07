# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`PowerPlotsMakie.jl` — a Julia package for plotting power-system networks with Makie, built on
`GraphMakie`. The package is currently a scaffold: `src/PowerPlotsMakie.jl` contains only a
placeholder `hello_world()`, and `GraphMakie` is the sole runtime dependency. Most real work will
mean adding source files and wiring them into the single `module PowerPlotsMakie`.

Generated from [BestieTemplate.jl](https://github.com/JuliaBesties/BestieTemplate.jl); `.copier-answers.yml`
records the template state. Template-managed files (CI workflows, `.pre-commit-config.yaml`, the
contributing/developer docs, issue templates) may be rewritten by a `copier update`, so prefer
changing generated files upstream-compatibly and never leave `.rej` files behind — a pre-commit hook
fails the commit on them.

## Repository layout

A Julia 1.12 **workspace** (`[workspace] projects = ["test", "docs", "examples"]` in `Project.toml`).
Each subproject has its own `Project.toml` with a `[sources]` path entry pointing back at the root
package, so they all resolve against one shared `Manifest.toml` — add a dependency to the subproject
that needs it, not to the root, unless the package itself needs it at runtime.

- `src/` — the package module.
- `test/` — TestItemRunner suite (see below).
- `docs/` — Documenter site.
- `examples/` — scratch environment for visual/manual checks (`GLMakie`, `Graphs`, `NetworkLayout`,
  `GraphMakie`). Untracked at present; it is the natural place to put runnable demo scripts.

## Commands

Run the full test suite:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

Run a subset. `test/runtests.jl` uses `@run_package_tests`, and test items are auto-discovered from
`test/test-*.jl` — there are no `include`s to edit. Filter by name or tag with an explicit path:

```bash
# single test item by name
julia --project=test -e 'using TestItemRunner; TestItemRunner.run_tests("."; filter=ti->occursin("Basic", ti.name), verbose=true)'

# by tag (test items carry tags such as :unit, :fast, :integration, :slow)
julia --project=test -e 'using TestItemRunner; TestItemRunner.run_tests("."; filter=ti->(:unit in ti.tags), verbose=true)'
```

Do **not** call `@run_package_tests` from `julia -e`: the macro resolves its search root from the
calling file's directory, which for `-e` becomes the *parent* of the repo, and it will then collect
and run sibling packages' test items. Use `run_tests(".")` from the repo root instead.

Lint and format (JuliaFormatter, markdownlint, yamlfmt/yamllint, CFF validation) — this is exactly
what CI runs, and commits are blocked unless it passes once `pre-commit install` has been run:

```bash
pre-commit run -a
```

Link checking (matches CI; note the config file is dotted, unlike the command in the developer docs):

```bash
lychee --no-progress --config .lychee.toml .
```

Build and preview docs live:

```bash
julia --project=docs -e 'using LiveServer; servedocs()'
```

## Conventions

- Julia formatting: 4-space indent, 92-column margin (`.JuliaFormatter.toml`). Compat floor is
  Julia 1.10, so avoid syntax newer than that even though the local toolchain is 1.12.
- `docs/make.jl` builds the page list by walking `docs/src/`. Adding a `.md` file is enough; adding a
  **subfolder** requires a title entry in the `titles` dict there or the build errors. Numbered
  prefixes (`90-`, `91-`, `95-`) control ordering. `95-reference.md` is `@autodocs` over the module,
  so exported docstrings land there automatically.
- Release steps (version bump, CHANGELOG sections, JuliaRegistrator, TagBot) are documented in
  `docs/src/91-developer.md` — follow that rather than improvising.
