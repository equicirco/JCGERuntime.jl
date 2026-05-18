"""
Generic helpers for numerical experiment design, batch execution, comparison,
frontier selection, sensitivity screening, and CSV export.
"""
module Experiments

using JuMP

export assignment_label, grid_assignments
export parameter_grid, policy_grid, parameter_policy_grid
export run_grid
export compare_to_reference, compare_to_group_reference
export closure_failures, assert_closure
export frontier_rows, sensitivity_screen
export write_rows_csv

function _value_vector(values)
    return values isa AbstractVector ? collect(values) : [values]
end

function _keyword_items(kwargs)
    items = Pair{Symbol,Vector{Any}}[]
    for (key, values) in kwargs
        push!(items, Symbol(key) => Any[_value_vector(values)...])
    end
    return items
end

"""
    grid_assignments(items)
    grid_assignments(; kwargs...)

Return the Cartesian product of parameter assignments as vectors of `Pair`s.
Each assignment can be passed to a model-specific factory.
"""
function grid_assignments(items::AbstractVector{<:Pair})
    isempty(items) && return [Pair{Symbol,Any}[]]
    first_item = first(items)
    rest = grid_assignments(items[2:end])
    out = Vector{Pair{Symbol,Any}}[]
    for value in first_item.second, tail in rest
        push!(out, [Symbol(first_item.first) => value; tail])
    end
    return out
end

grid_assignments(; kwargs...) = grid_assignments(_keyword_items(kwargs))

"""
    assignment_label(assignments; empty_label="baseline")

Create a stable text label for one assignment vector.
"""
function assignment_label(assignments;
    empty_label::AbstractString = "baseline",
    pair_separator::AbstractString = ",",
    key_value_separator::AbstractString = "=")
    isempty(assignments) && return String(empty_label)
    return join(
        ("$(key)$(key_value_separator)$(value)" for (key, value) in assignments),
        pair_separator,
    )
end

"""
    parameter_grid(factory; prefix="grid", kwargs...)

Build one experiment object per Cartesian parameter assignment. `factory` receives
`(label, assignments)` and returns the model-specific experiment object.
"""
function parameter_grid(factory::Function; prefix::AbstractString = "grid", kwargs...)
    return [
        factory("$(prefix):$(assignment_label(assignments))", assignments)
        for assignments in grid_assignments(; kwargs...)
    ]
end

"""
    policy_grid(factory, kind, target, values; prefix="policy")

Build one experiment object per policy value. `factory` receives
`(label, kind, target, value)`.
"""
function policy_grid(factory::Function, kind::Symbol, target::Symbol, values;
    prefix::AbstractString = "policy")
    return [
        factory("$(prefix):$(kind).$(target)=$(value)", kind, target, value)
        for value in _value_vector(values)
    ]
end

"""
    parameter_policy_grid(factory; policy_kind, policy_target, tau, prefix="grid", kwargs...)

Build experiments for each parameter assignment and policy value. `factory`
receives `(label, assignments, policy_kind, policy_target, policy_value)`.
"""
function parameter_policy_grid(factory::Function;
    policy_kind::Symbol,
    policy_target::Symbol,
    tau,
    prefix::AbstractString = "grid",
    kwargs...)
    out = nothing
    for assignments in grid_assignments(; kwargs...), policy_value in _value_vector(tau)
        label = "$(prefix):$(assignment_label(assignments)),$(policy_kind).$(policy_target)=$(policy_value)"
        spec = factory(label, assignments, policy_kind, policy_target, policy_value)
        if out === nothing
            out = typeof(spec)[spec]
        else
            push!(out, spec)
        end
    end
    return out === nothing ? Any[] : out
end

"""
    run_grid(specs; runner, kwargs...)

Run a batch of model-specific experiment objects. `runner` is called as
`runner(spec; kwargs...)` for each spec.
"""
function run_grid(specs::AbstractVector; runner::Function, kwargs...)
    return [runner(spec; kwargs...) for spec in specs]
end

run_grid(runner::Function, specs::AbstractVector; kwargs...) =
    [runner(spec; kwargs...) for spec in specs]

"""
    compare_to_reference(rows, reference; compare)

Merge each row with model-specific comparison fields against one reference row.
`compare(row, reference)` must return a `NamedTuple`.
"""
function compare_to_reference(rows::AbstractVector{<:NamedTuple},
    reference::NamedTuple;
    compare::Function)
    return [merge(row, compare(row, reference)) for row in rows]
end

compare_to_reference(compare::Function,
    rows::AbstractVector{<:NamedTuple},
    reference::NamedTuple) =
    compare_to_reference(rows, reference; compare)

function _group_key(row::NamedTuple, fields::AbstractVector{Symbol})
    return Tuple(getproperty(row, field) for field in fields)
end

"""
    compare_to_group_reference(rows, group_by; reference_filter, compare)

Compare each row to the one reference row selected inside its group.
"""
function compare_to_group_reference(rows::AbstractVector{<:NamedTuple},
    group_by::AbstractVector{Symbol};
    reference_filter::Function,
    compare::Function)
    groups = Dict{Tuple,Vector{NamedTuple}}()
    for row in rows
        key = _group_key(row, group_by)
        push!(get!(groups, key, NamedTuple[]), row)
    end

    out = NamedTuple[]
    for (key, group) in groups
        references = filter(reference_filter, group)
        length(references) == 1 || error(
            "Expected exactly one reference row for group $(key); found $(length(references))")
        ref = only(references)
        append!(out, (merge(row, compare(row, ref)) for row in group))
    end
    return out
end

function _matches_required(row::NamedTuple, field::Symbol, expected)
    expected === nothing && return true
    hasproperty(row, field) || return false
    return getproperty(row, field) == expected
end

function _within_tolerance(row::NamedTuple, field::Union{Nothing,Symbol}, tol::Real)
    field === nothing && return true
    hasproperty(row, field) || return false
    value = getproperty(row, field)
    value isa Real || return false
    return isfinite(value) && abs(Float64(value)) <= tol
end

"""
    closure_failures(rows; closure=nothing, status=JuMP.MOI.LOCALLY_SOLVED,
                     residual_field=nothing, residual_tol=1e-6)

Return rows that do not match the requested closure/status/residual criteria.
"""
function closure_failures(rows::AbstractVector{<:NamedTuple};
    closure = nothing,
    status = JuMP.MOI.LOCALLY_SOLVED,
    residual_field::Union{Nothing,Symbol} = nothing,
    residual_tol::Real = 1.0e-6)
    return [
        row for row in rows
        if !_matches_required(row, :closure, closure) ||
           !_matches_required(row, :status, status) ||
           !_within_tolerance(row, residual_field, residual_tol)
    ]
end

function _default_failure_message(row::NamedTuple)
    label = hasproperty(row, :label) ? row.label : row
    status = hasproperty(row, :status) ? row.status : "missing"
    return "$(label): status=$(status)"
end

"""
    assert_closure(rows; kwargs...)

Validate a batch with `closure_failures` and return `rows` unchanged. Throws an
error listing the first failing rows.
"""
function assert_closure(rows::AbstractVector{<:NamedTuple};
    describe::Function = _default_failure_message,
    kwargs...)
    failures = closure_failures(rows; kwargs...)
    if !isempty(failures)
        shown = [describe(row) for row in collect(Iterators.take(failures, 5))]
        suffix = length(failures) > length(shown) ?
                 "\n  ... $(length(failures) - length(shown)) more" : ""
        error("Closure validation failed for $(length(failures)) result(s):\n  " *
              join(shown, "\n  ") * suffix)
    end
    return rows
end

function _frontier_value(row::NamedTuple, field::Symbol)
    value = getproperty(row, field)
    value isa Real || error("Frontier field $(field) must be numeric")
    return Float64(value)
end

function _frontier_sort_value(row::NamedTuple, field::Symbol, sense::Symbol)
    value = _frontier_value(row, field)
    sense === :min && return value
    sense === :max && return -value
    sense === :absolute_min && return abs(value)
    error("Unknown frontier sense $(sense). Use :min, :max, or :absolute_min.")
end

"""
    frontier_rows(rows; group_by, select_by, predicate, sense=:min)

Return one selected row per group after filtering with `predicate`.
"""
function frontier_rows(rows::AbstractVector{<:NamedTuple};
    group_by::AbstractVector{Symbol} = Symbol[],
    select_by::Symbol,
    predicate::Function = row -> true,
    sense::Symbol = :min)
    groups = Dict{Tuple,Vector{NamedTuple}}()
    for row in rows
        predicate(row) || continue
        key = _group_key(row, group_by)
        push!(get!(groups, key, NamedTuple[]), row)
    end

    out = NamedTuple[]
    for group in values(groups)
        ordered = sort(group; by = row -> _frontier_sort_value(row, select_by, sense))
        push!(out, first(ordered))
    end
    return sort(out; by = row -> _group_key(row, group_by))
end

function _numeric_property(row::NamedTuple, field::Symbol)
    value = getproperty(row, field)
    value isa Real || error("Field $(field) must be numeric")
    return Float64(value)
end

function _mean(values::AbstractVector{Float64})
    isempty(values) && return NaN
    return sum(values) / length(values)
end

"""
    sensitivity_screen(rows, outcome, parameters)

Rank varied parameters by the range of mean `outcome` values across their levels.
"""
function sensitivity_screen(rows::AbstractVector{<:NamedTuple},
    outcome::Symbol,
    parameters::AbstractVector{Symbol})
    out = NamedTuple[]
    for parameter in parameters
        level_values = Dict{Any,Vector{Float64}}()
        for row in rows
            level = getproperty(row, parameter)
            push!(get!(level_values, level, Float64[]), _numeric_property(row, outcome))
        end
        level_means = [
            (level = level, mean = _mean(values))
            for (level, values) in level_values
        ]
        isempty(level_means) && continue
        ordered = sort(level_means; by = item -> item.mean)
        low = first(ordered)
        high = last(ordered)
        push!(out, (
            outcome = outcome,
            parameter = parameter,
            levels = length(level_means),
            level_min = low.level,
            mean_min = low.mean,
            level_max = high.level,
            mean_max = high.mean,
            effect_range = high.mean - low.mean,
            abs_effect_range = abs(high.mean - low.mean),
        ))
    end
    return sort(out; by = row -> row.abs_effect_range, rev = true)
end

function _csv_escape(value)
    if value isa AbstractFloat
        text = isfinite(value) ? string(value) : ""
    else
        text = string(value)
    end
    if occursin('"', text) || occursin(',', text) || occursin('\n', text) || occursin('\r', text)
        return "\"" * replace(text, "\"" => "\"\"") * "\""
    end
    return text
end

"""
    write_rows_csv(path, rows)

Write scalar `NamedTuple` rows to CSV.
"""
function write_rows_csv(path::AbstractString, rows::AbstractVector{<:NamedTuple})
    isempty(rows) && error("Cannot write an empty row collection")
    headers = collect(keys(first(rows)))
    open(path, "w") do io
        println(io, join(string.(headers), ","))
        for row in rows
            println(io, join((_csv_escape(getproperty(row, header)) for header in headers), ","))
        end
    end
    return path
end

end
