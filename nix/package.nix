{
  lib,
  python3,
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

  # agent-limits.sh looks python3 up on PATH, which a NixOS profile may not
  # have; pin it to the store interpreter. --replace-fail makes the build fail
  # if the script stops matching, instead of silently shipping an unpinned one.
  # agent-relay.py (started by agent-ssh.sh) is pinned through its shebang.
  buildInputs = [ python3 ];
  postInstall = ''
    substituteInPlace "$target/scripts/agent-limits.sh" \
      --replace-fail 'command -v python3' 'command -v ${python3.interpreter}' \
      --replace-fail 'exec python3 ' 'exec ${python3.interpreter} '
    patchShebangs --host "$target/scripts/agent-limits.py" "$target/scripts/agent-relay.py"
  '';

  meta = {
    description = "tmux plugin showing AI agent state in pane borders, window titles and the status bar";
    homepage = "https://github.com/accessd/tmux-agent-indicator";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
