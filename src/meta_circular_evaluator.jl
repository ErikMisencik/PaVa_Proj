include("testing.jl")
include("default_fun.jl")
include("default_sym.jl")

debug = false

function metajulia_repl()
    scope = Dict()
    while true
        print(">> ")
        result = ""
        input = ""
        while true
            input = input * "\n" * readline()
            result = Meta.parse(input, 1; greedy=true, raise=false)
            if result[1].head != :incomplete
                break
            end
        end
        println(metajulia_eval(result[1], scope))
    end
end

function metajulia_eval(exp, scope)
    return metajulia_eval(exp, scope)
end

"""
Could lead to very interesting use cases. If we are able to read julia code as string we could expose an api that takes julia code as input and we can process
this with our meta evaluator.
"""
function meta_eval_string(input_string)
    #cast string to expression
    expr = Meta.parse(input_string)
    metajulia_eval(expr)
end

function metajulia_eval(exp, scope=Dict())
    if (debug)
        println(typeof(exp))
        println(exp)
        println("Current scope: ", scope)
    end
    if is_expression(exp)
        return eval_exp(exp, scope)
    elseif is_symbol(exp)
        return return_var(exp, scope)
    elseif is_quote(exp)
        return eval_quote(exp, scope)
    else
        return exp
    end
end

function eval_quote(quote_exp, scope)

    if is_expression(quote_exp) && quote_exp.head == :$
        # Evaluate the interpolated expression
        return metajulia_eval(quote_exp.args[1], scope)
    end

    if isa(quote_exp, QuoteNode)
        # Return the value of the QuoteNode as is
        return quote_exp.value
    else
        return quote_exp.args[1]
    end
    
    ############### START ADDED FOR MACRO ##############
    if is_expression(quote_exp) && quote_exp.head == :quote
        if is_macro_expansion(quote_exp, scope)
            # Evaluate the content of the quote if it's part of a macro expansion
            return metajulia_eval(quote_exp.args[1], scope)
        else
            return quote_exp
        end
    end
    ############### END OF ADDED FOR MACRO ##############
end

function return_var(name, scope)
    if haskey(scope, name)
        return scope[name]
    else
        return name
    end
end

function eval_exp(exp, scope)

    ############### START ADDED FOR MACRO ##############
    # First check if it's a macro call or definition
    macro_type = is_macro_expansion(exp, scope)
    if macro_type == :macro_def
        return define_macro(exp, scope)
    elseif macro_type == :macro
        return eval_macro(exp, scope)
    end
    ############### END OF ADDED FOR MACRO ##############
 
    if exp.head == :quote
        eval_quote(exp, scope)  # Handle quoted expressions
    elseif exp.head != :call
        println("1")
        eval_operator(exp, scope)
    else
        println("3")
        eval_call(exp, scope)
    end
end

function eval_operator(operator_exp, scope)
    if haskey(default_sym_dict, operator_exp.head)
        # the dict defines basic operation they can be retrieved by the value 
        println(default_sym_dict[operator_exp.head](operator_exp, scope))
        return default_sym_dict[operator_exp.head](operator_exp, scope)
    end
    throw(UndefVarError(operator_exp.head))
end

# First the scope is checked for a name reference. This allows to override default fun. 
function eval_call(call, scope)
    fun_name = call.args[1]
    println(fun_name)
    if is_fun_defined(fun_name, scope)
        println("a")
        return eval_fun_call(call.args, scope)
    elseif is_default_fun_defined(fun_name)
        println("b")
        # the dict defines basic operation they can be retrieved by the value 
        return default_fun_dict[fun_name](call, scope)
    elseif is_anonymous_call(call)
        println("c")
        println(call)
        return eval_anonymous_call(metajulia_eval(call.args[1]), call.args[2])
    elseif typeof(scope[call.args[1]]) == fexpr
        return eval_fexpr_call(call.args, scope)
    elseif haskey(scope,call.args[1])        
        eval_fun_call(call.args, scope)    
    end
    throw(UndefVarError(fun_name))
end

struct Anonymous_Fun
    input_params::Any
    body::Any # can be expression or return value
end

function eval_anonymous_call(anon_fun, var_values)
    input = is_symbol(anon_fun.input_params) ? (anon_fun.input_params,) : anon_fun.input_params
    values = is_symbol(var_values) ? (var_values,) : var_values
    inner_scope = Dict(zip(input, values))
    println(inner_scope)
    return(metajulia_eval(anon_fun.body, inner_scope))
end

function is_anonymous_call(call)
    if typeof(call.args[1]) == Expr
        if call.args[1].head == :->
            return true
        end
    end
    return false
end

function is_default_fun_defined(fun_name)
    return haskey(default_fun_dict, fun_name)
end

function assign_var(var_name, var_value_exp, scope) # maybe in a later point of the project the var_name should also be evaluated
    var_value = metajulia_eval(var_value_exp, scope)
    scope[var_name] = var_value # Update scope
    return var_value
end

function eval_let(let_exp_args, outer_scope)

    let_exp_init = let_exp_args[1]
    let_exp_body = let_exp_args[2:end]
    local_scope = deepcopy(outer_scope)  # Inherit outer scope
    result = nothing

    if is_assignment(let_exp_init)   # if init only has 1 assignment
        eval_let_defs(let_exp_init, local_scope)
    else
        for exp in let_exp_init.args
            if (length(exp.args) > 1) && is_assignment(exp)   # if init is not empty
                eval_let_defs(exp, local_scope)
            end
        end
    end

    for exp in let_exp_body
        if length(exp.args) > 1    # if body is not empty expression
            if is_assignment(exp)
                eval_let_defs(exp, local_scope)
            else
                result = metajulia_eval(exp, local_scope)  # Use updated local_scope
            end
        end
    end
    return result
end

function eval_let_defs(exp, scope)
    var_name = exp.args[1]

    if is_expression(var_name)
        assign_fun(var_name, exp.args[2], scope)   # Function Definition
    else
        assign_var(var_name, metajulia_eval(exp.args[2], scope), scope)
    end
end

struct Fun_Def
    input_params::Any
    body::Any
end   
Base.show(io::IOBuffer, f::Fun_Def) = print(io, "<function>")

function assign_fun(function_decl, function_exp, scope)
    # Extract function parameters and body
    name = function_decl.args[1]
    params = function_decl.args[2:end]
    body = function_exp.args[end]

    params = is_symbol(params) ? (params,) : params     # Put param in tuple if singular one param
    fun_dev = Fun_Def(params, body)
    scope[name] = fun_dev   # Update scope
end 

struct UserFunction # System does not allow to use the name Function
    body::Any
    local_scope::Dict
end

function userFunction(fun_call_exp_args, scope)
    fun_name = fun_call_exp_args[1]
    param_values = map(x -> metajulia_eval(x, scope), fun_call_exp_args[2:end])
    fun_dev = scope[fun_name]
    local_scope = Dict(zip(fun_dev.input_params, param_values))
    body = fun_dev.body
    return UserFunction(body, local_scope)
end

function eval_fun_call(fun_call_exp_args, scope)
    fun = userFunction(fun_call_exp_args, scope)
    fun_scope = merge(scope, fun.local_scope)
    return metajulia_eval(fun.body, fun_scope)
end

function is_fun_defined(fun_name, scope)
    println(scope[fun_name])
    return haskey(scope, fun_name) && typeof(scope[fun_name]) == Fun_Def
end

function eval_if(if_exp_args, scope)
    args_length = length(if_exp_args)
    i = 1
    # if_exp_args[] is the part of the if exp that decides if args[2] or [3] should be returned
    while i < args_length
        if metajulia_eval(if_exp_args[i], scope) # if_exp_args[i] is the boolean expression
            return metajulia_eval(if_exp_args[i + 1], scope) # if_exp_args[i + 1] is the value to return
        else
            i += 2
        end
    end
    return metajulia_eval(if_exp_args[end], scope)
end

function eval_block(block_args, scope)
    args_length = length(block_args)     #block_args represent the instructions inside the block body
    i = 1     #in julia arrays start at 1
    while i < args_length
        metajulia_eval(block_args[i], scope)
        i += 1
    end
    return metajulia_eval(block_args[i], scope)
end

function is_expression(var)
    return isa(var, Expr)
end

function is_quote(quote_node)
    return isa(quote_node, QuoteNode)
end

function is_assignment(exp)
     return exp.head == :(=)
end

function is_symbol(var)
    return isa(var, Symbol)
end

function eval_assignment(operator_exp, scope)

    if is_expression(operator_exp.args[2])
        #define_fun(operator_exp, scope)
    end

    # if call is a function definition
    if is_expression(operator_exp.args[1]) 
        return assign_fun(operator_exp.args[1], operator_exp.args[2], scope)
    else
        return assign_var(operator_exp.args[1], operator_exp.args[2], scope)
    end
end

struct fexpr
    params
    body
end
Base.show(io::IOBuffer, f::fexpr) = print(io, "<fexpr>")

function eval_fexpr_def(function_decl, scope)
    # Extract function parameters and body
    name = function_decl.args[1].args[1]
    params = function_decl.args[1].args[2:end]
    body = function_decl.args[end]

    function_object = fexpr( params, body)  # Create a function object
    scope[name] = function_object   # Update scope

end
	
function eval_fexpr_call(fun_call_exp_args, scope)
    fun_name = fun_call_exp_args[1]
    param_values = deepcopy(fun_call_exp_args[2:end])  

    fexpr_object = scope[fun_name]
    params = fexpr_object.params
    body = fexpr_object.body

    # Create a local scope for the fexpr call
    local_scope = Dict(zip(params, param_values))
    result = metajulia_eval(body, local_scope)
    return result
end

 ############### START ADDED FOR MACRO ##############
 
struct MacroDef
    name::String
    params::Vector{Symbol}
    body::Expr
end

function define_macro(exp, scope)
    macro_name, macro_params, macro_body = string(exp.args[1].args[1]), exp.args[1].args[2:end], exp.args[2]
    scope[macro_name] = MacroDef(macro_name, macro_params, macro_body)
end


function eval_macro(exp, scope)

    macro_def = scope[string(exp.args[1])]
    macro_body = macro_def.body
    macro_args = exp.args[2:end]
    macro_body = foldl((body, pair) -> replace_expr(body, Expr(:$, pair[1]), pair[2]), zip(macro_def.params, macro_args), init = macro_body)
    metajulia_eval(macro_body.args[1], Dict())
end

function is_macro_expansion(exp, scope)
    if isa(exp, Expr) && exp.head == :call
        return haskey(scope, string(exp.args[1])) ? :macro : false
    elseif isa(exp, Expr) && exp.head == :$=
        return :macro_def
    end
    return false
end

function replace_expr(expr, to_replace, replacement)
    if expr == to_replace
        return replacement
    elseif isa(expr, Expr)
        return Expr(expr.head, map(arg -> replace_expr(arg, to_replace, replacement), expr.args)...)
    else
        return expr
    end
end
 ############### END OF ADDED FOR MACRO ##############
 s = Dict()

 @assert(metajulia_eval(:(sum(f, a, b) = 
 a > b ?
     0 :
     f(a) + sum(f, a + 1, b)), s) !== nothing)


metajulia_eval(:((x -> x + 1)(2)))


@assert(metajulia_eval(:(sum(x -> x*x, 1, 10)), s) == 385)