# Copyright 2018 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Skylark build rules for cabal haskell packages.

To see all of the generated rules, run:
bazel query --output=build @haskell_{package}_{hash}//:all
where {package} is the lower-cased package name with - replaced by _
and {hash} is the Bazel hash of the original package name.
"""

load("@bazel_skylib//:lib.bzl", "paths")
load("@bazel_skylib//:lib.bzl", sets = "new_sets")
load(
    "@io_tweag_rules_haskell//haskell:haskell.bzl",
    "haskell_binary",
    "haskell_cc_import",
    "haskell_library",
)
load(
    "@io_tweag_rules_haskell//haskell:c2hs.bzl",
    "c2hs_library",
)
load(":bzl/alex.bzl", "genalex")
load(":bzl/cabal_paths.bzl", "cabal_paths")
load(":bzl/happy.bzl", "genhappy")
load("//templates:templates.bzl", "templates")
load("//tools:mangling.bzl", "hazel_cbits", "hazel_library")

_conditions_default = "//conditions:default"

# Those libraries are already provided by the system, Bazel or rules_haskell,
# and must thus be ignored when specified as extra libraries.
_excluded_cxx_libs = sets.make(elements = [
    "pthread",
    "stdc++",
    # Windows libraries
    "advapi32",
    "iphlpapi",
    "Crypt32",
])

def _get_core_dependency_includes(ghc_workspace):
    """Include files that are exported by core dependencies
    (That is, their "install-includes".)
    TODO: detect this more automatically.
    """
    return {
        "unix": "{}//:unix-includes".format(ghc_workspace),
    }

def _paths_module(desc):
    return "Paths_" + desc.package.pkgName.replace("-", "_")

def _hazel_symlink_impl(ctx):
    ctx.actions.run(
        outputs = [ctx.outputs.out],
        inputs = [ctx.file.src],
        executable = "ln",
        arguments = [
            "-s",
            "/".join([".."] * len(ctx.outputs.out.dirname.split("/"))) +
            "/" + ctx.file.src.path,
            ctx.outputs.out.path,
        ],
    )

hazel_symlink = rule(
    implementation = _hazel_symlink_impl,
    attrs = {
        "src": attr.label(mandatory = True, allow_files = True, single_file = True),
        "out": attr.string(mandatory = True),
    },
    outputs = {"out": "%{out}"},
)

def _conditions_dict(d):
    return d.select if hasattr(d, "select") else {_conditions_default: d}

def _fix_source_dirs(dirs):
    if dirs:
        return dirs
    return [""]

def _module_output(file, ending):
    """Replace the input's ending by the ending for the generated output file.

    Args:
      file: Input file name.
      ending: Input file ending.

    Returns:
      The output file with appropriate ending. E.g. `file.y --> file.hs`.
    """
    out_extension = {
        "hs": "hs",
        "lhs": "lhs",
        "hsc": "hsc",
        "chs": "hs",
        "x": "hs",
        "y": "hs",
        "ly": "hs",
    }[ending]
    return file[:-len(ending)] + out_extension

def _find_module_by_ending(modulePath, ending, sourceDirs):
    """Try to find a source file for the given modulePath with the given ending.

    Checks for module source files in all given source directories.

    Args:
      modulePath: The module path converted to a relative file path. E.g.
        `Some/Module/Name`
      ending: Look for module source files with this file ending.
      sourceDirs: Look for module source files in these directories.

    Returns:
      Either `None` if no source file was found, or a `struct` describing the
      module source file. See `_find_module` for details.
    """

    # Find module source file in source directories.
    files = native.glob([
        paths.join(d if d != "." else "", modulePath + "." + ending)
        for d in sourceDirs
    ])
    if len(files) == 0:
        return None
    file = files[0]

    # Look for hs/lhs boot file.
    bootFile = None
    if ending in ["hs", "lhs"]:
        bootFiles = native.glob([file + "-boot"])
        if len(bootFiles) != 0:
            bootFile = bootFiles[0]
    return struct(
        type = ending,
        src = file,
        out = _module_output(file, ending),
        boot = bootFile,
    )

def _find_module(module, sourceDirs):
    """Find the source file for the given module.

    Args:
      module: The Haskell module name. E.g. `Some.Module.Name`.
      sourceDirs: List of source directories under which to search for sources.

    Returns:
      Either `None` if no module source file was found,
      or a `struct` with the following fields:

      `type`: The ending.
      `src`: The source file that was found.
        E.g. `Some/Module/Name.y`
      `out`: The expected generated output module file.
        E.g. `Some/Module/Name.hs`.
      `bootFile`: Haskell boot file path or `None` if no boot file was found.
    """
    modulePath = module.replace(".", "/")
    mod = None

    # Looking for raw source files first. To override duplicates (e.g. if a
    # package contains both a Happy Foo.y file and the corresponding generated
    # Foo.hs).
    for ending in ["hs", "lhs", "hsc", "chs", "x", "y", "ly"]:
        mod = _find_module_by_ending(modulePath, ending, sourceDirs)
        if mod != None:
            break
    return mod

def _get_build_attrs(
        name,
        build_info,
        desc,
        generated_srcs_dir,
        extra_modules,
        ghc_version,
        ghc_workspace,
        extra_libs,
        cc_deps = [],
        version_overrides = None,
        ghcopts = []):
    """Get the attributes for a particular library or binary rule.

    Args:
      name: The name of this component.
      build_info: A struct of the Cabal BuildInfo for this component.
      desc: A struct of the Cabal PackageDescription for this package.
      generated_srcs_dir: Location of autogenerated files for this rule,
        e.g., "dist/build" for libraries.
      extra_modules: exposed-modules: or other-modules: in the package description
      ghc_workspace: Workspace in which GHC is provided.
      extra_libs: A dictionary that maps from name of extra libraries to Bazel
        targets that provide the shared library and headers as a cc_library.
      cc_deps: External cc_libraries that this rule should depend on.
      version_overrides: Override the default version of specific dependencies;
        see cabal_haskell_package for more details.
      ghcopts: Extra GHC options.
    Returns:
      A dictionary of attributes (e.g. "srcs", "deps") that can be passed
      into a haskell_library or haskell_binary rule.
    """

    # Preprocess and collect all the source files by their extension.
    # module_map will contain a dictionary from module names ("Foo.Bar")
    # to the preprocessed source file ("src/Foo/Bar.hs").
    module_map = {}

    # boot_module_map will contain a dictionary from module names ("Foo.Bar")
    # to hs-boot files, if applicable.
    boot_module_map = {}

    # build_files will contain a list of all files in the build directory.
    build_files = []

    clib_name = name + "-cbits"
    generated_modules = [_paths_module(desc)]

    # Keep track of chs modules, as later chs modules may depend on earlier ones.
    chs_targets = []

    for module in build_info.otherModules + extra_modules:
        if module in generated_modules:
            continue

        # Look for module files in source directories.
        info = _find_module(
            module,
            _fix_source_dirs(build_info.hsSourceDirs) + [generated_srcs_dir],
        )
        if info == None:
            fail("Missing module %s for %s" % (module, name) + str(module_map))

        # Create module files in build directory.
        if info.type in ["hs", "lhs", "hsc"]:
            module_out = info.out
            module_map[module] = module_out
            build_files.append(module_out)
            if info.boot != None:
                boot_out = info.out + "-boot"
                boot_module_map[module] = boot_out
                build_files.append(boot_out)
        elif info.type in ["chs"]:
            chs_name = name + "-" + module + "-chs"
            module_map[module] = chs_name
            build_files.append(info.src)
            msg_no_such_lib = "Cannot find library: %s. If it is a system library, please open a ticket on https://github.com/tweag/rules_haskell requesting to add it to _excluded_cxx_libs."
            c2hs_library(
                name = chs_name,
                srcs = [info.src],
                deps = [
                    extra_libs[elib] if extra_libs.get(elib) else fail(msg_no_such_lib % elib)
                    for elib in build_info.extraLibs
                    if not sets.contains(_excluded_cxx_libs, elib)
                ] + [clib_name] + chs_targets,
            )
            chs_targets.append(chs_name)
        elif info.type in ["x"]:
            module_out = info.out
            module_map[module] = module_out
            build_files.append(module_out)
            genalex(
                src = info.src,
                out = module_out,
            )
        elif info.type in ["y", "ly"]:
            module_out = info.out
            module_map[module] = module_out
            build_files.append(module_out)
            genhappy(
                src = info.src,
                out = module_out,
            )

    # Create extra source files in build directory.
    extra_srcs = []
    for f in native.glob([paths.normalize(f) for f in desc.extraSrcFiles]):
        fout = f

        # Skip files that were created in the previous steps.
        if fout in build_files:
            continue
        extra_srcs.append(fout)

    # Collect the source files for each module in this Cabal component.
    # srcs is a mapping from "select()" conditions (e.g. //third_party/haskell/ghc:ghc-8.0.2) to a list of source files.
    # Turn others to dicts if there is a use case.
    srcs = {}

    # Keep track of .hs-boot files specially.  GHC doesn't want us to pass
    # them as command-line arguments; instead, it looks for them next to the
    # corresponding .hs files.
    deps = {}
    cdeps = {}
    paths_module = _paths_module(desc)
    extra_modules_dict = _conditions_dict(extra_modules)
    other_modules_dict = _conditions_dict(build_info.otherModules)
    for condition in depset(extra_modules_dict.keys() + other_modules_dict.keys()):
        srcs[condition] = []
        deps[condition] = []
        cdeps[condition] = []
        for m in (extra_modules_dict.get(condition, []) +
                  other_modules_dict.get(condition, [])):
            if m == paths_module:
                deps[condition] += [":" + paths_module]
            elif m in module_map:
                srcs[condition] += [module_map[m]]

                # Get ".hs-boot" and ".lhs-boot" files.
                if m in boot_module_map:
                    srcs[condition] += [boot_module_map[m]]
            else:
                fail("Missing module %s for %s" % (m, name) + str(module_map))

    # Collect the options to pass to ghc.
    extra_ghcopts = ghcopts
    ghcopts = []
    all_extensions = [ext for ext in ([build_info.defaultLanguage] if build_info.defaultLanguage else ["Haskell98"]) +
                                     build_info.defaultExtensions +
                                     build_info.oldExtensions]
    ghcopts = ghcopts + ["-X" + ext for ext in all_extensions]

    ghcopt_blacklist = ["-Wall", "-Wwarn", "-w", "-Werror", "-O2", "-O", "-O0"]
    for (compiler, opts) in build_info.options:
        if compiler == "ghc":
            ghcopts += [o for o in opts if o not in ghcopt_blacklist]
    ghcopts += ["-w", "-Wwarn"]  # -w doesn't kill all warnings...

    # Collect the dependencies.
    #
    # If package A depends on packages B and C, then the cbits target A-cbits
    # will depend on B-cbits and C-cbits, and the Haskell target A will depend on
    # A-cbits and the Haskell targets B and C. This allows A-cbits to depend on
    # header files in B-cbits and C-cbits, as is the case with Cabal.
    _CORE_DEPENDENCY_INCLUDES = _get_core_dependency_includes(ghc_workspace)
    for condition, ps in _conditions_dict(depset(
        [p.name for p in build_info.targetBuildDepends],
    ).to_list()).items():
        if condition not in deps:
            deps[condition] = []
        if condition not in cdeps:
            cdeps[condition] = []
        for p in ps:
            # Collect direct Haskell dependencies.
            deps[condition] += [hazel_library(p)]

            # Collect direct cbits dependencies.
            cdeps[condition] += [hazel_cbits(p)]
            if p in _CORE_DEPENDENCY_INCLUDES:
                cdeps[condition] += [_CORE_DEPENDENCY_INCLUDES[p]]
                deps[condition] += [_CORE_DEPENDENCY_INCLUDES[p]]

    ghcopts += ["-optP" + o for o in build_info.cppOptions]

    # Generate a cc_library for this package.
    # TODO(judahjacobson): don't create the rule if it's not needed.
    # TODO(judahjacobson): Figure out the corner case logic for some packages.
    # In particular: JuicyPixels, cmark, ieee754.
    install_includes = native.glob(
        [
            paths.join(d if d != "." else "", f)
            for d in build_info.includeDirs
            for f in build_info.installIncludes
        ],
    )
    globbed_headers = native.glob([
        paths.normalize(f)
        for f in desc.extraSrcFiles + desc.extraTmpFiles
    ])

    # Some packages, such as network, include the config.log and config.status
    # files, generated by the ./configure script, in their extraTmpFiles. These
    # files contain information specific to the build host, which defeates
    # distributed caching. Here we black-list any such files and exclude them
    # from the headers attribute to cc_library.
    header_blacklist = [
        "config.log",
        "config.status",
    ]
    headers = depset(
        [
            hdr
            for hdr in globbed_headers
            if hdr.split("/")[-1] not in header_blacklist
        ] +
        install_includes,
    )
    ghcopts += ["-I" + native.package_name() + "/" + d for d in build_info.includeDirs]
    for xs in deps.values():
        xs.append(":" + clib_name)

    ghc_version_components = ghc_version.split(".")
    if len(ghc_version_components) != 3:
        fail("Not enough version components for GHC:" + str(ghc_version_components))

    ghc_version_string = (
        ghc_version_components[0] +
        ("0" if int(ghc_version_components[1]) <= 9 else "") +
        ghc_version_components[1]
    )

    elibs_targets = [
        extra_libs[elib]
        for elib in build_info.extraLibs
        if not sets.contains(_excluded_cxx_libs, elib)
    ]

    native.cc_library(
        name = clib_name,
        srcs = build_info.cSources,
        includes = build_info.includeDirs,
        copts = ([o for o in build_info.ccOptions if not o.startswith("-D")] +
                 [
                     "-D__GLASGOW_HASKELL__=" + ghc_version_string,
                     "-w",
                 ]),
        defines = [o[2:] for o in build_info.ccOptions if o.startswith("-D")],
        textual_hdrs = list(headers),
        deps = ["{}//:rts-headers".format(ghc_workspace)] + select(cdeps) + cc_deps + elibs_targets,
        visibility = ["//visibility:public"],
        linkstatic = select({
            "@bazel_tools//src/conditions:windows": True,
            "//conditions:default": False,
        }),
    )

    return {
        "srcs": srcs,
        "extra_srcs": extra_srcs,
        "deps": deps,
        "compiler_flags": ghcopts + extra_ghcopts,
    }

def _collect_data_files(description):
    name = description.package.pkgName
    if name in templates:
        files = []
        for f in templates[name]:
            out = paths.join(description.dataDir, f)
            hazel_symlink(
                name = name + "-template-" + f,
                src = "@ai_formation_hazel//templates/" + name + ":" + f,
                out = out,
            )
            files += [out]
        return files
    else:
        return native.glob([paths.join(description.dataDir, d) for d in description.dataFiles])

def cabal_haskell_package(
        description,
        ghc_version,
        ghc_workspace,
        extra_libs):
    """Create rules for building a Cabal package.

    Args:
      description: A Skylark struct generated by cabal2build representing a
        .cabal file's contents.
      ghc_workspace: Workspace under which GHC is provided.
      extra_libs: A dictionary that maps from name of extra libraries to Bazel
        targets that provide the shared library and headers as a cc_library.
    """
    name = description.package.pkgName

    cabal_paths(
        name = _paths_module(description),
        package = name.replace("-", "_"),
        version = [int(v) for v in description.package.pkgVersion.split(".")],
        data_dir = description.dataDir,
        data = _collect_data_files(description),
    )

    lib = description.library
    if lib and lib.libBuildInfo.buildable:
        if not lib.exposedModules:
            native.cc_library(
                name = name,
                visibility = ["//visibility:public"],
                linkstatic = select({
                    "@bazel_tools//src/conditions:windows": True,
                    "//conditions:default": False,
                }),
            )
            native.cc_library(
                name = name + "-cbits",
                visibility = ["//visibility:public"],
                linkstatic = select({
                    "@bazel_tools//src/conditions:windows": True,
                    "//conditions:default": False,
                }),
            )
        else:
            lib_attrs = _get_build_attrs(
                name,
                lib.libBuildInfo,
                description,
                "dist/build",
                lib.exposedModules,
                ghc_version,
                ghc_workspace,
                extra_libs,
            )
            srcs = lib_attrs.pop("srcs")
            deps = lib_attrs.pop("deps")

            elibs_targets = [
                extra_libs[elib]
                for elib in lib.libBuildInfo.extraLibs
                if not sets.contains(_excluded_cxx_libs, elib)
            ]

            hidden_modules = [m for m in lib.libBuildInfo.otherModules if not m.startswith("Paths_")]

            haskell_library(
                name = name,
                srcs = select(srcs),
                hidden_modules = hidden_modules,
                version = description.package.pkgVersion,
                deps = select(deps) + elibs_targets,
                visibility = ["//visibility:public"],
                **lib_attrs
            )

    for exe in description.executables:
        if not exe.buildInfo.buildable:
            continue
        exe_name = exe.exeName

        # Avoid a name clash with the library.  For stability, make this logic
        # independent of whether the package actually contains a library.
        if exe_name == name:
            exe_name = name + "_bin"
        paths_mod = _paths_module(description)
        attrs = _get_build_attrs(
            exe_name,
            exe.buildInfo,
            description,
            "dist/build/%s/%s-tmp" % (name, name),
            # Some packages (e.g. happy) don't specify the Paths_ module
            # explicitly.
            [paths_mod] if paths_mod not in exe.buildInfo.otherModules else [],
            ghc_version,
            ghc_workspace,
            extra_libs,
        )
        srcs = attrs.pop("srcs")
        deps = attrs.pop("deps")

        [full_module_path] = native.glob(
            [paths.normalize(paths.join(d, exe.modulePath)) for d in _fix_source_dirs(exe.buildInfo.hsSourceDirs)],
        )
        full_module_out = full_module_path
        for xs in srcs.values():
            if full_module_out not in xs:
                xs.append(full_module_out)

        haskell_binary(
            name = exe_name,
            srcs = select(srcs),
            deps = select(deps),
            visibility = ["//visibility:public"],
            **attrs
        )
