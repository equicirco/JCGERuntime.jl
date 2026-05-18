# Usage

`JCGERuntime` compiles RunSpecs and executes solver runs.

## Solve a model

```julia
using JCGERuntime, Ipopt
result = run!(spec; optimizer=Ipopt.Optimizer)
```

## Validation

```julia
report = validate_model(spec)
```

## Experiment batches

Model packages can use `JCGERuntime.Experiments` for generic numerical
experiment workflows while keeping model-specific indicators and interpretation
locally:

```julia
using JCGERuntime

specs = JCGERuntime.Experiments.parameter_grid(
    (label, assignments) -> build_experiment(label, assignments);
    sigma = [1.5, 2.0, 3.0],
)

records = JCGERuntime.Experiments.run_grid(specs; runner = run_experiment)
rows = result_rows(records)

JCGERuntime.Experiments.assert_closure(rows;
    closure = :fiscal,
    residual_field = :max_abs_market_residual,
)
```

For independent experiment solves, opt into process-based parallel execution:

```julia
records = JCGERuntime.Experiments.run_grid(specs;
    runner = run_experiment,
    execution = :distributed,
    workers = 8,
    worker_modules = [:MyModelPackage],
)
```

Serial execution is the default. Distributed execution preserves row order and
uses `worker_modules` to load model packages on worker processes.

## Compilation hooks

Use `compile!` and `build_model!` for advanced workflows that need direct access
to the JuMP model or solver options.
