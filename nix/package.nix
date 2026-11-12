{
  lib,
  tmuxPlugins,
  version ? "unstable",
}:
tmuxPlugins.mkTmuxPlugin {
  pluginName = "agent-indicator";
  rtpFilePath = "agent-indicator.tmux";
  inherit version;

  # Runtime files only: docs, tests and the TPM-style installers stay out of the
  # store path, so editing them doesn't rebuild the plugin.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../agent-indicator.tmux
      ../hooks
      ../plugins
      ../scripts
      ../LICENSE
      ../licenses
    ];
  };

  meta = {
    description = "tmux plugin showing AI agent state in pane borders, window titles and the status bar";
    homepage = "https://github.com/accessd/tmux-agent-indicator";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
