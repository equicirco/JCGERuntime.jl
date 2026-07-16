using Test
using JCGERuntime
using JCGECore
using JuMP

@testset "JCGERuntime" begin
    ctx = KernelContext()
    report = validate_model(ctx)
    @test report.ok
end

@testset "AST inequality and log objective compilation" begin
    model = JuMP.Model()
    ctx = KernelContext(model = model)
    x = JuMP.@variable(model, lower_bound = 1.0e-6, start = 1.0, base_name = "x")
    register_variable!(ctx, :x, x)

    register_equation!(ctx;
        tag = :upper,
        block = :test,
        payload = (
            indices = (),
            params = nothing,
            expr = ELe(EVar(:x), EConst(2.0)),
            constraint = nothing,
        ))
    register_equation!(ctx;
        tag = :lower,
        block = :test,
        payload = (
            indices = (),
            params = nothing,
            expr = EGe(EVar(:x), EConst(0.5)),
            constraint = nothing,
        ))
    register_equation!(ctx;
        tag = :objective,
        block = :test,
        payload = (
            indices = (),
            params = nothing,
            constraint = nothing,
            objective_expr = ELog(EVar(:x)),
            objective_sense = :Max,
        ))

    compile_equations!(ctx)
    @test all(eq -> eq.payload.constraint !== nothing, ctx.equations[1:2])
    @test JuMP.objective_sense(model) == JuMP.MOI.MAX_SENSE
end

@testset "Closure-condition roles and accounting checks" begin
    model = JuMP.Model()
    ctx = KernelContext(model = model)
    x = JuMP.@variable(model, base_name = "x")
    register_variable!(ctx, :x, x)
    register_equation!(ctx;
        tag = :clearing,
        block = :market,
        payload = (
            indices = (:g1, :r1),
            index_names = (:good, :region),
            params = nothing,
            expr = EEq(EVar(:x, Any[]), EConst(2.0)),
            constraint = nothing,
        ))

    condition = only(closure_conditions(ctx))
    @test condition == ClosureCondition(:market, :clearing, :g1, :r1)
    closure = ClosureSpec(:P_INDEX;
        condition_roles = Dict(condition => :accounting_check))
    compile_equations!(ctx; closure = closure)
    @test ctx.equations[1].payload.constraint === nothing
    @test ctx.equations[1].payload.condition_role == :accounting_check

    ctx.variables[:x] = 2.0
    evaluate_residuals!(ctx)
    residual = only(equation_residuals(ctx))
    @test residual.role == :accounting_check
    @test residual.residual == 0.0

    enforced_model = JuMP.Model()
    enforced = KernelContext(model = enforced_model)
    y = JuMP.@variable(enforced_model, base_name = "y")
    register_variable!(enforced, :y, y)
    register_equation!(enforced;
        tag = :clearing,
        block = :market,
        payload = (
            indices = (),
            params = nothing,
            expr = EEq(EVar(:y), EConst(1.0)),
            constraint = nothing,
        ))
    compile_equations!(enforced)
    @test only(enforced.equations).payload.constraint !== nothing
    @test only(enforced.equations).payload.condition_role == :enforce
end

@testset "Experiments" begin
    specs = Experiments.parameter_grid(; alpha = [1.0, 2.0], beta = [10.0]) do label, assignments
        (label = label, assignments = assignments)
    end
    @test length(specs) == 2
    @test specs[1].label == "grid:alpha=1.0,beta=10.0"

    policy_specs = Experiments.policy_grid(:route, :REF, [-0.1, 0.0]) do label, kind, target, value
        (label = label, kind = kind, target = target, value = value)
    end
    @test length(policy_specs) == 2
    @test policy_specs[1].value == -0.1

    runner = function (spec; scale = 1.0)
        (label = spec.label,
            closure = :fiscal,
            status = JuMP.MOI.LOCALLY_SOLVED,
            alpha = only(value for (key, value) in spec.assignments if key == :alpha),
            score = scale * only(value for (key, value) in spec.assignments if key == :alpha),
            max_abs_market_residual = 1.0e-9)
    end
    runs = Experiments.run_grid(specs; runner = runner, scale = 2.0)
    @test length(runs) == 2

    distributed_runs = Experiments.run_grid(specs;
        runner = runner,
        scale = 2.0,
        execution = :distributed,
        workers = 2,
        worker_modules = [:JuMP])
    @test distributed_runs == runs

    errored = Experiments.run_grid([(label = "bad",)];
        runner = spec -> error("failed $(spec.label)"),
        on_error = (spec, err) -> (label = spec.label, error = sprint(showerror, err)))
    @test only(errored).label == "bad"
    @test occursin("failed bad", only(errored).error)

    @test Experiments.closure_failures(runs;
        closure = :fiscal,
        residual_field = :max_abs_market_residual,
        residual_tol = 1.0e-6) == NamedTuple[]
    @test Experiments.assert_closure(runs;
        closure = :fiscal,
        residual_field = :max_abs_market_residual,
        residual_tol = 1.0e-6) == runs

    comparison = Experiments.compare_to_reference(runs, first(runs)) do row, ref
        (delta_score = row.score - ref.score,)
    end
    @test comparison[1].delta_score == 0.0
    @test comparison[2].delta_score == 2.0

    grouped = Experiments.compare_to_group_reference(comparison, Symbol[];
        reference_filter = row -> row.delta_score == 0.0,
        compare = (row, ref) -> (group_delta = row.score - ref.score,))
    @test length(grouped) == 2

    frontier = Experiments.frontier_rows(comparison;
        group_by = Symbol[],
        select_by = :alpha,
        predicate = row -> row.delta_score >= 0.0,
        sense = :max)
    @test only(frontier).alpha == 2.0

    sensitivity = Experiments.sensitivity_screen(comparison, :score, [:alpha])
    @test only(sensitivity).parameter == :alpha

    csv_path = joinpath(mktempdir(), "rows.csv")
    @test Experiments.write_rows_csv(csv_path, comparison) == csv_path
    @test occursin("delta_score", read(csv_path, String))
end
