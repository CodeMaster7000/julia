Julia v1.8 Release Notes
========================


New language features
---------------------

* `Module(:name, false, false)` can be used to create a `module` that contains no names (it does not import `Base` or `Core` and does not contain a reference to itself). ([#40110, #42154])
* `@inline` and `@noinline` annotations can be used within a function body to give an extra
  hint about the inlining cost to the compiler. ([#41312])
* `@inline` and `@noinline` annotations can now be applied to a function callsite or block
  to enforce the involved function calls to be (or not to be) inlined. ([#41312])
* The default behavior of observing `@inbounds` declarations is now an option via `auto` in `--check-bounds=yes|no|auto` ([#41551])
* New function `eachsplit(str)` for iteratively performing `split(str)`.
* `∀`, `∃`, and `∄` are now allowed as identifier characters ([#42314]).
* Support for Unicode 14.0.0 ([#43443]).
* `try`-blocks can now optionally have an `else`-block which is executed right after the main body only if
  no errors were thrown. ([#42211])
* Mutable struct fields may now be annotated as `const` to prevent changing
  them after construction, providing for greater clarity and optimization
  ability of these objects ([#43305]).
* Empty n-dimensional arrays can now be created using multiple semicolons inside square brackets, i.e. `[;;;]` creates a 0×0×0 `Array`. ([#41618])

Language changes
----------------

* Newly created Task objects (`@spawn`, `@async`, etc.) now adopt the world-age for methods from their parent
  Task upon creation, instead of using the global latest world at start. This is done to enable inference to
  eventually optimize these calls. Places that wish for the old behavior may use `Base.invokelatest`. ([#41449])
* `@time` and `@timev` now take an optional description to allow annotating the source of time reports.
  i.e. `@time "Evaluating foo" foo()` ([#42431])
* New `@showtime` macro to show both the line being evaluated and the `@time` report ([#42431])
* Iterating an `Iterators.Reverse` now falls back on reversing the eachindex iterator, if possible ([#43110]).
* Unbalanced Unicode bidirectional formatting directives are now disallowed within strings and comments,
  to mitigate the ["trojan source"](https://www.trojansource.codes) vulnerability ([#42918]).
* `Base.ifelse` is now defined as a generic function rather than a builtin one, allowing packages to
  extend its definition ([#37343]).

Compiler/Runtime improvements
-----------------------------

* Bootstrapping time has been improved by about 25% ([#41794]).
* The LLVM-based compiler has been separated from the run-time library into a new library,
  `libjulia-codegen`. It is loaded by default, so normal usage should see no changes.
  In deployments that do not need the compiler (e.g. system images where all needed code
  is precompiled), this library (and its LLVM dependency) can simply be excluded ([#41936]).
* Conditional type constraint can now be forwarded interprocedurally (i.e. propagated from caller to callee) ([#42529]).
* Julia-level SROA (Scalar Replacement of Aggregates) has been improved, i.e. allowing elimination of
  `getfield` call with constant global field ([#42355]), enabling elimination of mutable struct with
  uninitialized fields ([#43208]), improving performance ([#43232]), handling more nested `getfield`
  calls ([#43239]).
* Abstract callsite can now be inlined or statically resolved as far as the callsite has a single
  matching method ([#43113]).
* Builtin function are now a bit more like generic functions, and can be enumerated with `methods` ([#43865]).

Command-line option changes
---------------------------

* New option `--strip-metadata` to remove docstrings, source location information, and local
  variable names when building a system image ([#42513]).
* New option `--strip-ir` to remove the compiler's IR (intermediate representation) of source
  code when building a system image. The resulting image will only work if `--compile=all` is
  used, or if all needed code is precompiled ([#42925]).
* When the program file is `-` the code to be executed is read from standard in ([#43191]).

Multi-threading changes
-----------------------


Build system changes
--------------------


New library functions
---------------------

* `hardlink(src, dst)` can be used to create hard links. ([#41639])
* `setcpuaffinity(cmd, cpus)` can be used to set CPU affinity of sub-processes. ([#42469])
* `diskstat(path=pwd())` can be used to return statistics about the disk. ([#42248])

New library features
--------------------

* `@test_throws "some message" triggers_error()` can now be used to check whether the displayed error text
  contains "some message" regardless of the specific exception type.
  Regular expressions, lists of strings, and matching functions are also supported. ([#41888])
* `@testset foo()` can now be used to create a test set from a given function. The name of the test set
  is the name of the called function. The called function can contain `@test` and other `@testset`
  definitions, including to other function calls, while recording all intermediate test results. ([#42518])
* Keys with value `nothing` are now removed from the environment in `addenv` ([#43271]).

Standard library changes
------------------------

* `range` accepts either `stop` or `length` as a sole keyword argument ([#39241])
* `precision` and `setprecision` now accept a `base` keyword ([#42428]).
* `Iterators.reverse` (and hence `last`) now supports `eachline` iterators ([#42225]).
* The `length` function on certain ranges of certain specific element types no longer checks for integer
  overflow in most cases. The new function `checked_length` is now available, which will try to use checked
  arithmetic to error if the result may be wrapping. Or use a package such as SaferIntegers.jl when
  constructing the range. ([#40382])
* TCP socket objects now expose `closewrite` functionality and support half-open mode usage ([#40783]).
* `extrema` now supports `init` keyword argument ([#36265], [#43604]).
* Intersect returns a result with the eltype of the type-promoted eltypes of the two inputs ([#41769]).
* `Iterators.countfrom` now accepts any type that defines `+`. ([#37747])
* The `LazyString` and the `lazy"str"` macro were added to support delayed construction of error messages in error paths. ([#33711])

#### InteractiveUtils
* A new macro `@time_imports` for reporting any time spent importing packages and their dependencies ([#41612])

#### Package Manager

#### LinearAlgebra

* The BLAS submodule now supports the level-2 BLAS subroutine `spr!` ([#42830]).
* `cholesky[!]` now supports `LinearAlgebra.PivotingStrategy` (singleton type) values
  as its optional `pivot` argument: the default is `cholesky(A, NoPivot())` (vs.
  `cholesky(A, RowMaximum())`); the former `Val{true/false}`-based calls are deprecated. ([#41640])
* The standard library `LinearAlgebra.jl` is now completely independent of `SparseArrays.jl`,
  both in terms of the source code as well as unit testing ([#43127]). As a consequence,
  sparse arrays are no longer (silently) returned by methods from `LinearAlgebra` applied
  to `Base` or `LinearAlgebra` objects. Specifically, this results in the following breaking
  changes:

  * Concatenations involving special "sparse" matrices (`*diagonal`) now return dense matrices;
    As a consequence, the `D1` and `D2` fields of `SVD` objects, constructed upon `getproperty`
    calls are now dense matrices.
  * 3-arg `similar(::SpecialSparseMatrix, ::Type, ::Dims)` returns a dense zero matrix.
    As a consequence, products of bi-, tri- and symmetric tridiagonal matrices with each
    other result in dense output. Moreover, constructing 3-arg similar matrices of special
    "sparse" matrices of (nonstatic) matrices now fails for the lack of `zero(::Type{Matrix{T}})`.

#### Markdown

#### Printf
* Now uses `textwidth` for formatting `%s` and `%c` widths ([#41085]).

#### Profile
* Profiling now records sample metadata including thread and task. `Profile.print()` has a new `groupby` kwarg that allows
  grouping by thread, task, or nested thread/task, task/thread, and `threads` and `tasks` kwargs to allow filtering.
  Further, percent utilization is now reported as a total or per-thread, based on whether the thread is idle or not at
  each sample. `Profile.fetch()` by default strips out the new metadata to ensure backwards compatibility with external
  profiling data consumers, but can be included with the `include_meta` kwarg. ([#41742])
* The new `Profile.Allocs` module allows memory allocations to be profiled. The stack trace, type, and size of each
  allocation is recorded, and a `sample_rate` argument allows a tunable amount of allocations to be skipped,
  reducing performance overhead. ([#42768])

#### Random

#### REPL
* `RadioMenu` now supports optional `keybindings` to directly select options ([#41576]).
* ` ?(x, y` followed by TAB displays all methods that can be called
  with arguments `x, y, ...`. (The space at the beginning prevents entering help-mode.)
  `MyModule.?(x, y` limits the search to `MyModule`. TAB requires that at least one
  argument have a type more specific than `Any`; use SHIFT-TAB instead of TAB
  to allow any compatible methods.

* New `err` global variable in `Main` set when an expression throws an exception, akin to `ans`. Typing `err` reprints
  the exception information.

#### SparseArrays

* The code for SparseArrays has been moved from the Julia repo to the external
  repo at https://github.com/JuliaSparse/SparseArrays.jl. This is only a code
  movement and does not impact any usage ([#43813]).

* New sparse concatenation functions `sparse_hcat`, `sparse_vcat`, and `sparse_hvcat` return
  `SparseMatrixCSC` output independent from the types of the input arguments. They make
  concatenation behavior available, in which the presence of some special "sparse" matrix
  argument resulted in sparse output by multiple dispatch. This is no longer possible after
  making `LinearAlgebra.jl` independent from `SparseArrays.jl` ([#43127]).

#### Dates

#### Downloads

#### Statistics

#### Sockets

#### Tar

#### Distributed

#### UUIDs

#### Mmap

#### DelimitedFiles

#### Logging
* The standard log levels `BelowMinLevel`, `Debug`, `Info`, `Warn`, `Error`,
  and `AboveMaxLevel` are now exported from the Logging stdlib ([#40980]).

#### Unicode
* Added function `isequal_normalized` to check for Unicode equivalence without
  explicitly constructing normalized strings ([#42493]).
* The `Unicode.normalize` function now accepts a `chartransform` keyword that can
  be used to supply custom character mappings, and a `Unicode.julia_chartransform`
  function is provided to reproduce the mapping used in identifier normalization
  by the Julia parser ([#42561]).


Deprecated or removed
---------------------


External dependencies
---------------------


Tooling Improvements
---------------------
* `GC.enable_logging(true)` can be used to log each garbage collection, with the
  time it took and the amount of memory that was collected ([#43511]).


<!--- generated by NEWS-update.jl: -->
