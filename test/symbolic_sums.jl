function symbolic_sum_context()
    model = JuMP.Model()
    ctx = KernelContext(model = model)
    a = JuMP.@variable(model, lower_bound = 0.1, base_name = "a")
    b = JuMP.@variable(model, lower_bound = 0.1, base_name = "b")
    q = JuMP.@variable(model, base_name = "q")
    for (name, variable) in ((:a, a), (:b, b), (:q, q), (:X_A, a), (:X_B, b))
        register_variable!(ctx, name, variable)
    end
    return ctx, a, b, q
end

@testset "Symbolic sum compilation" begin
    indexed = EVar(:X, Any[EIndex(:i)])
    cases = [
        (:affine_and_nonlinear, EAdd([EVar(:a), ELog(EVar(:a))]),
            (a, b) -> a + log(a)),
        (:affine_and_quadratic, EAdd([EVar(:a), EPow(EVar(:a), EConst(2))]),
            (a, b) -> a + a^2),
        (:quadratic_and_nonlinear, EAdd([EPow(EVar(:a), EConst(2)), ELog(EVar(:a))]),
            (a, b) -> a^2 + log(a)),
        (:mixed_constant, EAdd([EConst(5), EVar(:a), ELog(EVar(:a))]),
            (a, b) -> 5 + a + log(a)),
        (:repeated_variable, EAdd([EVar(:a), EVar(:a)]),
            (a, b) -> 2a),
        (:numeric_only, EAdd([EConst(3), EConst(5)]),
            (a, b) -> 8),
        (:singleton, EAdd([EVar(:a)]), (a, b) -> a),
        (:empty_addition, EAdd(EquationExpr[]), (a, b) -> 0),
        (:indexed_sum, ESum(:i, [:A, :B], EAdd([indexed, ELog(indexed)])),
            (a, b) -> a + log(a) + b + log(b)),
        (:singleton_sum, ESum(:i, [:A], EAdd([indexed, ELog(indexed)])),
            (a, b) -> a + log(a)),
        (:sum_inside_addition, EAdd([ESum(:i, [:A, :B], indexed), ELog(EVar(:a))]),
            (a, b) -> a + b + log(a)),
        (:product_inside_addition, EAdd([EProd(:i, [:A, :B], indexed), ELog(EVar(:a))]),
            (a, b) -> a * b + log(a)),
    ]
    for (name, expression, expected) in cases
        @testset "$(name)" begin
            ctx, a, b, q = symbolic_sum_context()
            register_equation!(ctx; tag = name, block = :sum_test,
                payload = (indices = (), params = nothing,
                    expr = EEq(EVar(:q), expression), constraint = nothing))
            compile_equations!(ctx)
            constraint = only(ctx.equations).payload.constraint
            @test constraint isa JuMP.ConstraintRef
            object = JuMP.constraint_object(constraint)
            for (aval, bval) in ((1.25, 2.5), (2.0, 3.0))
                point = Dict(a => aval, b => bval, q => expected(aval, bval))
                @test isapprox(JuMP.value(variable -> point[variable], object.func),
                    object.set.value; atol = 1e-12)
            end
        end
    end
end

@testset "Symbolic sums in objectives and empty-domain validation" begin
    ctx, a, b, _ = symbolic_sum_context()
    expression = EAdd([EVar(:a), ELog(EVar(:a)),
        ESum(:i, [:A, :B], EVar(:X, Any[EIndex(:i)]))])
    register_equation!(ctx; tag = :objective, block = :sum_test,
        payload = (indices = (), params = nothing, constraint = nothing,
            objective_expr = expression, objective_sense = :Max))
    compile_equations!(ctx)
    point = Dict(a => 2.0, b => 3.0)
    @test JuMP.objective_sense(ctx.model) == JuMP.MOI.MAX_SENSE
    @test isapprox(JuMP.value(variable -> point[variable],
        JuMP.objective_function(ctx.model)), 7 + log(2); atol = 1e-12)

    empty, _, _, _ = symbolic_sum_context()
    register_equation!(empty; tag = :empty_sum, block = :sum_test,
        payload = (indices = (), params = nothing, constraint = nothing,
            expr = EEq(EVar(:q), ESum(:i, Symbol[], EVar(:X, Any[EIndex(:i)])))))
    @test_throws ErrorException compile_equations!(empty)
end
