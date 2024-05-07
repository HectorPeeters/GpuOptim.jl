using .Core.Compiler: naive_idoms, IRCode, Argument
using Metatheory
using Metatheory.EGraphs: collect_cse!, rec_extract, settermtype!, EGraph

const RewriteRule = Any

"""
    perform_rewrites!(ir::IRCode, ci::CC.CodeInfo, rules::Any)

Perform e-graph rewrite optimizations on the given IR code using the specified 
rules.
"""
function perform_rewrites!(
    ir::IRCode, ci::CC.CodeInfo, interp::CustomInterpreter)

    # Only optimize functions defined in the Main module
    if ci.parent.def.module != Main
        return ir, false
    end

    cfg = ir.cfg

    # Currently, we only support functions with a single block
    if length(cfg.blocks) != 1
        @debug "Skipping function with multiple blocks: $(size(cfg.blocks))"
        return ir, false
    end

    made_changes = false

    for (i, block) in enumerate(cfg.blocks)
        # Convert the IR block to an expression tree
        irtoexpr = IrToExpr(ir.stmts, block.stmts)
        irexpr = get_root_expr!(irtoexpr)

        # Create an e-graph from the expression tree
        g = EGraph(irexpr; keepmeta=true)
        settermtype!(g, IRExpr)

        # Apply the rewrite rules to the e-graph
        # params = SaturationParams(timeout=20, timelimit=1000000000, eclasslimit=4000)
        saturate!(g, interp.rules) # |> println

        analyze!(g, astsize, g.root)

        # result = rec_extract(g, astsize, g.root; cse_env=cse_env)
        result = extract!(g, astsize)

        # Continue if no changes were made
        result == irexpr && continue

        made_changes = true

        # Extract the optimized expression from the e-graph
        exprtoir = ExprToIr(ci.parent.def.module, block.stmts)

        # Convert the optimized expression back to IR
        (optim_instr, optim_types) = expr_to_ir!(exprtoir, result)

        if length(optim_instr) > length(block.stmts)
            # TODO: we need to resize in the middle of the instruction stream 
            #       here. However, this case currently shouldn't be possible as 
            #       we use the astsize cost function.
            error("New block is larger than old block: ",
                size(block.stmts), " -> ", size(optim_instr))
        end

        # Patch the optimized instructions back into the IR code
        for (i, instr) in enumerate(optim_instr)
            ir.stmts.stmt[i+block.stmts.start-1] = instr
            ir.stmts.type[i+block.stmts.start-1] = optim_types[i]
            ir.stmts.info[i+block.stmts.start-1] = CC.NoCallInfo()
            ir.stmts.flag[i+block.stmts.start-1] = CC.IR_FLAG_REFINED
        end

        # Remove any remaining instructions
        for i in length(optim_instr)+1:length(block.stmts)
            ir.stmts.stmt[i+block.stmts.start-1] = nothing
            ir.stmts.type[i+block.stmts.start-1] = Nothing
            ir.stmts.info[i+block.stmts.start-1] = CC.NoCallInfo()
            ir.stmts.flag[i+block.stmts.start-1] = CC.IR_FLAG_NULL
            ir.stmts.line[i+block.stmts.start-1] = 0
        end
    end

    return ir, made_changes
end
