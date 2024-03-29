function get_impl_function_name(func_name)
    if func_name isa Expr
        return error("TODO: get the implementation function name for cases like `Base.:+`")
    end

    return Symbol("impl_", func_name)
end

macro rewritetarget(func::Expr)
    # If a return type isn't included in the function, the name of the function is nested 
    # one additional level. We need the return type to be explicitly stated as that
    # information is lost when using the `Base.compilerbarrier`.
    if func.args[begin].args[begin] isa Symbol
        return error("Please add a return type to the function")
    end

    # Full signature of function including name and return type
    signature = func.args[begin]
    # Signature of function without return type
    signature_noret = signature.args[begin]

    func_name = signature_noret.args[begin]
    args = signature_noret.args[2:end]
    ret_type = signature.args[2]

    # Change the name of the implementation function by appending `impl!_`
    # func_name_impl = get_impl_function_name(func_name)
    func_name_impl = Symbol("impl_", func_name)
    func.args[begin].args[begin].args[begin] = func_name_impl

    # Return a wrapper around the function that encapsulates the original implementation
    # inside of a `Base.compilerbarrier`.
    return esc(quote
        $(func)

        function $func_name($(args...))::$ret_type
            return Base.compilerbarrier(:type, $(func_name_impl))($(args...))::$ret_type
        end
    end)
end

"""
    strip_compbarrier!(ir::IRCode)

This function is used to remove all remaining calls to `Base.compilerbarrier` from the IR.
These are generated by the `@rewritetarget` macro and are no longer needed after applying
the possible rewrite optimizations. As the `Base.compilerbarrier` calls are generated in
the function and not at the call-site, they cannot be removed when applying the rewrite,
so a separate pass is needed to eliminate them.
"""
function strip_compbarrier!(ir::IRCode)
    instructions = instrs(ir)

    compbarrier_value = nothing

    made_changes = false

    # TODO: the logic in this function will trigger on any call to `Base.compilerbarrier`,
    #       even if it's not generated by the `@rewritetarget` macro.

    for (i, instruction) in enumerate(instructions)
        if Meta.isexpr(instruction, :call) && instruction.args[begin] == GlobalRef(Base, :compilerbarrier)
            # Keep track of the value stored in the compilerbarrier
            compbarrier_value = instruction.args[3]

            # Mark the compilerbarrier as dead
            markdead!(ir, i)

            made_changes = true

            continue
        end

        if compbarrier_value !== nothing
            # Take the impl function and set it directly, ignoring the compilerbarrier
            instruction.args[begin] = compbarrier_value

            # TODO: find a better place to get the return type
            ret_type = ir.stmts.type[end-2]
            arg_types = size(ir.argtypes) == 0 ? () : (ir.argtypes[2:end]...,)
            sig_types = Tuple{arg_types...,ret_type}

            func = getfield(compbarrier_value.mod, compbarrier_value.name)
            m = methods(func, arg_types) |> first

            mi = Core.Compiler.specialize_method(m, sig_types, Core.svec())

            instructions[i] = Expr(
                :invoke,
                mi,
                func,
                instruction.args[2:end]...
            )

            # Set the type of the instruction to the known type, as that information
            # was lost by the compilerbarrier.
            ir.stmts.type[i] = ret_type

            compbarrier_value = nothing

            @info "Stripped compilerbarrier"
        end
    end

    return ir, made_changes
end
