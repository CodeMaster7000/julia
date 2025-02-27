// This file is a part of Julia. License is MIT: https://julialang.org/license

// This file defines an RPATH-style relative path loader for all platforms
#include "loader.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Bring in definitions of symbols exported from libjulia. */
#include "jl_exports.h"

/* Bring in helper functions for windows without libgcc. */
#ifdef _OS_WINDOWS_
#include "loader_win_utils.c"
#endif

// Save DEP_LIBS to a variable that is explicitly sized for expansion
static char dep_libs[1024] = DEP_LIBS;

JL_DLLEXPORT void jl_loader_print_stderr(const char * msg)
{
    fputs(msg, stderr);
}
// I use three arguments a lot.
void jl_loader_print_stderr3(const char * msg1, const char * msg2, const char * msg3)
{
    jl_loader_print_stderr(msg1);
    jl_loader_print_stderr(msg2);
    jl_loader_print_stderr(msg3);
}

/* Wrapper around dlopen(), with extra relative pathing thrown in*/
static void * load_library(const char * rel_path, const char * src_dir, int err) {
    void * handle = NULL;

    // See if a handle is already open to the basename
    const char *basename = rel_path + strlen(rel_path);
    while (basename-- > rel_path)
        if (*basename == PATHSEPSTRING[0] || *basename == '/')
            break;
    basename++;
#if defined(_OS_WINDOWS_)
    if ((handle = GetModuleHandleA(basename)))
        return handle;
#else
    // if err == 0 the library is optional, so don't allow global lookups to see it
    if ((handle = dlopen(basename, RTLD_NOLOAD | RTLD_NOW | (err ? RTLD_GLOBAL : RTLD_LOCAL))))
        return handle;
#endif

    char path[2*PATH_MAX + 1] = {0};
    strncat(path, src_dir, sizeof(path) - 1);
    strncat(path, PATHSEPSTRING, sizeof(path) - 1);
    strncat(path, rel_path, sizeof(path) - 1);

#if defined(_OS_WINDOWS_)
    wchar_t wpath[2*PATH_MAX + 1] = {0};
    if (!utf8_to_wchar(path, wpath, 2*PATH_MAX)) {
        jl_loader_print_stderr3("ERROR: Unable to convert path ", path, " to wide string!\n");
        exit(1);
    }
    handle = (void *)LoadLibraryExW(wpath, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
#else
    handle = dlopen(path, RTLD_NOW | (err ? RTLD_GLOBAL : RTLD_LOCAL));
#endif

    if (handle == NULL) {
        if (!err)
            return NULL;
        jl_loader_print_stderr3("ERROR: Unable to load dependent library ", path, "\n");
#if defined(_OS_WINDOWS_)
        LPWSTR wmsg = TEXT("");
        FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER |
                       FORMAT_MESSAGE_FROM_SYSTEM |
                       FORMAT_MESSAGE_IGNORE_INSERTS |
                       FORMAT_MESSAGE_MAX_WIDTH_MASK,
                       NULL, GetLastError(),
                       MAKELANGID(LANG_ENGLISH, SUBLANG_ENGLISH_US),
                       (LPWSTR)&wmsg, 0, NULL);
        char err[256] = {0};
        wchar_to_utf8(wmsg, err, 255);
        jl_loader_print_stderr3("Message:", err, "\n");
#else
        jl_loader_print_stderr3("Message:", dlerror(), "\n");
#endif
        exit(1);
    }
    return handle;
}

static void * lookup_symbol(const void * lib_handle, const char * symbol_name) {
#ifdef _OS_WINDOWS_
    return GetProcAddress((HMODULE) lib_handle, symbol_name);
#else
    return dlsym((void *)lib_handle, symbol_name);
#endif
}

// Find the location of libjulia.
char lib_dir[PATH_MAX];
JL_DLLEXPORT const char * jl_get_libdir()
{
    // Reuse the path if this is not the first call.
    if (lib_dir[0] != 0) {
        return lib_dir;
    }
#if defined(_OS_WINDOWS_)
    // On Windows, we use GetModuleFileNameW
    wchar_t libjulia_path[PATH_MAX];
    HMODULE libjulia = NULL;

    // Get a handle to libjulia.
    if (!utf8_to_wchar(LIBJULIA_NAME, libjulia_path, PATH_MAX)) {
        jl_loader_print_stderr3("ERROR: Unable to convert path ", LIBJULIA_NAME, " to wide string!\n");
        exit(1);
    }
    libjulia = LoadLibraryW(libjulia_path);
    if (libjulia == NULL) {
        jl_loader_print_stderr3("ERROR: Unable to load ", LIBJULIA_NAME, "!\n");
        exit(1);
    }
    if (!GetModuleFileNameW(libjulia, libjulia_path, PATH_MAX)) {
        jl_loader_print_stderr("ERROR: GetModuleFileName() failed\n");
        exit(1);
    }
    if (!wchar_to_utf8(libjulia_path, lib_dir, PATH_MAX)) {
        jl_loader_print_stderr("ERROR: Unable to convert julia path to UTF-8\n");
        exit(1);
    }
#else
    // On all other platforms, use dladdr()
    Dl_info info;
    if (!dladdr(&jl_get_libdir, &info)) {
        jl_loader_print_stderr("ERROR: Unable to dladdr(&jl_get_libdir)!\n");
        jl_loader_print_stderr3("Message:", dlerror(), "\n");
        exit(1);
    }
    strcpy(lib_dir, info.dli_fname);
#endif
    // Finally, convert to dirname
    const char * new_dir = dirname(lib_dir);
    if (new_dir != lib_dir) {
        // On some platforms, dirname() mutates.  On others, it does not.
        memcpy(lib_dir, new_dir, strlen(new_dir)+1);
    }
    return lib_dir;
}

void * libjulia_internal = NULL;
__attribute__((constructor)) void jl_load_libjulia_internal(void) {
    // Only initialize this once
    if (libjulia_internal != NULL) {
        return;
    }

    // Introspect to find our own path
    const char * lib_dir = jl_get_libdir();

    // Pre-load libraries that libjulia-internal needs.
    int deps_len = strlen(dep_libs);
    char * curr_dep = &dep_libs[0];

    // We keep track of "special" libraries names (ones whose name is prefixed with `@`)
    // which are libraries that we want to load in some special, custom way, such as
    // `libjulia-internal` or `libjulia-codegen`.
    int special_idx = 0;
    char * special_library_names[2] = {NULL};
    while (1) {
        // try to find next colon character; if we can't, break out
        char * colon = strchr(curr_dep, ':');
        if (colon == NULL)
            break;

        // Chop the string at the colon so it's a valid-ending-string
        *colon = '\0';

        // If this library name starts with `@`, don't open it here (but mark it as special)
        if (curr_dep[0] == '@') {
            if (special_idx > sizeof(special_library_names)/sizeof(char *)) {
                jl_loader_print_stderr("ERROR: Too many special library names specified, check LOADER_BUILD_DEP_LIBS and friends!\n");
                exit(1);
            }
            special_library_names[special_idx] = curr_dep + 1;
            special_idx += 1;
        } else {
            load_library(curr_dep, lib_dir, 1);
        }

        // Skip ahead to next dependency
        curr_dep = colon + 1;
    }

    if (special_idx != sizeof(special_library_names)/sizeof(char *)) {
        jl_loader_print_stderr("ERROR: Too few special library names specified, check LOADER_BUILD_DEP_LIBS and friends!\n");
        exit(1);
    }

    // Unpack our special library names.  This is why ordering of library names matters.
    libjulia_internal = load_library(special_library_names[0], lib_dir, 1);
    void *libjulia_codegen = load_library(special_library_names[1], lib_dir, 0);
    const char * const * codegen_func_names;
    const char *codegen_liberr;
    if (libjulia_codegen == NULL) {
        // if codegen is not available, use fallback implementation in libjulia-internal
        libjulia_codegen = libjulia_internal;
        codegen_func_names = jl_codegen_fallback_func_names;
        codegen_liberr = " from libjulia-internal\n";
    }
    else {
        codegen_func_names = jl_codegen_exported_func_names;
        codegen_liberr = " from libjulia-codegen\n";
    }

    // Once we have libjulia-internal loaded, re-export its symbols:
    for (unsigned int symbol_idx=0; jl_runtime_exported_func_names[symbol_idx] != NULL; ++symbol_idx) {
        void *addr = lookup_symbol(libjulia_internal, jl_runtime_exported_func_names[symbol_idx]);
        if (addr == NULL) {
            jl_loader_print_stderr3("ERROR: Unable to load ", jl_runtime_exported_func_names[symbol_idx], " from libjulia-internal\n");
            exit(1);
        }
        (*jl_runtime_exported_func_addrs[symbol_idx]) = addr;
    }
    // jl_options must be initialized very early, in case an embedder sets some
    // values there before calling jl_init
    ((void (*)(void))jl_init_options_addr)();

    for (unsigned int symbol_idx=0; codegen_func_names[symbol_idx] != NULL; ++symbol_idx) {
        void *addr = lookup_symbol(libjulia_codegen, codegen_func_names[symbol_idx]);
        if (addr == NULL) {
            jl_loader_print_stderr3("ERROR: Unable to load ", codegen_func_names[symbol_idx], codegen_liberr);
            exit(1);
        }
        (*jl_codegen_exported_func_addrs[symbol_idx]) = addr;
    }
    // Next, if we're on Linux/FreeBSD, set up fast TLS.
#if !defined(_OS_WINDOWS_) && !defined(_OS_DARWIN_)
    void (*jl_pgcstack_setkey)(void*, void*(*)(void)) = lookup_symbol(libjulia_internal, "jl_pgcstack_setkey");
    if (jl_pgcstack_setkey == NULL) {
        jl_loader_print_stderr("ERROR: Cannot find jl_pgcstack_setkey() function within libjulia-internal!\n");
        exit(1);
    }
    void *fptr = lookup_symbol(RTLD_DEFAULT, "jl_get_pgcstack_static");
    void *(*key)(void) = lookup_symbol(RTLD_DEFAULT, "jl_pgcstack_addr_static");
    if (fptr != NULL && key != NULL)
        jl_pgcstack_setkey(fptr, key);
#endif

    // jl_options must be initialized very early, in case an embedder sets some
    // values there before calling jl_init
    ((void (*)(void))jl_init_options_addr)();
}

// Load libjulia and run the REPL with the given arguments (in UTF-8 format)
JL_DLLEXPORT int jl_load_repl(int argc, char * argv[]) {
    // Some compilers/platforms are known to have `__attribute__((constructor))` issues,
    // so we have a fallback call of `jl_load_libjulia_internal()` here.
    if (libjulia_internal == NULL) {
        jl_load_libjulia_internal();
        if (libjulia_internal == NULL) {
            jl_loader_print_stderr("ERROR: libjulia-internal could not be loaded!\n");
            exit(1);
        }
    }
    // Load the repl entrypoint symbol and jump into it!
    int (*entrypoint)(int, char **) = (int (*)(int, char **))lookup_symbol(libjulia_internal, "jl_repl_entrypoint");
    if (entrypoint == NULL) {
        jl_loader_print_stderr("ERROR: Unable to find `jl_repl_entrypoint()` within libjulia-internal!\n");
        exit(1);
    }
    return entrypoint(argc, (char **)argv);
}

#ifdef _OS_WINDOWS_
int __stdcall DllMainCRTStartup(void* instance, unsigned reason, void* reserved) {
    setup_stdio();

    // Because we override DllMainCRTStartup, we have to manually call our constructor methods
    jl_load_libjulia_internal();
    return 1;
}
#endif

#ifdef __cplusplus
} // extern "C"
#endif
