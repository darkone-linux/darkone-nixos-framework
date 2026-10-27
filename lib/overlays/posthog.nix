# Overlay: unbreaks `python3Packages.posthog`, a dependency of `aider-chat`.
#
# :::caution[Why]
# nixpkgs marks `posthog` broken since `mcp` 2 (`broken = versionAtLeast
# mcp.version "2"`): every reverse dependency refuses to evaluate. `mcp` is a
# check input only; a single test hits the mcp 2 field rename.
# :::
#
# :::tip[Cleanup]
# Drop once nixpkgs#578265 (unbreak, 7.71.0 -> 7.75.11) reaches
# `nixos-unstable`.
# :::

_final: prev: {

  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (_pyfinal: pyprev: {
      posthog = pyprev.posthog.overridePythonAttrs (old: {

        # `CallToolResult.structuredContent` is `structured_content` in mcp 2.
        disabledTests = old.disabledTests ++ [
          "test_prepare_tool_result_delivers_into_call_tool_result_models"
        ];
        meta = old.meta // {
          broken = false;
        };
      });
    })
  ];
}
