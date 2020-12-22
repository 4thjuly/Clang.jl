using Clang
using Clang.LibClang
using Test

@testset "macro" begin
    trans_unit = parse_header(joinpath(@__DIR__, "c", "macro.h"),
                              flags = CXTranslationUnit_DetailedPreprocessingRecord)
    ctx = DefaultContext()
    push!(ctx.trans_units, trans_unit)
    root_cursor = getcursor(trans_unit)
    cursors = children(root_cursor)
    g_uri_xxx = search(cursors, x->name(x)=="G_URI_RESERVED_CHARS_SUBCOMPONENT_DELIMITERS")[1]
    wrap!(ctx, g_uri_xxx)
    expr = :(const G_URI_RESERVED_CHARS_SUBCOMPONENT_DELIMITERS = "!\$&'()*+,;=")
    @test ctx.common_buffer[:G_URI_RESERVED_CHARS_SUBCOMPONENT_DELIMITERS].items[1] == expr

    # test tokenize for macro instantiation
    func = search(cursors, x->kind(x)==CXCursor_FunctionDecl)[1]
    body = children(func)[1]
    op = children(body)[3]
    subop = children(op)[2]
    @test mapreduce(x->x.text, *, tokenize(subop)) == "FOO(foo,1,x)"
    wrap!(ctx, func)
    @test !isempty(ctx.api_buffer)

    # Issue #270 Support '==' in macros
    equals_macro = search(cursors, x->name(x)=="EQUALS_A_B")[1]
    wrap!(ctx, equals_macro)
    @test ctx.common_buffer[:EQUALS_A_B].items[1] == :(const EQUALS_A_B = A == B)

    # Permissive
    foo1_macro = search(cursors, x->name(x)=="FOO1")[1]
    wrap!(ctx, foo1_macro)
    @test ctx.common_buffer[:FOO1].items[1] == :(const FOO1 = bar1(0x1234))

    foo2_macro = search(cursors, x->name(x)=="FOO2")[1]
    wrap!(ctx, foo2_macro)
    @test ctx.common_buffer[:FOO2].items[1] == :(const FOO2 = (((0 | BAR2) | BAR3) | BAR4) | BAR5)

    foo3_macro = search(cursors, x->name(x)=="FOO3")[1]
    wrap!(ctx, foo3_macro)
    @show ctx.common_buffer[:FOO3].items[1]
    # @test ctx.common_buffer[:FOO3].items[1] == :(const FOO3(x, y) = BAR6(x, y, x, y))
end
