# This file is a part of Julia. License is MIT: https://julialang.org/license

# Method and method table pretty-printing

const empty_sym = Symbol("")
function strip_gensym(sym)
    if sym === :var"#self#" || sym === :var"#unused#"
        return empty_sym
    end
    return Symbol(replace(String(sym), r"^(.*)#(.*#)?\d+$" => s"\1"))
end

function argtype_decl(env, n, @nospecialize(sig::DataType), i::Int, nargs, isva::Bool) # -> (argname, argtype)
    t = sig.parameters[unwrapva(min(i, end))]
    if i == nargs && isva
        va = sig.parameters[end]
        if isvarargtype(va) && (!isdefined(va, :N) || !isa(va.N, Int))
            t = va
        else
            ntotal = length(sig.parameters)
            isvarargtype(va) && (ntotal += va.N - 1)
            t = Vararg{t,ntotal-nargs+1}
        end
    end
    if isa(n,Expr)
        n = n.args[1]  # handle n::T in arg list
    end
    n = strip_gensym(n)
    local s
    if n === empty_sym
        s = ""
    else
        s = sprint(show_sym, n)
        t === Any && return s, ""
    end
    if isvarargtype(t)
        if !isdefined(t, :N)
            if unwrapva(t) === Any
                return string(s, "..."), ""
            else
                return s, string_with_env(env, unwrapva(t)) * "..."
            end
        end
        return s, string_with_env(env, "Vararg{", t.T, ", ", t.N, "}")
    end
    return s, string_with_env(env, t)
end

function method_argnames(m::Method)
    argnames = ccall(:jl_uncompress_argnames, Vector{Symbol}, (Any,), m.slot_syms)
    isempty(argnames) && return argnames
    return argnames[1:m.nargs]
end

function arg_decl_parts(m::Method, html=false)
    tv = Any[]
    sig = m.sig
    while isa(sig, UnionAll)
        push!(tv, sig.var)
        sig = sig.body
    end
    file = m.file
    line = m.line
    argnames = method_argnames(m)
    if length(argnames) >= m.nargs
        show_env = ImmutableDict{Symbol, Any}()
        for t in tv
            show_env = ImmutableDict(show_env, :unionall_env => t)
        end
        decls = Tuple{String,String}[argtype_decl(show_env, argnames[i], sig, i, m.nargs, m.isva)
                    for i = 1:m.nargs]
        decls[1] = ("", sprint(show_signature_function, unwrapva(sig.parameters[1]), false, decls[1][1], html,
                               context = show_env))
    else
        decls = Tuple{String,String}[("", "") for i = 1:length(sig.parameters::SimpleVector)]
    end
    return tv, decls, file, line
end

# NOTE: second argument is deprecated and is no longer used
function kwarg_decl(m::Method, kwtype = nothing)
    mt = get_methodtable(m)
    if isdefined(mt, :kwsorter)
        kwtype = typeof(mt.kwsorter)
        sig = rewrap_unionall(Tuple{kwtype, Any, (unwrap_unionall(m.sig)::DataType).parameters...}, m.sig)
        kwli = ccall(:jl_methtable_lookup, Any, (Any, Any, UInt), kwtype.name.mt, sig, get_world_counter())
        if kwli !== nothing
            kwli = kwli::Method
            slotnames = ccall(:jl_uncompress_argnames, Vector{Symbol}, (Any,), kwli.slot_syms)
            kws = filter(x -> !(x === empty_sym || '#' in string(x)), slotnames[(kwli.nargs + 1):end])
            # ensure the kwarg... is always printed last. The order of the arguments are not
            # necessarily the same as defined in the function
            i = findfirst(x -> endswith(string(x)::String, "..."), kws)
            if i !== nothing
                push!(kws, kws[i])
                deleteat!(kws, i)
            end
            return kws
        end
    end
    return Symbol[]
end

function show_method_params(io::IO, tv)
    if !isempty(tv)
        print(io, " where ")
        if length(tv) == 1
            show(io, tv[1])
        else
            print(io, "{")
            for i = 1:length(tv)
                if i > 1
                    print(io, ", ")
                end
                x = tv[i]
                show(io, x)
                io = IOContext(io, :unionall_env => x)
            end
            print(io, "}")
        end
    end
end

# In case the line numbers in the source code have changed since the code was compiled,
# allow packages to set a callback function that corrects them.
# (Used by Revise and perhaps other packages.)
# Any function `f` stored here must be consistent with the signature
#    f(m::Method)::Tuple{Union{Symbol,String}, Union{Int32,Int64}}
const methodloc_callback = Ref{Union{Function, Nothing}}(nothing)

function fixup_stdlib_path(path::String)
    # The file defining Base.Sys gets included after this file is included so make sure
    # this function is valid even in this intermediary state
    if isdefined(@__MODULE__, :Sys) && Sys.BUILD_STDLIB_PATH != Sys.STDLIB::String
        # BUILD_STDLIB_PATH gets defined in sysinfo.jl
        path = replace(path, normpath(Sys.BUILD_STDLIB_PATH) => normpath(Sys.STDLIB::String))
    end
    return path
end

# This function does the method location updating
function updated_methodloc(m::Method)::Tuple{String, Int32}
    file, line = m.file, m.line
    if methodloc_callback[] !== nothing
        try
            file, line = invokelatest(methodloc_callback[], m)::Tuple{Union{Symbol,String}, Union{Int32,Int64}}
        catch
        end
    end
    file = fixup_stdlib_path(string(file))
    return file, Int32(line)
end

functionloc(m::Core.MethodInstance) = functionloc(m.def)

"""
    functionloc(m::Method)

Returns a tuple `(filename,line)` giving the location of a `Method` definition.
"""
function functionloc(m::Method)
    file, ln = updated_methodloc(m)
    if ln <= 0
        error("could not determine location of method definition")
    end
    return (find_source_file(string(file)), ln)
end

"""
    functionloc(f::Function, types)

Returns a tuple `(filename,line)` giving the location of a generic `Function` definition.
"""
functionloc(@nospecialize(f), @nospecialize(types)) = functionloc(which(f,types))

function functionloc(@nospecialize(f))
    mt = methods(f)
    if isempty(mt)
        if isa(f, Function)
            error("function has no definitions")
        else
            error("object is not callable")
        end
    end
    if length(mt) > 1
        error("function has multiple methods; please specify a type signature")
    end
    return functionloc(first(mt))
end

function sym_to_string(sym)
    s = String(sym)
    if endswith(s, "...")
        return string(sprint(show_sym, Symbol(s[1:end-3])), "...")
    else
        return sprint(show_sym, sym)
    end
end

function show(io::IO, m::Method)
    tv, decls, file, line = arg_decl_parts(m)
    sig = unwrap_unionall(m.sig)
    if sig === Tuple
        # Builtin
        print(io, m.name, "(...) in ", m.module)
        return
    end
    print(io, decls[1][2], "(")
    join(
        io,
        String[isempty(d[2]) ? d[1] : string(d[1], "::", d[2]) for d in decls[2:end]],
        ", ",
        ", ",
    )
    kwargs = kwarg_decl(m)
    if !isempty(kwargs)
        print(io, "; ")
        join(io, map(sym_to_string, kwargs), ", ", ", ")
    end
    print(io, ")")
    show_method_params(io, tv)
    print(io, " in ", m.module)
    if line > 0
        file, line = updated_methodloc(m)
        print(io, " at ", file, ":", line)
    end
    nothing
end

function show_method_list_header(io::IO, ms::MethodList, namefmt::Function)
    mt = ms.mt
    name = mt.name
    hasname = isdefined(mt.module, name) &&
              typeof(getfield(mt.module, name)) <: Function
    n = length(ms)
    m = n==1 ? "method" : "methods"
    print(io, "# $n $m")
    sname = string(name)
    namedisplay = namefmt(sname)
    if hasname
        what = (startswith(sname, '@') ?
                    "macro"
               : mt.module === Core && last(ms).sig === Tuple ?
                    "builtin function"
               : # else
                    "generic function")
        print(io, " for ", what, " ", namedisplay)
    elseif '#' in sname
        print(io, " for anonymous function ", namedisplay)
    elseif mt === _TYPE_NAME.mt
        print(io, " for type constructor")
    else
        print(io, " for callable object")
    end
    n > 0 && print(io, ":")
    nothing
end

function show_method_table(io::IO, ms::MethodList, max::Int=-1, header::Bool=true)
    mt = ms.mt
    name = mt.name
    hasname = isdefined(mt.module, name) &&
              typeof(getfield(mt.module, name)) <: Function
    if header
        show_method_list_header(io, ms, str -> "\""*str*"\"")
    end
    n = rest = 0
    local last

    last_shown_line_infos = get(io, :last_shown_line_infos, nothing)
    last_shown_line_infos === nothing || empty!(last_shown_line_infos)

    for meth in ms
        if max == -1 || n < max
            n += 1
            println(io)
            print(io, "[$n] ")
            show(io, meth)
            file, line = updated_methodloc(meth)
            if last_shown_line_infos !== nothing
                push!(last_shown_line_infos, (string(file), line))
            end
        else
            rest += 1
            last = meth
        end
    end
    if rest > 0
        println(io)
        if rest == 1
            show(io, last)
        else
            print(io, "... $rest methods not shown")
            if hasname
                print(io, " (use methods($name) to see them all)")
            end
        end
    end
    nothing
end

show(io::IO, ms::MethodList) = show_method_table(io, ms)
show(io::IO, ::MIME"text/plain", ms::MethodList) = show_method_table(io, ms)
show(io::IO, mt::Core.MethodTable) = show_method_table(io, MethodList(mt))

function inbase(m::Module)
    if m == Base
        true
    else
        parent = parentmodule(m)
        parent === m ? false : inbase(parent)
    end
end
fileurl(file) = let f = find_source_file(file); f === nothing ? "" : "file://"*f; end

function url(m::Method)
    M = m.module
    (m.file === :null || m.file === :string) && return ""
    file = string(m.file)
    line = m.line
    line <= 0 || occursin(r"In\[[0-9]+\]", file) && return ""
    Sys.iswindows() && (file = replace(file, '\\' => '/'))
    libgit2_id = PkgId(UUID((0x76f85450_5226_5b5a,0x8eaa_529ad045b433)), "LibGit2")
    if inbase(M)
        if isempty(Base.GIT_VERSION_INFO.commit)
            # this url will only work if we're on a tagged release
            return "https://github.com/JuliaLang/julia/tree/v$VERSION/base/$file#L$line"
        else
            return "https://github.com/JuliaLang/julia/tree/$(Base.GIT_VERSION_INFO.commit)/base/$file#L$line"
        end
    elseif root_module_exists(libgit2_id)
        LibGit2 = root_module(libgit2_id)
        try
            d = dirname(file)
            return LibGit2.with(LibGit2.GitRepoExt(d)) do repo
                LibGit2.with(LibGit2.GitConfig(repo)) do cfg
                    u = LibGit2.get(cfg, "remote.origin.url", "")
                    u = match(LibGit2.GITHUB_REGEX,u).captures[1]
                    commit = string(LibGit2.head_oid(repo))
                    root = LibGit2.path(repo)
                    if startswith(file, root) || startswith(realpath(file), root)
                        "https://github.com/$u/tree/$commit/"*file[length(root)+1:end]*"#L$line"
                    else
                        fileurl(file)
                    end
                end
            end
        catch
            return fileurl(file)
        end
    else
        return fileurl(file)
    end
end

function show(io::IO, ::MIME"text/html", m::Method)
    tv, decls, file, line = arg_decl_parts(m, true)
    sig = unwrap_unionall(m.sig)
    if sig === Tuple
        # Builtin
        print(io, m.name, "(...) in ", m.module)
        return
    end
    print(io, decls[1][2], "(")
    join(
        io,
        String[
            isempty(d[2]) ? d[1] : string(d[1], "::<b>", d[2], "</b>") for d in decls[2:end]
        ],
        ", ",
        ", ",
    )
    kwargs = kwarg_decl(m)
    if !isempty(kwargs)
        print(io, "; <i>")
        join(io, map(sym_to_string, kwargs), ", ", ", ")
        print(io, "</i>")
    end
    print(io, ")")
    if !isempty(tv)
        print(io,"<i>")
        show_method_params(io, tv)
        print(io,"</i>")
    end
    print(io, " in ", m.module)
    if line > 0
        file, line = updated_methodloc(m)
        u = url(m)
        if isempty(u)
            print(io, " at ", file, ":", line)
        else
            print(io, """ at <a href="$u" target="_blank">""",
                  file, ":", line, "</a>")
        end
    end
end

function show(io::IO, mime::MIME"text/html", ms::MethodList)
    mt = ms.mt
    show_method_list_header(io, ms, str -> "<b>"*str*"</b>")
    print(io, "<ul>")
    for meth in ms
        print(io, "<li> ")
        show(io, mime, meth)
        print(io, "</li> ")
    end
    print(io, "</ul>")
end

show(io::IO, mime::MIME"text/html", mt::Core.MethodTable) = show(io, mime, MethodList(mt))

# pretty-printing of AbstractVector{Method}
function show(io::IO, mime::MIME"text/plain", mt::AbstractVector{Method})
    last_shown_line_infos = get(io, :last_shown_line_infos, nothing)
    last_shown_line_infos === nothing || empty!(last_shown_line_infos)
    first = true
    for (i, m) in enumerate(mt)
        first || println(io)
        first = false
        print(io, "[$(i)] ")
        show(io, m)
        file, line = updated_methodloc(m)
        if last_shown_line_infos !== nothing
            push!(last_shown_line_infos, (string(file), line))
        end
    end
end

function show(io::IO, mime::MIME"text/html", mt::AbstractVector{Method})
    summary(io, mt)
    if !isempty(mt)
        print(io, ":<ul>")
        for d in mt
            print(io, "<li> ")
            show(io, mime, d)
        end
        print(io, "</ul>")
    end
end
