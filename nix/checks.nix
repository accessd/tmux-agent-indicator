# flake check for the Home Manager module: evaluates it against stub Home
# Manager options, then runs the generated activation scripts on fixture
# settings files. Covers the merge pass and the strip-only pass that runs when
# an integration, or the whole module, is disabled.
{ pkgs, hmModule }:
let
  inherit (pkgs) lib;

  hmLib = lib.extend (
    _: _: {
      hm.dag.entryAfter = after: data: { inherit after data; };
    }
  );

  stubOptions =
    { lib, ... }:
    {
      options = {
        programs.tmux.plugins = lib.mkOption {
          type = lib.types.listOf lib.types.raw;
          default = [ ];
        };
        home.activation = lib.mkOption {
          type = lib.types.attrsOf lib.types.raw;
          default = { };
        };
        home.file = lib.mkOption {
          type = lib.types.attrsOf lib.types.raw;
          default = { };
        };
        xdg.configFile = lib.mkOption {
          type = lib.types.attrsOf lib.types.raw;
          default = { };
        };
      };
    };

  evalConfig =
    agentIndicator:
    (lib.evalModules {
      specialArgs = {
        inherit pkgs;
        lib = hmLib;
      };
      modules = [
        hmModule
        stubOptions
        { programs.tmux.agentIndicator = agentIndicator; }
      ];
    }).config;

  allEnabled = evalConfig {
    enable = true;
    integrations = {
      claude.enable = true;
      codex.enable = true;
      opencode.enable = true;
      omp.enable = true;
    };
  };
  claudeDisabled = evalConfig {
    enable = true;
    integrations.codex.enable = true;
  };
  moduleDisabled = evalConfig { };

  script = config: name: pkgs.writeText "${name}.sh" config.home.activation.${name}.data;

  pluginDir = allEnabled.programs.tmux.agentIndicator.dir;
in
pkgs.runCommand "tmux-agent-indicator-hm-module-check"
  {
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"

    run() { "$@"; }
    warnEcho() { echo "$*" >&2; }

    # Old generation's store hook, a TPM hook, a user's own hook, other keys.
    seed() {
      local agent=$1 file=$2
      mkdir -p "$(dirname "$file")"
      jq -n --arg agent "$agent" '
        def old(state): { type: "command", command: "\"/nix/store/aaaa-old/share/tmux-plugins/agent-indicator\"/scripts/agent-state.sh --agent \($agent) --state \(state)" };
        {
          model: "opus",
          hooks: {
            Stop: [ { matcher: "", hooks: [ old("done"), { type: "command", command: "my-own-hook" } ] } ],
            UserPromptSubmit: [ { matcher: "", hooks: [ old("running") ] } ],
            Notification: [ { matcher: "", hooks: [ { type: "command", command: "\"$HOME/.tmux/plugins/tmux-agent-indicator\"/scripts/agent-state.sh --agent \($agent) --state needs-input" } ] } ]
          }
        }' > "$file"
    }

    claude="$HOME/.claude/settings.json"
    codex="$HOME/.codex/hooks.json"

    # Merge: store hooks of this package replace old store and TPM hooks.
    seed claude "$claude"
    seed codex "$codex"
    source ${script allEnabled "tmuxAgentIndicatorClaude"}
    source ${script allEnabled "tmuxAgentIndicatorCodex"}
    for f in "$claude" "$codex"; do
      jq -e --arg dir ${lib.escapeShellArg pluginDir} '
        .model == "opus"
        and ([.. | strings | select(contains("aaaa-old") or contains(".tmux/plugins"))] | length == 0)
        and ([.hooks[][].hooks[] | select(.command | startswith("\"" + $dir + "\"/scripts/agent-state.sh "))] | length >= 3)
        and ([.hooks.Stop[].hooks[] | select(.command == "my-own-hook")] | length == 1)
      ' "$f" >/dev/null || { echo "merge check failed for $f"; cat "$f"; exit 1; }
    done

    # Strip-only: claude integration off while the module is on, and the whole
    # module off. Only store-path hooks go; TPM hooks and other keys stay.
    for stripScript in ${script claudeDisabled "tmuxAgentIndicatorClaude"} ${script moduleDisabled "tmuxAgentIndicatorClaude"}; do
      seed claude "$claude"
      source "$stripScript"
      jq -e '
        .model == "opus"
        and ([.. | strings | select(contains("/nix/store"))] | length == 0)
        and (.hooks | has("UserPromptSubmit") | not)
        and ([.hooks.Stop[].hooks[].command] == ["my-own-hook"])
        and ([.hooks.Notification[].hooks[].command | select(contains(".tmux/plugins"))] | length == 1)
      ' "$claude" >/dev/null || { echo "strip check failed ($stripScript)"; cat "$claude"; exit 1; }
    done

    # Strip-only never creates a missing file, and leaves a file without
    # store-path hooks byte-identical.
    rm -rf "$HOME/.claude" "$HOME/.codex"
    source ${script moduleDisabled "tmuxAgentIndicatorClaude"}
    source ${script moduleDisabled "tmuxAgentIndicatorCodex"}
    test ! -e "$claude"
    test ! -e "$codex"
    test ! -d "$HOME/.codex"

    mkdir -p "$HOME/.codex"
    printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}]},"a":  1}\n' > "$codex"
    cp "$codex" "$codex.orig"
    source ${script moduleDisabled "tmuxAgentIndicatorCodex"}
    cmp "$codex" "$codex.orig"

    # Links into the store package, so plugins resolve their scripts from it.
    [ ${lib.escapeShellArg allEnabled.xdg.configFile."opencode/plugins/opencode-tmux-agent-indicator.js".source} = ${lib.escapeShellArg "${pluginDir}/plugins/opencode-tmux-agent-indicator.js"} ]
    test -f ${pluginDir}/plugins/opencode-tmux-agent-indicator.js
    test -f ${pluginDir}/scripts/agent-state.sh

    touch "$out"
  ''
