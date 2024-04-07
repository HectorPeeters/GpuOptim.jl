using .Core.Compiler: naive_idoms, IRCode, Argument
using Metatheory
using Metatheory.EGraphs

const RewriteRule = Any

"""
    perform_rewrites!(ir::IRCode, ci::CC.CodeInfo, rules::Any)

Perform e-graph rewrite optimizations on the given IR code using the specified 
rules.
"""
function perform_rewrites!(ir::IRCode, ci::CC.CodeInfo, rules::Any)
    # Only optimize functions defined in the Main module
    if ci.parent.def.module != Main
        return ir, false
    end

    # Compute the control flow graph of the IR code
    cfg = CC.compute_basic_blocks(ir.stmts.stmt)

    # Currently, we only support functions with a single block
    if length(cfg.blocks) != 1
        @warn "Skipping function with multiple blocks: $(size(cfg.blocks))"
        return ir, false
    end

    made_changes = false

    for (i, block) in enumerate(cfg.blocks)
        # Convert the IR block to an expression tree
        irexpr = get_root_expr!(ir.stmts, block.stmts)

        # Create an e-graph from the expression tree
        g = EGraph(irexpr; keepmeta=true)
        settermtype!(g, IRExpr)

        # Apply the rewrite rules to the e-graph
        saturate!(g, rules)

        # Extract the optimized expression from the e-graph
        result = extract!(g, astsize)

        # Continue if no changes were made
        result == irexpr && continue

        made_changes = true

        # Convert the optimized expression back to IR
        exprtoir = ExprToIr(ci.parent.def.module, block.stmts)
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
        end
    end

    return ir, made_changes
end
