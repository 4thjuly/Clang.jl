"""
Unsupported argument types
"""
const RESERVED_ARG_TYPES = ["va_list"]

"""
    wrap!(ctx::AbstractContext, cursor::CLFunctionDecl)
Subroutine for handling function declarations. Note that VarArg functions are not supported.
"""
function wrap!(ctx::AbstractContext, cursor::CLFunctionDecl)
    func_type = type(cursor)
    if kind(func_type) == CXType_FunctionNoProto
        @warn "No Prototype for $cursor - assuming no arguments"
    elseif isvariadic(func_type)
        @warn "Skipping VarArg Function $cursor"
        return ctx
    end

    func_name = isempty(ctx.force_name) ? Symbol(spelling(cursor)) : ctx.force_name
    ret_type = clang2julia(return_type(cursor))
    args = function_args(cursor)
    arg_types = [argtype(func_type, i) for i in 0:length(args)-1]
    arg_reps = clang2julia.(arg_types)
    for (i, arg) in enumerate(arg_reps)
        # constant array argument should be converted to Ptr
        # e.g. double f[3] => Ptr{Cdouble} instead of NTuple{3, Cdouble}
        if Meta.isexpr(arg, :curly) && first(arg.args) == :NTuple
            arg_reps[i] = Expr(:curly, :Ptr, last(arg.args))
        end
    end

    # check whether any argument types are blocked
    for t in arg_types
        if spelling(t) in RESERVED_ARG_TYPES
            @warn "Skipping $(name(cursor)) due to unsupported argument: $(spelling(t))"
            return ctx
        end
    end

    # handle unnamed args and convert names to symbols
    arg_count = 0
    arg_names = map(args) do x
                    n = name_safe(name(x))
                    s = !isempty(n) ? n : "arg"*string(arg_count+=1)
                    Symbol(s)
                end

    isstrict = get(ctx.options, "is_function_strictly_typed", true)
    signature = isstrict ? efunsig(func_name, arg_names, arg_reps) : Expr(:call, func_name, arg_names...)

    ctx.libname == "libxxx" && @warn "default libname: \":libxxx\" are being used, did you forget to specify `context.libname`?"
    body = eccall(func_name, Symbol(ctx.libname), ret_type, arg_names, arg_reps)

    push!(ctx.api_buffer, Expr(:function, signature, Expr(:block, body)))

    return ctx
end

function is_ptr_type_expr(@nospecialize t)
    (t === :Cstring || t === :Cwstring) && return true
    isa(t, Expr) || return false
    t = t::Expr
    t.head === :curly && t.args[1] === :Ptr
end

function efunsig(name::Symbol, args::Vector{Symbol}, types)
    x = [is_ptr_type_expr(t) ? a : Expr(:(::), a, t) for (a,t) in zip(args,types)]
    Expr(:call, name, x...)
end

function eccall(func_name::Symbol, libname::Symbol, rtype, args, types)
  :(ccall(($(QuoteNode(func_name)), $libname),
            $rtype,
            $(Expr(:tuple, types...)),
            $(args...))
    )
end

"""
    wrap!(ctx::AbstractContext, cursor::CLEnumDecl)
Subroutine for handling enum declarations.
"""
function wrap!(ctx::AbstractContext, cursor::CLEnumDecl)
    cursor_name = name(cursor)
    # handle typedef anonymous enum
    idx = ctx.children_index
    if 0 < idx < length(ctx.children)
        next_cursor = ctx.children[idx+1]
        if is_typedef_anon(cursor, next_cursor)
            cursor_name = name(next_cursor)
        end
    end
    !isempty(ctx.force_name) && (cursor_name = ctx.force_name;)
    cursor_name == "" && (@warn("Skipping unnamed EnumDecl: $cursor"); return ctx)

    enum_sym = symbol_safe(cursor_name)
    enum_type = INT_CONVERSION[clang2julia(cursor)]
    name2value = Tuple{Symbol,Int}[]
    # extract values and names
    for item_cursor in children(cursor)
        kind(item_cursor) == CXCursor_PackedAttr && (@warn("this is a `__attribute__((packed))` enum, the underlying alignment of generated structure may not be compatible with the original one in C!"); continue)
        item_name = spelling(item_cursor)
        isempty(item_name) && continue
        item_sym = symbol_safe(item_name)
        push!(name2value, (item_sym, value(item_cursor)))
    end

    expr = Expr(:macrocall, Symbol("@cenum"), nothing, Expr(:(::), enum_sym, enum_type))
    enum_pairs = Expr(:block)
    ctx.common_buffer[enum_sym] = ExprUnit(expr)
    for (name,value) in name2value
        ctx.common_buffer[name] = ctx.common_buffer[enum_sym]  ##???
        push!(enum_pairs.args, :($name = $value))
    end
    push!(expr.args, enum_pairs)

    return ctx
end

"""
    wrap!(ctx::AbstractContext, cursor::CLStructDecl)
Subroutine for handling struct declarations.
"""
function wrap!(ctx::AbstractContext, cursor::CLStructDecl)
    # make sure a empty struct is indeed an opaque struct typedef/typealias
    # cursor = canonical(cursor)  # this won't work
    cursor = type(cursor) |> canonical |> typedecl
    cursor_name = name(cursor)
    # handle typedef anonymous struct
    idx = ctx.children_index
    if 0 < idx < length(ctx.children)
        next_cursor = ctx.children[idx+1]
        if is_typedef_anon(cursor, next_cursor)
            cursor_name = name(next_cursor)
        end
    end
    !isempty(ctx.force_name) && (cursor_name = ctx.force_name;)
    cursor_name == "" && (@warn("Skipping unnamed StructDecl: $cursor"); return ctx)

    struct_sym = symbol_safe(cursor_name)
    ismutable = get(ctx.options, "is_struct_mutable", false)
    buffer = ctx.common_buffer

    # generate struct declaration
    block = Expr(:block)
    expr = Expr(:struct, ismutable, struct_sym, block)
    deps = OrderedSet{Symbol}()
    struct_fields = children(cursor)
    for (field_idx, field_cursor) in enumerate(struct_fields)
        field_name = name(field_cursor)
        field_kind = kind(field_cursor)
        if field_kind == CXCursor_StructDecl || field_kind == CXCursor_UnionDecl
            continue
        elseif field_kind == CXCursor_FirstAttr
            continue
        elseif field_kind != CXCursor_FieldDecl || field_kind == CXCursor_TypeRef
            buffer[struct_sym] = ExprUnit(Poisoned())
            @warn "Skipping struct: \"$cursor\" due to unsupported field: $field_cursor"
            return ctx
        elseif isempty(field_name)
            error("Unnamed struct member in: $cursor ... cursor: $field_cursor")
        end

        if occursin("anonymous", string(clang2julia(field_cursor)))
            idx = field_idx-1
            anonymous_record = struct_fields[idx]
            while idx != 0 && kind(anonymous_record) == CXCursor_FieldDecl
                idx -= 1
                anonymous_record = struct_fields[idx]
            end
            if idx == field_idx-1
                ctx.anonymous_counter += 1
                anon_name = "ANONYMOUS$(ctx.anonymous_counter)_"*spelling(field_cursor)
                ctx.force_name = anon_name
                wrap!(ctx, anonymous_record)
                ctx.force_name = ""
                repr = symbol_safe(anon_name)
            else
                anon_name = "ANONYMOUS$(ctx.anonymous_counter)_"*spelling(struct_fields[idx+1])
                repr = symbol_safe(anon_name)
            end
        else
            repr = clang2julia(field_cursor)
        end
        push!(block.args, Expr(:(::), symbol_safe(field_name), repr))
        push!(deps, target_type(repr))
    end

    # check for a previous forward ordering
    if !(struct_sym in keys(buffer)) || buffer[struct_sym].state == :empty
        if !isempty(struct_fields)
            buffer[struct_sym] = ExprUnit(expr, deps)
        else
            # opaque struct typedef/typealias
            buffer[struct_sym] = ExprUnit(:(const $struct_sym = Cvoid), deps, state=:empty)
        end
    end

    return ctx
end

"""
    wrap!(ctx::AbstractContext, cursor::CLUnionDecl)
Subroutine for handling union declarations.
"""
function wrap!(ctx::AbstractContext, cursor::CLUnionDecl)
    # make sure a empty union is indeed an opaque union typedef/typealias
    cursor = type(cursor) |> canonical |> typedecl
    cursor_name = name(cursor)
    # handle typedef anonymous union
    idx = ctx.children_index
    if 0 < idx < length(ctx.children)
        next_cursor = ctx.children[idx+1]
        if is_typedef_anon(cursor, next_cursor)
            cursor_name = name(next_cursor)
        end
    end
    !isempty(ctx.force_name) && (cursor_name = ctx.force_name;)
    cursor_name == "" && (@warn("Skipping unnamed UnionDecl: $cursor"); return ctx)

    union_sym = symbol_safe(cursor_name)
    ismutable = get(ctx.options, "is_struct_mutable", false)
    buffer = ctx.common_buffer

    block = Expr(:block)
    expr = Expr(:struct, ismutable, union_sym, block)
    deps = OrderedSet{Symbol}()
    # find the largest union field and declare a block of bytes to match.
    union_fields = children(cursor)
    if !isempty(union_fields)
        max_size = 0
        largest_field_idx = 0
        for i = 1:length(union_fields)
            field_cursor = union_fields[i]
            field_kind = kind(field_cursor)
            (field_kind == CXCursor_StructDecl || field_kind == CXCursor_UnionDecl) && continue
            field_kind == CXCursor_FirstAttr && continue
            field_size = typesize(type(field_cursor))
            if field_size > max_size
                max_size = field_size
                largest_field_idx = i
            end
        end
        largest_field = union_fields[largest_field_idx]
        if occursin("anonymous", string(clang2julia(largest_field)))
            idx = largest_field_idx-1
            anonymous_record = union_fields[idx]
            while idx != 0 && kind(anonymous_record) == CXCursor_FieldDecl
                idx -= 1
                anonymous_record = union_fields[idx]
            end
            ctx.anonymous_counter += 1
            anon_name = "ANONYMOUS$(ctx.anonymous_counter)_"*spelling(largest_field)
            ctx.force_name = anon_name
            wrap!(ctx, anonymous_record)
            ctx.force_name = ""
            repr = symbol_safe(anon_name)
        else
            repr = clang2julia(largest_field)
        end
        largest_field_sym = symbol_safe(spelling(largest_field))
        push!(block.args, Expr(:(::), largest_field_sym, repr))
        push!(deps, target_type(repr))
        buffer[union_sym] = ExprUnit(expr, deps)
    elseif !(union_sym in keys(buffer)) || buffer[union_sym].state == :empty
        buffer[union_sym] = ExprUnit(:(const $union_sym = Cvoid), deps, state=:empty)
    else
        @warn "Skipping union: \"$cursor\" due to unknown cases."
    end

    return ctx
end

"""
    wrap!(ctx::AbstractContext, cursor::CLTypedefDecl)
Subroutine for handling typedef declarations.
"""
function wrap!(ctx::AbstractContext, cursor::CLTypedefDecl)
    td_type = underlying_type(cursor)
    td_sym = isempty(ctx.force_name) ? Symbol(spelling(cursor)) : ctx.force_name
    buffer = ctx.common_buffer
    if kind(td_type) == CXType_Unexposed
        # TODO: which corner case will trigger this pass?
        @error "Skipping Typedef: CXType_Unexposed, $cursor, please report this on Github."
    end

    if kind(td_type) == CXType_FunctionProto
        # TODO: need to find a test case too
        if !haskey(buffer, td_sym)
            buffer[td_sym] = ExprUnit(string("# Skipping Typedef: CXType_FunctionProto ", spelling(cursor)))
        end
        return ctx
    end

    td_target = clang2julia(td_type)
    if !haskey(buffer, td_sym)
        buffer[td_sym] = ExprUnit(:(const $td_sym = $td_target), [td_target])
    end
    return ctx
end


"""
    handle_macro_exprn(tokens::TokenList, pos::Int)
For handling of #define'd constants, allows basic expressions but bails out quickly.
"""
function handle_macro_exprn(tokens::TokenList, pos::Int)
    function trans(tok)
        ops = ["+" "-" "*" "~" ">>" "<<" "/" "\\" "%" "|" "||" "^" "&" "&&" "=="]
        token_kind = kind(tok)
        (token_kind == CXToken_Literal || token_kind == CXToken_Identifier) && return 0
        token_kind == CXToken_Punctuation && tok.text ∈ ops && return 1
        return -1
    end

    # normalize literal with a size suffix
    function literally(tok)
        # note: put multi-character first, or it will break out too soon for those!
        literalsuffixes = ["ULL", "Ull", "uLL", "ull", "LLU", "LLu", "llU", "llu",
                           "LL", "ll", "UL", "Ul", "uL", "ul", "LU", "Lu", "lU", "lu",
                           "U", "u", "L", "l", "F", "f"]

        function literal_totype(literal, txt)
          literal = lowercase(literal)

          # Floats following http://en.cppreference.com/w/cpp/language/floating_literal
          float64 = occursin(".", txt) && occursin("l", literal)
          float32 = occursin("f", literal)

          if float64 || float32
            float64 && return "Float64"
            float32 && return "Float32"
          end

          # Integers following http://en.cppreference.com/w/cpp/language/integer_literal
          unsigned = occursin("u", literal)
          nbits = count(x -> x == 'l', literal) == 2 ? 64 : 32
          return "$(unsigned ? "U" : "")Int$nbits"
        end

        token_kind = kind(tok)
        txt = tok.text |> strip
        if token_kind == CXToken_Identifier || token_kind == CXToken_Punctuation
            # pass
        elseif token_kind == CXToken_Literal
            for sfx in literalsuffixes
                if endswith(txt, sfx)
                    type = literal_totype(sfx, txt)
                    txt = txt[1:end-length(sfx)]
                    txt = "$(type)($txt)"
                    break
                end
            end
        end
        return txt
    end

    # @info tokens
    # for i = 1:length(tokens)
    #     @info tokens[i]
    # end
    
    # check whether identifiers and literals alternate
    # with punctuation
    exprn = ""
    pos > length(tokens) && return exprn, pos

    prev = 1 >> trans(tokens[pos])
    for lpos = pos:length(tokens)
        pos = lpos
        tok = tokens[lpos]
        state = trans(tok)
        if xor(state, prev) == 1
            prev = state
        else
            break
        end
        exprn = exprn * literally(tok)
    end
    return exprn, pos
end

function handle_macro_simple(ctx::AbstractContext, cursor::CLMacroDefinition)::Bool
    tokens = tokenize(cursor)
    tokenGroups = []
    curGroup = []
    exprn = String[]
    brackets = 0

    function tokenGroupsToString(tokenGroups) 
        s = ""
        for tokens in tokenGroups
            s *= " " * mapreduce(t -> t.text, *, tokens)
        end
        return s
    end

    for token in tokens
        # @show kind(token)
        # @show token.text
        
        if length(curGroup) == 0
            push!(curGroup, token)
        elseif kind(curGroup[1]) == CXToken_Identifier && kind(token) == CXToken_Identifier
            push!(tokenGroups, curGroup)
            curGroup = []
            push!(curGroup, token)
        elseif kind(curGroup[1]) == CXToken_Identifier && token.text == "("
            brackets += 1
            push!(tokenGroups, curGroup)
            curGroup = []
            push!(curGroup, token)
        elseif curGroup[1].text == "(" && token.text == ")"
            push!(curGroup, token)
            brackets -= 1
            if brackets == 0
                push!(tokenGroups, curGroup)
                curGroup = []
            end
        elseif curGroup[1].text == "(" && token.text == "("
            brackets += 1
            push!(curGroup, token)
        else
            push!(curGroup, token)
        end
    end
    if length(curGroup) != 0
        push!(tokenGroups, curGroup)
    end

    # for cGroup = 1:length(tokenGroups)
    #     group = tokenGroups[cGroup]
    #     firstKind = kind(group[1])
    #     groupStr = mapreduce(t -> t.text, *, group)
    #     println("Group: $cGroup ($firstKind) $groupStr")
    # end

    try
        if length(tokenGroups) == 2 &&
                kind(tokenGroups[1][1]) == CXToken_Identifier && 
                kind(tokenGroups[2][1]) != CXToken_Identifier
            id1 = tokenGroups[1][1].text
            lit = mapreduce(t -> t.text, *, tokenGroups[2])
            exprStr = "const " * id1 * " = " * lit
            # @show exprStr
            target = Meta.parse(exprStr)
            deps = get_symbols(target)
            # const foo = <literal>
            ctx.common_buffer[symbol_safe(id1)] = ExprUnit(target, deps)
            return true
        elseif length(tokenGroups) == 3 && 
                kind(tokenGroups[1][1]) == CXToken_Identifier && 
                kind(tokenGroups[2][1]) == CXToken_Identifier && 
                tokenGroups[3][1].text == "("
            id1 = tokenGroups[1][1].text
            id2 = tokenGroups[2][1].text
            lit = mapreduce(t -> t.text, *, tokenGroups[3])
            exprStr = "const " * id1 * " = " * id2 * lit
            # @show exprStr
            target = Meta.parse(exprStr)
            deps = get_symbols(target)
            # const foo = bar(<literal>)
            ctx.common_buffer[symbol_safe(id1)] = ExprUnit(target, deps)
            return true
        elseif length(tokenGroups) == 4 &&
                kind(tokenGroups[1][1]) == CXToken_Identifier && 
                tokenGroups[2][1].text == "("   
                kind(tokenGroups[3][1]) == CXToken_Identifier && 
                tokenGroups[4][1].text == "("
            id1 = tokenGroups[1][1].text
            lit1 = mapreduce(t -> t.text, *, tokenGroups[2])
            id2 = tokenGroups[3][1].text
            lit2 = mapreduce(t -> t.text, *, tokenGroups[4])
            exprStr = "const " * id1 * lit1 * " = " * id2 * lit2
            # @show exprStr
            target = Meta.parse(exprStr)
            deps = get_symbols(target)
            # const foo = bar(<literal>)
            ctx.common_buffer[symbol_safe(id1) ] = ExprUnit(target, deps)
            return true
        else
            s = tokenGroupsToString(tokenGroups)
            @info "Not able to simple-wrap: $s" 
        end
    catch exc
         s = tokenGroupsToString(tokenGroups)
        @info "Exception, not able to simple-wrap: $s"
    end

    return false
end

# Assume #define foo(...) bar(...) => const foo(..) = bar(...)
# function handle_macro_func(ctx::AbstractContext, cursor::CLMacroDefinition)

#     # dump(cursor)
#     tokens = tokenize(cursor)
#     exprn = String[]

#     for token in tokens
#         @show kind(token)
#         @show token.text
#     end

#     push!(exprn, "const ")
#     tokenInd = 1
#     if kind(tokens[tokenInd]) == CXToken_Identifier
#         push!(exprn, tokens[tokenInd].text)
#     else 
#         return
#     end

#     # @show exprn

#     tokenInd += 1
#     if kind(tokens[tokenInd]) == CXToken_Punctuation && tokens[tokenInd].text == "("
#         push!(exprn, "(")
#     else
#         return
#     end

#     # @show exprn

#     tokenInd += 1
#     while tokenInd <= length(tokens)
#         if kind(tokens[tokenInd]) == CXToken_Punctuation && tokens[tokenInd].text == ")"
#             push!(exprn, ")")
#             break
#         elseif kind(tokens[tokenInd]) == CXToken_Punctuation && tokens[tokenInd].text == ","
#             push!(exprn, ",")
#         elseif kind(tokens[tokenInd]) == CXToken_Identifier
#             push!(exprn, tokens[tokenInd].text)
#         end
#         tokenInd += 1
#     end 

#     push!(exprn, " = ")

#     # @show exprn

#     tokenInd += 1
#     if kind(tokens[tokenInd]) == CXToken_Identifier
#         push!(exprn, tokens[tokenInd].text)
#     else 
#         return
#     end

#     # @show exprn

#     tokenInd += 1
#     if kind(tokens[tokenInd]) == CXToken_Punctuation && tokens[tokenInd].text == "("
#         push!(exprn, "(")
#     else
#         return
#     end

#     # @show exprn

#     tokenInd += 1
#     @show length(tokens)
#     while tokenInd <= length(tokens)
#         if kind(tokens[tokenInd]) == CXToken_Punctuation && tokens[tokenInd].text == ")"
#             push!(exprn, ")")
#             break
#         elseif kind(tokens[tokenInd]) == CXToken_Punctuation && tokens[tokenInd].text == ","
#             push!(exprn, ",")
#         elseif kind(tokens[tokenInd]) == CXToken_Identifier
#             push!(exprn, tokens[tokenInd].text)
#         end
#         tokenInd += 1
#     end 
    
#     # @show exprn
#     buffer = ctx.common_buffer
#     use_sym = symbol_safe(tokens[1].text)
#     target = Meta.parse(join(exprn))
#     deps = get_symbols(target)
#     # @show join(exprn)
#     buffer[use_sym] = ExprUnit(target, deps)
#  end

# TODO: This really returns many more symbols than we want,
# Functionally, it shouldn't matter, but eventually, we
# might want something more sophisticated.
# (Check: Does this functionality already exist elsewhere?)
get_symbols(s) = Any[]
get_symbols(s::Symbol) = Any[s]
get_symbols(e::Expr) = vcat(get_symbols(e.head), get_symbols(e.args))
get_symbols(xs::Array) = reduce(vcat, [get_symbols(x) for x in xs])

"""
    wrap!(ctx::AbstractContext, cursor::CLMacroDefinition)
Subroutine for handling macro declarations.
"""
function wrap!(ctx::AbstractContext, cursor::CLMacroDefinition)
    if handle_macro_simple(ctx, cursor)
         return ctx
    else
        tokens = tokenize(cursor)
        
        # for token in tokens
        #     @show kind(token)
        #     @show token.text
        # end
        
        # Skip any empty definitions
        tokens.size < 2 && return ctx
        startswith(name(cursor), "_") && return ctx

        buffer = ctx.common_buffer
        pos = 1; exprn = ""
        if tokens[2].text == "("
            exprn, pos = handle_macro_exprn(tokens, 3)
            if pos != lastindex(tokens) || tokens[pos].text != ")" || exprn == ""
                mdef_str = join([c.text for c in tokens], " ")
                buffer[Symbol(mdef_str)] = ExprUnit(string("# Skipping MacroDefinition: ", replace(mdef_str, "\n"=>"\n#")))
                return ctx
            end
            exprn = "(" * exprn * ")"
        else
            exprn, pos = handle_macro_exprn(tokens, 2)
            if pos != lastindex(tokens)
                mdef_str = join([c.text for c in tokens], " ")
                buffer[Symbol(mdef_str)] = ExprUnit(string("# Skipping MacroDefinition: ", replace(mdef_str, "\n"=>"#\n")))
                return ctx
            end
        end

        # Occasionally, skipped definitions slip through
        (exprn == "" || exprn == "()") && return buffer

        use_sym = symbol_safe(tokens[1].text)

        try
            target = Meta.parse(exprn)
            e = Expr(:const, Expr(:(=), use_sym, target))
            deps = get_symbols(target)
            buffer[use_sym] = ExprUnit(e, deps)
        catch err
            # this assumes all parsing failures are due to string-parsing
            ## TODO: find a elegant way to solve this
            e = :(const $use_sym = $(exprn[2:end-1]))
            buffer[use_sym] = ExprUnit(e,[])
        end
    end
    
    return ctx
end

"""
    wrap!(ctx::AbstractContext, cursor::CLTypeRef)
For now, we just skip CXCursor_TypeRef cursors.
"""
function wrap!(ctx::AbstractContext, cursor::CLTypeRef)
    @warn "Skipping CXCursor_TypeRef cursor: $cursor"
    return ctx
end

function wrap!(ctx::AbstractContext, cursor::CLCursor)
    @warn "not wrapping $(cursor)"
    return ctx
end

function wrap!(ctx::AbstractContext, cursor::Union{CLLastPreprocessing,CLMacroInstantiation})
    @debug "not wrapping $(cursor)"
    return ctx
end
