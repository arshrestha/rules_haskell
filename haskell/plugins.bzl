load(":private/providers.bzl", "GhcPluginInfo", "HaskellLibraryInfo")

def ghc_plugin_impl(ctx):
    args = [ctx.expand_make_variables("args", i, {}) for i in ctx.attr.args]
    return [
        GhcPluginInfo(
            module = ctx.attr.module,
            deps = ctx.attr.deps,
            args = args,
        ),
    ]

ghc_plugin = rule(
    ghc_plugin_impl,
    attrs = {
        "module": attr.string(
            doc = "Plugin entrypoint.",
        ),
        "deps": attr.label_list(
            doc = "Plugin dependencies. These are compile-time dependencies only.",
            providers = [HaskellLibraryInfo],
        ),
        "args": attr.string_list(
            doc = "Plugin options.",
        ),
        "tools": attr.label_list(
            doc = "Tools needed by the plugin when it used.",
        ),
    },
)
"""Declare a GHC plugin.

Example:
  ```bzl
  haskell_library(
      name = "plugin-lib",
      srcs = ["Plugin.hs"],
  )

  ghc_plugin(
      name = "plugin",
      module = "Plugin",
      deps = [":plugin-lib"],
  )

  haskell_binary(
      name = "some-binary",
      srcs = ["Main.hs"],
      plugins = [":plugin"],
  ```

Plugins to use during compilation by GHC are given by the `plugins`
attribute to Haskell rules. Plugins are haskell libraries with some
extra metadata, like the name of the module that acts as the
entrypoint for the plugin and plugin options.

"""
