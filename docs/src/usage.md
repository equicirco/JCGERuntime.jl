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

Use `compile_equations!` for advanced workflows that need direct access to the
JuMP model or solver options.

`compile_equations!` compiles backend-neutral equation expressions from
`JCGECore` into JuMP constraints. It supports equality and inequality relations:

```julia
EEq(lhs, rhs)  # lhs == rhs
ELe(lhs, rhs)  # lhs <= rhs
EGe(lhs, rhs)  # lhs >= rhs
```

Objective expressions registered through `objective_expr` are compiled into a
JuMP objective. Natural logarithms can be represented with `ELog(expr)`, so
log-utility objectives can stay in the JCGE expression tree instead of using
direct JuMP objective macros.

## Closure conditions and accounting checks

Every registered equation receives a stable key from its block name, tag, and
indices. A model can retain an identity in its equation inventory while asking
the runtime to evaluate it after solution rather than impose it on the solver:

```julia
using JCGECore: ClosureCondition, ClosureSpec

check = ClosureCondition(:investment_pool, :investment_pool_clearing)
closure = ClosureSpec(:P_HH_COMMON;
    kind = :price_index,
    condition_roles = Dict(check => :accounting_check),
)
```

Pass the closure to `compile_equations!`, or use `run!`, which does so
automatically. After `solve!`, call `evaluate_residuals!` to record residuals;
`run!` performs this step automatically. `closure_conditions(ctx)` lists the
keys registered in a built model.
