{
  description = "straps-collab — collaborative org-mode notebooks for straps.nvim";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkPlugin = pkgs: pkgs.vimUtils.buildVimPlugin {
        pname = "straps-collab";
        version = self.shortRev or self.dirtyShortRev or "dev";
        src = self;
        meta = {
          description = "Collaborative org-mode notebooks for straps.nvim";
          license = nixpkgs.lib.licenses.mit;
        };
      };
    in
    {
      packages = forAllSystems (pkgs: rec {
        straps-collab = mkPlugin pkgs;
        default = straps-collab;
      });

      overlays.default = final: prev: {
        vimPlugins = prev.vimPlugins // { straps-collab = mkPlugin final; };
      };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.neovim
            pkgs.luajitPackages.busted pkgs.luajitPackages.nlua
          ];
        };
      });

      checks = forAllSystems (pkgs: {
        tests = pkgs.stdenvNoCC.mkDerivation {
          name = "straps-collab-tests";
          src = self;
          nativeBuildInputs = [ pkgs.neovim pkgs.luajitPackages.busted pkgs.luajitPackages.nlua ];
          dontBuild = true;
          doCheck = true;
          checkPhase = ''
            export HOME=$TMPDIR
            export XDG_DATA_HOME=$TMPDIR/data XDG_STATE_HOME=$TMPDIR/state XDG_CACHE_HOME=$TMPDIR/cache
            fail=0
            for t in tests/*_spec.lua; do
              echo "== $t"
              busted "$t" || fail=1
            done
            [ "$fail" = 0 ]
          '';
          installPhase = "touch $out";
        };
      });
    };
}
