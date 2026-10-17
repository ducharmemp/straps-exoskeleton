{ pkgs, modules, package }:
let
  lib = pkgs.lib;
  evaluate = module: config: (lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      {
        options.extraPlugins = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
        options.extraConfigLua = lib.mkOption { type = lib.types.lines; default = ""; };
      }
      module
      config
    ];
  }).config;
  disabled = evaluate modules.default { };
  enabled = evaluate modules.default { plugins."straps-collab".enable = true; };
  named = evaluate modules."straps-collab" { plugins."straps-collab".enable = true; };
  custom = evaluate modules.default {
    plugins."straps-collab" = { enable = true; package = pkgs.emptyDirectory; };
  };
  ordered = evaluate modules.default {
    plugins."straps-collab".enable = true;
    extraConfigLua = "require('straps').setup({})";
  };
  registration = "require('straps_collab').register()\n";
  predicates = {
    disabledPackages = disabled.extraPlugins == [ ];
    disabledLua = disabled.extraConfigLua == "";
    defaultPackage = map toString enabled.extraPlugins == [ (toString package) ];
    enabledLua = enabled.extraConfigLua == registration;
    customPackage = map toString custom.extraPlugins == [ (toString pkgs.emptyDirectory) ];
    aliasPackages = map toString named.extraPlugins == map toString enabled.extraPlugins;
    aliasLua = named.extraConfigLua == enabled.extraConfigLua;
    registrationOrder = ordered.extraConfigLua == "require('straps').setup({})\n${registration}";
  };
in {
  inherit predicates;
  check = assert lib.all (value: value) (builtins.attrValues predicates);
    pkgs.runCommand "straps-collab-nixvim-module-contract" { } "touch $out";
}
