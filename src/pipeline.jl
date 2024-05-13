
"""
    logir(ir, ci, sv)

Log the IR code of a function if it is in the Main module.
"""
function logir(ir, _, sv)
    sv.inlining.interp.options.log_ir || return (ir, false)

    # Only log functions in the Main module
    if nameof(sv.src.parent.def.module) == :Main
        println("Function: ", sv.src.parent.def)
        println(ir)
    end

    return ir |> pass_changed
end

"""
    pass_changed(x)

Helper function to indicate that a pass has changed the IR code.
"""
pass_changed(x) = (x, true)

function build_optimization_pipeline()
    pm = CC.PassManager()

    # Perform initial conversion to IRCode
    CC.register_pass!(pm, "slot2reg", CC.slot2reg)
    CC.register_condpass!(pm, "compact 1", (ir, _, _) ->
        CC.compact!(ir) |> pass_changed)

    # Perform first pass of normal optimization pipeline
    CC.register_pass!(pm, "inlining", (ir, ci, sv) ->
        CC.ssa_inlining_pass!(ir, sv.inlining, ci.propagate_inbounds))
    CC.register_pass!(pm, "compact 2", (ir, _, _) ->
        CC.compact!(ir) |> pass_changed)
    CC.register_pass!(pm, "SROA", (ir, _, sv) ->
        CC.sroa_pass!(ir, sv.inlining) |> pass_changed)
    CC.register_pass!(pm, "ADCE", (ir, _, sv) ->
        CC.adce_pass!(ir, sv.inlining))
    CC.register_condpass!(pm, "compact 3", (ir, _, _) ->
        CC.compact!(ir, true) |> pass_changed)

    # Perform rewrite optimizations until fixedpoint is reached
    CC.register_pass!(pm, "rewrite", (ir, ci, sv) ->
        perform_rewrites!(ir, ci, sv.inlining.interp))
    CC.register_condpass!(pm, "compact 4", (ir, _, _) ->
        CC.compact!(ir, true) |> pass_changed)

    # Cleanup calls to compiler barrier functions
    CC.register_pass!(pm, "cleanup",
        replace_compbarrier_calls!)

    # Perform second pass of normal optimization pipeline
    CC.register_pass!(pm, "inlining", (ir, ci, sv) ->
        CC.ssa_inlining_pass!(ir, sv.inlining, ci.propagate_inbounds))
    CC.register_pass!(pm, "compact 2", (ir, _, _) ->
        CC.compact!(ir) |> pass_changed)

    CC.register_pass!(pm, "SROA", (ir, _, sv) ->
        CC.sroa_pass!(ir, sv.inlining) |> pass_changed)
    CC.register_pass!(pm, "ADCE", (ir, _, sv) ->
        CC.adce_pass!(ir, sv.inlining))
    CC.register_condpass!(pm, "compact 3", (ir, _, _) ->
        CC.compact!(ir, true) |> pass_changed)

    # Log the result of the optimizations
    CC.register_pass!(pm, "log", logir)

    if CC.is_asserts()
        CC.register_pass!(pm, "verify", (ir, _, sv) -> begin
            CC.verify_ir(ir, true, false,
                CC.optimizer_lattice(sv.inlining.interp))
            CC.verify_linetable(ir.linetable)
            return ir |> pass_changed
        end)
    end

    return pm
end
