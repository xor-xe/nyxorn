{
  lib,
  buildNpmPackage,
  fetchzip,
  nodejs_22,
  nix-update-script,
}:

buildNpmPackage (finalAttrs: {
  pname = "openclaw";
  version = "2026.3.31";

  src = fetchzip {
    url = "https://registry.npmjs.org/openclaw/-/openclaw-${finalAttrs.version}.tgz";
    hash = "sha256-q5mwgb6xUos97ezbs9CEev6hFsih1znjHROhvL/UtVY=";
  };

  nodejs = nodejs_22;

  npmDepsHash = "sha256-QA/UpcKJn69YrMaiH1Rdsm3dlLanDIGuT6tGLR9PE8w=";

  # dist/ is pre-built and included in the published npm tarball.
  dontNpmBuild = true;

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  # Skip postinstall scripts:
  #   - openclaw's own postinstall is a no-op outside `npm install -g`
  #   - sharp and sqlite-vec ship pre-built platform binaries; their
  #     postinstalls run a live binary check that fails in the Nix sandbox.
  #     Image processing and vector search degrade gracefully without them.
  npmFlags = [ "--ignore-scripts" ];

  postInstall = ''
    wrapProgram $out/bin/openclaw \
      --set OPENCLAW_NIX_MODE "1" \
      --set-default OPENCLAW_STATE_DIR "$HOME/.openclaw"
  '';

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "Multi-channel AI gateway with extensible messaging integrations";
    homepage = "https://github.com/openclaw/openclaw";
    license = lib.licenses.mit;
    mainProgram = "openclaw";
    platforms = lib.platforms.linux;
  };
})
