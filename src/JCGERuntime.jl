"""
JuMP-facing runtime for building, solving, and inspecting JCGE models.
"""
module JCGERuntime

using DualSignals
using JuMP
using JCGECore

export KernelContext, register_variable!, register_equation!, list_equations
export compile_equations!
export equation_residuals, summarize_residuals, to_dualsignals
export validate_model
export snapshot, snapshot_state
export solve!
export run!
export Experiments

include("experiments.jl")

"""
Minimal kernel context with registries.
"""
mutable struct KernelContext
    variables::Dict{Symbol,Any}
    equations::Vector{NamedTuple}
    model::Union{JuMP.Model,Nothing}
end

"""
Create a `KernelContext` with an optional JuMP model.
"""
KernelContext(; model::Union{JuMP.Model,Nothing}=nothing) =
    KernelContext(Dict{Symbol,Any}(), NamedTuple[], model)

"""
Register a variable handle under a symbolic name.
"""
function register_variable!(ctx::KernelContext, name::Symbol, handle)
    ctx.variables[name] = handle
    return handle
end

"""
Register an equation with tags and an opaque payload.
"""
function register_equation!(ctx::KernelContext; tag::Symbol, block::Symbol, payload)
    push!(ctx.equations, (tag=tag, block=block, payload=payload))
    return nothing
end

"""
List registered equations in the context.
"""
list_equations(ctx::KernelContext) = ctx.equations

"""
Solve the JuMP model attached to the context.

If `optimizer` is provided it is set on the model before solving.
"""
function solve!(ctx::KernelContext; optimizer=nothing)
    model = ctx.model
    model isa JuMP.Model || error("KernelContext.model is not set; provide a JuMP.Model to solve.")
    if optimizer !== nothing
        JuMP.set_optimizer(model, optimizer)
    end
    JuMP.optimize!(model)
    return model
end

"""
Build, compile, solve, and summarize a RunSpec.

Key options:
- `compile_ast`: when true, compile the AST into JuMP constraints.
- `compile_objective`: when false, skip objective compilation.
- `mcp_fix`: optional dictionary of fixed MCP variables by symbol.

Returns a NamedTuple with:
- `context`: the KernelContext
- `summary`: residual summary
- `signals`: DualSignals dataset
"""
function run!(spec; optimizer=nothing, dataset_id::String="jcge", tol::Real=1e-6,
    description::Union{String,Nothing}=nothing, compile_ast::Bool=true, params=nothing,
    compile_objective::Bool=true, mcp_fix=nothing)
    model = JuMP.Model()
    ctx = KernelContext(model=model)
    for block in spec.model.blocks
        JCGECore.build!(block, ctx, spec)
    end
    if mcp_fix !== nothing
        for (name, value) in mcp_fix
            var = get(ctx.variables, name, nothing)
            var isa JuMP.VariableRef || error("mcp_fix expects a variable Symbol registered in context: $(name)")
            JuMP.fix(var, value; force=true)
        end
    end
    if compile_ast
        compile_equations!(ctx; params=params, compile_objective=compile_objective)
    end
    solve!(ctx; optimizer=optimizer)
    summary = summarize_residuals(ctx; tol=tol)
    signals = to_dualsignals(ctx; dataset_id=dataset_id, tol=tol, description=description)
    return (context=ctx, summary=summary, signals=signals)
end

"""
Snapshot solved variable values into a dictionary.

Only finite values are recorded.
"""
function snapshot(ctx::KernelContext)
    out = Dict{Symbol,Float64}()
    for (name, var) in ctx.variables
        if var isa JuMP.VariableRef
            value = try
                JuMP.value(var)
            catch
                continue
            end
            if isfinite(value)
                out[name] = value
            end
        end
    end
    return out
end

"""
Snapshot solved variable values from a result.
"""
snapshot(result::NamedTuple) = snapshot(result.context)

"""
Snapshot start/lower/upper/fixed variable states from a context.

Only finite bounds and fixed values are recorded.
"""
function snapshot_state(ctx::KernelContext)
    start = Dict{Symbol,Float64}()
    lower = Dict{Symbol,Float64}()
    upper = Dict{Symbol,Float64}()
    fixed = Dict{Symbol,Float64}()
    for (name, var) in ctx.variables
        var isa JuMP.VariableRef || continue
        value = try
            JuMP.value(var)
        catch
            continue
        end
        if isfinite(value)
            start[name] = value
        end
        if JuMP.has_lower_bound(var)
            lb = JuMP.lower_bound(var)
            if isfinite(lb)
                lower[name] = lb
            end
        end
        if JuMP.has_upper_bound(var)
            ub = JuMP.upper_bound(var)
            if isfinite(ub)
                upper[name] = ub
            end
        end
        if JuMP.is_fixed(var)
            fixed[name] = JuMP.fix_value(var)
        end
    end
    return (start=start, lower=lower, upper=upper, fixed=fixed)
end

"""
Snapshot start/lower/upper/fixed variable states from a result.
"""
snapshot_state(result::NamedTuple) = snapshot_state(result.context)

"""
Collect equation residuals from the registry.
"""
function equation_residuals(ctx::KernelContext)
    out = NamedTuple[]
    for eq in ctx.equations
        payload = eq.payload
        if payload isa NamedTuple && haskey(payload, :residual)
            push!(out, (tag=eq.tag, block=eq.block, indices=get(payload, :indices, ()), residual=payload.residual))
        end
    end
    return out
end

"""
Summarize residuals with max and count above tolerance.
"""
function summarize_residuals(ctx::KernelContext; tol::Real=1e-6)
    res = equation_residuals(ctx)
    if isempty(res)
        return (count=0, max_abs=0.0, worst=nothing, above_tol=0)
    end
    absvals = map(r -> abs(r.residual), res)
    max_idx = argmax(absvals)
    worst = res[max_idx]
    above_tol = count(x -> x > tol, absvals)
    return (count=length(res), max_abs=absvals[max_idx], worst=worst, above_tol=above_tol)
end

"""
Validate a built model context and return a report.

The report includes residual summaries and MCP metadata checks if present.
Use `level=:full` to include top residuals and basic scaling warnings.
"""
function validate_model(ctx::KernelContext; data=nothing, level::Symbol=:basic, tol::Real=1e-6)
    report = _new_report()
    structural = _category!(report, :structural)
    residuals = _category!(report, :residuals)
    mcp = _category!(report, :mcp)
    scaling = _category!(report, :scaling)

    isempty(ctx.equations) && push!(structural[:warnings], "No equations registered in context")
    isempty(ctx.variables) && push!(structural[:warnings], "No variables registered in context")

    res = equation_residuals(ctx)
    if isempty(res)
        push!(residuals[:warnings], "No residuals recorded; call compile_equations! and solve before validation")
    else
        summary = summarize_residuals(ctx; tol=tol)
        push!(residuals[:notes], "max_abs=$(summary.max_abs), above_tol=$(summary.above_tol)")
        if summary.above_tol > 0
            push!(residuals[:warnings], "Residuals above tolerance: $(summary.above_tol)")
        end
        if level == :full
            absvals = map(r -> abs(r.residual), res)
            order = sortperm(absvals; rev=true)
            topk = min(length(order), 5)
            for i in 1:topk
                r = res[order[i]]
                push!(residuals[:notes], "worst $(i): $(r.block).$(r.tag) $(r.indices) residual=$(r.residual)")
            end
        end
    end

    has_mcp = any(eq -> eq.payload isa NamedTuple && haskey(eq.payload, :mcp_var), ctx.equations)
    if has_mcp
        skip_tags = Set([:objective, :numeraire, :start, :lower, :upper, :fixed])
        for eq in ctx.equations
            payload = eq.payload
            if !(payload isa NamedTuple)
                continue
            end
            expr = get(payload, :expr, nothing)
            if expr isa JCGECore.EquationExpr && !(eq.tag in skip_tags) && !haskey(payload, :mcp_var)
                push!(mcp[:warnings], "Missing mcp_var for $(eq.block).$(eq.tag) $(get(payload, :indices, ()))")
            end
        end
    else
        push!(mcp[:notes], "No MCP equations detected")
    end

    if level == :full
        values = Float64[]
        for var in values(ctx.variables)
            if var isa JuMP.VariableRef
                v = try
                    JuMP.value(var)
                catch
                    continue
                end
                isfinite(v) || continue
                push!(values, v)
            end
        end
        if !isempty(values)
            maxval = maximum(abs.(values))
            minval = minimum(abs.(values))
            if maxval > 1e6
                push!(scaling[:warnings], "Large variable magnitude detected: max=$(maxval)")
            end
            if minval < 1e-8
                push!(scaling[:warnings], "Very small variable magnitude detected: min=$(minval)")
            end
        end
    end

    data === nothing || push!(structural[:notes], "data provided but not used by validate_model yet")

    return _finalize_report(report)
end

"""
Convert residuals into a DualSignals dataset.

This is a lightweight mapping focused on constraint residuals.
"""
function to_dualsignals(ctx::KernelContext; dataset_id::String="jcge",
    description::Union{String,Nothing}=nothing,
    tol::Real=1e-6)
    res = equation_residuals(ctx)
    components = Dict{String,DualSignals.Component}()
    constraints = DualSignals.Constraint[]
    solutions = DualSignals.ConstraintSolution[]

    for r in res
        component_id = string(r.block)
        if !haskey(components, component_id)
            components[component_id] = DualSignals.Component(
                component_id=component_id,
                component_type=_component_type_enum(:other),
                name=component_id,
            )
        end
        constraint_id = string(r.block, ":", r.tag, ":", join(string.(r.indices), ","))
        push!(constraints, DualSignals.Constraint(
            constraint_id=constraint_id,
            kind=_constraint_kind_enum(:other),
            sense=_constraint_sense_enum(:eq),
            component_ids=[component_id],
        ))
        slack = abs(r.residual)
        push!(solutions, DualSignals.ConstraintSolution(
            constraint_id=constraint_id,
            dual=0.0,
            slack=slack,
            is_binding=slack <= tol,
        ))
    end

    metadata = DualSignals.DatasetMetadata(description=description)
    return DualSignals.DualSignalsDataset(
        dataset_id=dataset_id,
        metadata=metadata,
        components=collect(values(components)),
        constraints=constraints,
        constraint_solutions=solutions,
        variables=nothing,
    )
end

"""
Map a Symbol to an enum member by name.
"""
function _enum_by_name(::Type{T}, name::Symbol) where {T}
    for val in Base.Enums.instances(T)
        if string(val) == string(name)
            return val
        end
    end
    error("Unknown enum value $(name) for $(T)")
end

"""
Return a DualSignals ComponentType enum by name.
"""
_component_type_enum(sym::Symbol) = _enum_by_name(DualSignals.ComponentType, sym)
"""
Return a DualSignals ConstraintKind enum by name.
"""
_constraint_kind_enum(sym::Symbol) = _enum_by_name(DualSignals.ConstraintKind, sym)
"""
Return a DualSignals ConstraintSense enum by name.
"""
_constraint_sense_enum(sym::Symbol) = _enum_by_name(DualSignals.ConstraintSense, sym)

"""
Compile registered equations into JuMP constraints/objective.

If `compile_objective` is true, a single objective is compiled.
"""
function compile_equations!(ctx::KernelContext; params=nothing, compile_objective::Bool=true)
    model = ctx.model
    model isa JuMP.Model || return ctx
    local_objective = nothing
    local_sense = nothing
    for i in eachindex(ctx.equations)
        eq = ctx.equations[i]
        payload = eq.payload
        if !(payload isa NamedTuple)
            continue
        end
        expr = get(payload, :expr, nothing)
        objective_expr = get(payload, :objective_expr, nothing)
        objective_sense = get(payload, :objective_sense, nothing)
        index_names = get(payload, :index_names, nothing)
        indices = get(payload, :indices, ())
        constraint = get(payload, :constraint, nothing)
        if objective_expr !== nothing
            if local_objective !== nothing
                error("Multiple objectives registered; only one objective is supported.")
            end
            local_objective = (expr=objective_expr, index_names=index_names, indices=indices,
                params=get(payload, :params, nothing))
            local_sense = objective_sense === nothing ? :Max : objective_sense
        end
        if constraint !== nothing
            continue
        end
        if expr isa JCGECore.EquationExpr && !(expr isa JCGECore.ERaw)
            env = _index_env(index_names, indices)
            local_params = params === nothing ? get(payload, :params, nothing) : params
            mcp_var = get(payload, :mcp_var, nothing)
            new_constraint = _compile_equation(expr, ctx, local_params, indices, env; mcp_var=mcp_var)
            new_payload = merge(payload, (constraint=new_constraint,))
            ctx.equations[i] = (tag=eq.tag, block=eq.block, payload=new_payload)
        end
    end
    if local_objective !== nothing && compile_objective
        _compile_objective!(ctx, local_objective; params=params, sense=local_sense)
    end
    return ctx
end

"""
Create a new validation report container.
"""
function _new_report()
    return Dict{Symbol,Dict{Symbol,Vector{String}}}()
end

"""
Get or create a category entry within a validation report.
"""
function _category!(report, name::Symbol)
    if !haskey(report, name)
        report[name] = Dict(
            :errors => String[],
            :warnings => String[],
            :notes => String[],
        )
    end
    return report[name]
end

"""
Finalize a report into a summary NamedTuple.
"""
function _finalize_report(report)
    errors = 0
    warnings = 0
    for cat in values(report)
        errors += length(cat[:errors])
        warnings += length(cat[:warnings])
    end
    return (ok=errors == 0, errors=errors, warnings=warnings, categories=report)
end

"""
Compile a single equation expression into a JuMP constraint.
"""
function _compile_equation(expr::JCGECore.EquationExpr, ctx::KernelContext, params, idxs, env::Dict{Symbol,Symbol}; mcp_var=nothing)
    if expr isa JCGECore.EEq
        lhs = _compile_expr(expr.lhs, ctx, params, idxs, env)
        rhs = _compile_expr(expr.rhs, ctx, params, idxs, env)
        if mcp_var !== nothing
            var = _compile_mcp_var(mcp_var, ctx, params, idxs, env)
            return @constraint(ctx.model, lhs - rhs ⟂ var)
        end
        return @constraint(ctx.model, lhs == rhs)
    end
    error("Unsupported equation expression: expected EEq, got $(typeof(expr))")
end

"""
Compile an objective expression into the JuMP model.
"""
function _compile_objective!(ctx::KernelContext, objective; params=nothing, sense=:Max)
    model = ctx.model
    model isa JuMP.Model || return nothing
    expr = objective.expr
    index_names = objective.index_names
    indices = objective.indices
    env = _index_env(index_names, indices)
    local_params = params === nothing ? objective.params : params
    value = _compile_expr(expr, ctx, local_params, indices, env)
    if sense == :Min
        JuMP.@objective(model, Min, value)
    elseif sense == :Max
        JuMP.@objective(model, Max, value)
    else
        error("Unsupported objective sense: $(sense)")
    end
    return nothing
end

"""
Compile an expression AST node into a JuMP-compatible expression.
"""
function _compile_expr(expr::JCGECore.EquationExpr, ctx::KernelContext, params, idxs, env::Dict{Symbol,Symbol})
    if expr isa JCGECore.EVar
        resolved = _resolve_indices(expr.idxs, idxs, env)
        return _resolve_var(ctx, expr.name, resolved)
    elseif expr isa JCGECore.EParam
        resolved = _resolve_indices(expr.idxs, idxs, env)
        return _resolve_param(params, expr.name, resolved)
    elseif expr isa JCGECore.EConst
        return expr.value
    elseif expr isa JCGECore.ERaw
        error("Cannot compile ERaw expression: $(expr.text)")
    elseif expr isa JCGECore.EIndex
        haskey(env, expr.name) || error("Unbound index: $(expr.name)")
        return env[expr.name]
    elseif expr isa JCGECore.EAdd
        parts = map(t -> _compile_expr(t, ctx, params, idxs, env), expr.terms)
        return sum(parts; init=0.0)
    elseif expr isa JCGECore.EMul
        parts = map(t -> _compile_expr(t, ctx, params, idxs, env), expr.factors)
        return foldl(*, parts)
    elseif expr isa JCGECore.EPow
        base = _compile_expr(expr.base, ctx, params, idxs, env)
        exponent = _compile_expr(expr.exponent, ctx, params, idxs, env)
        return base ^ exponent
    elseif expr isa JCGECore.EDiv
        num = _compile_expr(expr.numerator, ctx, params, idxs, env)
        den = _compile_expr(expr.denominator, ctx, params, idxs, env)
        return num / den
    elseif expr isa JCGECore.ENeg
        inner = _compile_expr(expr.expr, ctx, params, idxs, env)
        return -inner
    elseif expr isa JCGECore.ESum
        if isempty(expr.domain)
            error("ESum domain is empty for index $(expr.index)")
        end
        parts = Vector{Any}()
        for val in expr.domain
            env[expr.index] = val
            push!(parts, _compile_expr(expr.expr, ctx, params, idxs, env))
        end
        delete!(env, expr.index)
        return sum(parts)
    elseif expr isa JCGECore.EProd
        if isempty(expr.domain)
            error("EProd domain is empty for index $(expr.index)")
        end
        vals = Vector{Any}()
        for val in expr.domain
            env[expr.index] = val
            push!(vals, _compile_expr(expr.expr, ctx, params, idxs, env))
        end
        delete!(env, expr.index)
        return foldl(*, vals)
    else
        error("Unsupported expression type: $(typeof(expr))")
    end
end

"""
Resolve a variable reference by name and indices.
"""
function _resolve_var(ctx::KernelContext, name::Symbol, idxs::Vector{Symbol})
    var_name = isempty(idxs) ? name : _global_var(name, idxs...)
    haskey(ctx.variables, var_name) || error("Missing variable: $(var_name)")
    return ctx.variables[var_name]
end

"""
Resolve an MCP complementarity variable expression.
"""
function _compile_mcp_var(expr, ctx::KernelContext, params, idxs, env::Dict{Symbol,Symbol})
    if expr isa JCGECore.EVar
        resolved = _resolve_indices(expr.idxs, idxs, env)
        return _resolve_var(ctx, expr.name, resolved)
    elseif expr isa Symbol
        return _resolve_var(ctx, expr, Symbol[])
    else
        error("Unsupported MCP variable expression: $(expr)")
    end
end

"""
Resolve a parameter reference by name and indices.
"""
function _resolve_param(params, name::Symbol, idxs::Vector{Symbol})
    params === nothing && error("No params provided for parameter $(name)")
    return JCGECore.getparam(params, name, idxs...)
end

"""
Build a global variable name from a base and indices.
"""
function _global_var(base::Symbol, idxs::Symbol...)
    if isempty(idxs)
        return base
    end
    return Symbol(string(base), "_", join(string.(idxs), "_"))
end

"""
Resolve indices from explicit indices or default indices and environment.
"""
function _resolve_indices(idxs, default_idxs, env::Dict{Symbol,Symbol})
    if idxs === nothing
        if default_idxs isa Tuple
            return Symbol[default_idxs...]
        elseif default_idxs isa AbstractVector
            return Symbol[default_idxs...]
        else
            return Symbol[]
        end
    elseif isempty(idxs)
        return Symbol[]
    end
    resolved = Symbol[]
    for idx in idxs
        if idx isa JCGECore.EIndex
            haskey(env, idx.name) || error("Unbound index: $(idx.name)")
            push!(resolved, env[idx.name])
        elseif idx isa Symbol
            push!(resolved, idx)
        else
            push!(resolved, Symbol(idx))
        end
    end
    return resolved
end

"""
Build an index environment mapping index names to values.
"""
function _index_env(index_names, indices)
    env = Dict{Symbol,Symbol}()
    if index_names === nothing
        return env
    end
    if indices isa Tuple
        values = collect(indices)
    elseif indices isa AbstractVector
        values = collect(indices)
    else
        values = Any[]
    end
    if length(index_names) != length(values)
        return env
    end
    for (name, val) in zip(index_names, values)
        env[Symbol(name)] = Symbol(val)
    end
    return env
end

end # module
