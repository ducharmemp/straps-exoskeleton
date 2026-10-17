{
  description = "straps-exoskeleton — collaborative org-mode notebooks for straps.nvim";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkPlugin = pkgs: pkgs.vimUtils.buildVimPlugin {
        pname = "straps-exoskeleton";
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
        straps-exoskeleton = mkPlugin pkgs;
        default = straps-exoskeleton;
      });

      overlays.default = final: prev: {
        vimPlugins = prev.vimPlugins // { straps-exoskeleton = mkPlugin final; };
      };

      nixvimModules = let
        collab = { lib, config, pkgs, ... }:
          let cfg = config.plugins."straps-exoskeleton";
          in {
            options.plugins."straps-exoskeleton" = {
              enable = lib.mkEnableOption "straps-exoskeleton shared org notebooks";
              package = lib.mkOption {
                type = lib.types.package;
                default = mkPlugin pkgs;
                defaultText = lib.literalExpression ''inputs.straps-exoskeleton.packages.''${system}.default'';
                description = "The straps-exoskeleton plugin package.";
              };
            };
            config = lib.mkIf cfg.enable {
              extraPlugins = [ cfg.package ];
              extraConfigLua = lib.mkAfter ''
                require('straps_collab').register()
              '';
            };
          };
      in {
        "straps-exoskeleton" = collab;
        default = collab;
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
        nixvim-module = (import ./tests/nixvim-module.nix {
          inherit pkgs;
          modules = self.nixvimModules;
          package = mkPlugin pkgs;
        }).check;
        tests = pkgs.stdenvNoCC.mkDerivation {
          name = "straps-exoskeleton-tests";
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
