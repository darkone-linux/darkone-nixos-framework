# Overlay: unbreaks `python3Packages.posthog`, a dependency of `aider-chat`.
#
# :::caution[Why]
# nixpkgs marks `posthog` broken since `mcp` 2 (`broken = versionAtLeast
# mcp.version "2"`): every reverse dependency refuses to evaluate. `mcp` is a
# check input only; a single test hits the mcp 2 field rename.
# :::
#
# :::note[No binary cache]
# Hydra skips a broken package: every builder runs the whole suite, under
# fleet build load. Tests asserting on a wall-clock window are disabled.
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

          # Timing-dependent: the assertion rides on a sub-3 s wall-clock window,
          # missed on a loaded builder (two of them failed a fleet build).
          "test_atexit_subprocess_does_not_drain_queued_backlog"
          "test_user_defined_flush_at"
          "test_empty_flush_does_not_drain_a_later_event"
          "test_join_discards_remaining_work_if_consumer_stops_during_drain"
          "test_the_real_wait_returns_when_close_is_called"
        ];
        meta = old.meta // {
          broken = false;
        };
      });
    })
  ];
}
