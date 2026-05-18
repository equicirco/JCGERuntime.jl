# JCGERuntime Changelog
All notable changes to this project will be documented in this file.
Releases use semantic versioning as in 'MAJOR.MINOR.PATCH'.

## Change entries
Added: For new features that have been added.
Changed: For changes in existing functionality.
Deprecated: For once-stable features removed in upcoming releases.
Removed: For features removed in this release.
Fixed: For any bug fixes.
Security: For vulnerabilities.

## [0.1.2] - 2026-05-18
### Added
- Process-based distributed execution for `JCGERuntime.Experiments.run_grid`
  through `execution = :distributed`, `workers`, and `worker_modules`.
- Optional `on_error` handling for experiment batches.

## [0.1.1] - 2026-05-18
### Added
- `JCGERuntime.Experiments` submodule with generic helpers for parameter and
  policy grids, batch execution, reference comparisons, closure validation,
  frontier selection, sensitivity screening, and CSV row export.

### Changed
- Relaxed `DualSignals` compatibility to the `0.1` series.

## [0.1.0] - 2026-01-15
### Added
- JuMP-backed runtime module with `KernelContext` registries for variables and equations.
- Equation compilation from JCGECore expressions, including objective support.
- Model execution helpers: `run!`, `solve!`, `compile_equations!`.
- Residual collection, summaries, and validation reports.
- Snapshot helpers for variable values and bounds.
- DualSignals export for constraint residuals.
- Minimal tests and documentation scaffolding.
