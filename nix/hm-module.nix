# Home Manager module: programs.tmux.agentIndicator.
# Exposed by the flake as homeModules.default; `version` comes from the flake.
{ version }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatStringsSep
    literalExpression
    mapAttrsToList
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    types
    ;

  cfg = config.programs.tmux.agentIndicator;
  pluginDir = "${cfg.package}/share/tmux-plugins/agent-indicator";

  tmuxValue =
    value:
    if lib.isBool value then
      (if value then "on" else "off")
    else
      "'${lib.replaceStrings [ "'" ] [ "'\\''" ] (toString value)}'";

  settingsConfig = concatStringsSep "\n" (
    mapAttrsToList (name: value: "set -g @agent-indicator-${name} ${tmuxValue value}") cfg.settings
  );

  # The hook templates resolve the plugin through $TMUX_AGENT_INDICATOR_DIR with
  # a TPM-path fallback; pin them to this package instead, so hooks also work
  # outside tmux and never call scripts from an older generation.
  hookTemplate =
    agent:
    pkgs.runCommand "tmux-agent-indicator-${agent}-hooks.json" { } ''
      substitute ${pluginDir}/hooks/${agent}-hooks.json "$out" \
        --replace-fail ${lib.escapeShellArg "\${TMUX_AGENT_INDICATOR_DIR:-$HOME/.tmux/plugins/tmux-agent-indicator}"} ${pluginDir}
    '';

  # jq definitions shared by the merge and strip-only passes. `ours` matches
  # this plugin's hook commands for the agent; with $store_only set it matches
  # only those pointing into the Nix store, so a TPM/install.sh setup that
  # shares the settings file is left alone.
  hookDefs = agent: ''
    def ours: type == "object" and ((.command // "") | type == "string" and test("scripts/agent-state\\.sh .*--agent ${agent} --state") and (($store_only | not) or contains($store)));
    def strip:
      map(if type == "object" and (.hooks | type) == "array" then .hooks |= map(select(ours | not)) else . end)
      | map(select(type != "object" or (.hooks | type) != "array" or (.hooks | length) > 0));
    def stripped: if (.hooks | type) == "object" then .hooks |= (map_values(if type == "array" then strip else . end) | with_entries(select(.value != []))) else . end;
  '';

  jqArgs = storeOnly: "--arg store ${lib.escapeShellArg "${builtins.storeDir}/"} --argjson store_only ${lib.boolToString storeOnly}";

  # Claude Code and Codex rewrite their settings files themselves, so the hooks
  # are merged in on activation instead of linking a read-only store file. Hooks
  # from earlier generations (any agent-state.sh path) are dropped first.
  mergeHooks = agent: settings: ''
    settings=${settings}
    if [ -L "$settings" ]; then
      warnEcho "tmux-agent-indicator: $settings is a symlink; not merging ${agent} hooks"
    else
      run mkdir -p "$(dirname "$settings")"
      tmp=$(mktemp)
      if { [ -s "$settings" ] && cat "$settings" || echo '{}'; } | ${lib.getExe pkgs.jq} ${jqArgs false} --slurpfile tpl ${hookTemplate agent} '
        ${hookDefs agent}
        stripped
        | reduce ($tpl[0].hooks | to_entries[]) as $e (.; .hooks[$e.key] += $e.value)
      ' > "$tmp"; then
        run cp "$tmp" "$settings"
      fi
      rm -f "$tmp"
    fi
  '';

  # Integration (or module) disabled: drop hooks left behind by earlier
  # generations, which point at store paths that GC will eventually delete.
  # Never creates the file, skips symlinks, and only rewrites on a real change.
  stripHooks = agent: settings: ''
    settings=${settings}
    if [ ! -L "$settings" ] && [ -s "$settings" ] && ${lib.getExe pkgs.gnugrep} -qF ${lib.escapeShellArg "${builtins.storeDir}/"} "$settings"; then
      tmp=$(mktemp)
      if ${lib.getExe pkgs.jq} ${jqArgs true} '
        ${hookDefs agent}
        stripped as $new | if $new == . then empty else $new end
      ' "$settings" > "$tmp" && [ -s "$tmp" ]; then
        run cp "$tmp" "$settings"
      fi
      rm -f "$tmp"
    fi
  '';

  syncHooks = enable: if enable then mergeHooks else stripHooks;
in
{
  options.programs.tmux.agentIndicator = {
    enable = mkEnableOption "tmux-agent-indicator, AI agent state in tmux pane borders, window titles and the status bar";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ./package.nix { inherit version; };
      defaultText = literalExpression "tmux-agent-indicator from its flake, built with pkgs";
      description = "The tmux-agent-indicator plugin package.";
    };

    dir = mkOption {
      type = types.str;
      readOnly = true;
      default = pluginDir;
      defaultText = literalExpression ''"''${cfg.package}/share/tmux-plugins/agent-indicator"'';
      description = ''
        Plugin directory in the store, for calling its scripts from other
        configuration (for example `''${config.programs.tmux.agentIndicator.dir}/scripts/session-attention.sh`).
      '';
    };

    settings = mkOption {
      type =
        with types;
        attrsOf (oneOf [
          bool
          int
          str
        ]);
      default = { };
      example = literalExpression ''
        {
          processes = "claude,codex,aider,cursor,opencode,omp";
          icons = "claude=🤖,codex=🧠,default=🤖";
          notification-enabled = false;
          done-window-title-bg = "red";
        }
      '';
      description = ''
        `@agent-indicator-*` tmux options, without the prefix. Booleans become
        `on`/`off`; an empty string skips that property, as in tmux.conf.
      '';
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      example = ''
        set -g status-right "#{agent_indicator} %H:%M"
      '';
      description = ''
        tmux configuration emitted just before the plugin loads. The plugin
        expands `#{agent_indicator}`, `#{agent_limits}` and
        `#{agent_session_dots}` in `status-left`/`status-right` only when it
        loads, and {option}`programs.tmux.extraConfig` comes after plugins, so
        status lines using them belong here.
      '';
    };

    integrations = {
      claude.enable = mkEnableOption "Claude Code hooks, merged into ~/.claude/settings.json";
      codex.enable = mkEnableOption "Codex hooks, merged into ~/.codex/hooks.json (trust them with /hooks in Codex)";
      opencode.enable = mkEnableOption "the OpenCode plugin in ~/.config/opencode/plugins";
      omp.enable = mkEnableOption "the omp extension in ~/.omp/agent/extensions";
    };
  };

  config = mkMerge [
    # Declared even while the module or an integration is disabled: the next
    # switch then strips the store-path hooks the previous generation merged,
    # which would otherwise dangle after garbage collection. A no-op unless the
    # settings file holds such hooks.
    {
      home.activation.tmuxAgentIndicatorClaude = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        syncHooks (cfg.enable && cfg.integrations.claude.enable) "claude" ''"$HOME/.claude/settings.json"''
      );
      home.activation.tmuxAgentIndicatorCodex = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        syncHooks (cfg.enable && cfg.integrations.codex.enable) "codex" ''"$HOME/.codex/hooks.json"''
      );
    }

    (mkIf cfg.enable (mkMerge [
      {
        programs.tmux.plugins = [
          {
            plugin = cfg.package;
            extraConfig = concatStringsSep "\n" (
              lib.filter (s: s != "") [
                settingsConfig
                cfg.extraConfig
              ]
            );
          }
        ];
      }

      (mkIf cfg.integrations.opencode.enable {
        # A symlink, so the plugin resolves its scripts from the store package.
        xdg.configFile."opencode/plugins/opencode-tmux-agent-indicator.js".source =
          "${pluginDir}/plugins/opencode-tmux-agent-indicator.js";
      })

      # omp resolves the scripts through the symlink's target, so a link suffices.
      (mkIf cfg.integrations.omp.enable {
        home.file.".omp/agent/extensions/tmux-agent-indicator.ts".source =
          "${pluginDir}/plugins/omp-tmux-agent-indicator.ts";
      })
    ]))
  ];
}
