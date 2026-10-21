{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    zmk-nix = {
      url = "github:lilyinstarlight/zmk-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zmk-nix }: let
    forAllSystems = nixpkgs.lib.genAttrs (nixpkgs.lib.attrNames zmk-nix.packages);
  in {
    packages = forAllSystems (system: let
      inherit (zmk-nix.legacyPackages.${system}) buildKeyboard buildSplitKeyboard;

      src = nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = nixpkgs.lib.fileset.unions [
          ./config
          ./zephyr
          ./snippets
          ./src
          ./CMakeLists.txt
          ./Kconfig
        ];
      };

      zephyrDepsHash = "sha256-B8RWKvZmSZp6AVy2QHnW5sHnfAxb3OqHkexgB1enG9s=";
    in rec {
      default = firmware;

      firmware = buildSplitKeyboard {
        name = "sofle";
        inherit src zephyrDepsHash;

        board = "nice_nano//zmk";
        shield = "sofle_%PART% nice_view_adapter nice_view_gem";
        snippets = [ "bootloader-on-1200-baud" ];

        meta.platforms = nixpkgs.lib.platforms.all;
      };

      settings_reset = buildKeyboard {
        name = "settings_reset";
        inherit src zephyrDepsHash;
        inherit (firmware) westDeps;

        board = "nice_nano//zmk";
        shield = "settings_reset";

        meta.platforms = nixpkgs.lib.platforms.all;
      };

      update = zmk-nix.packages.${system}.update;
    });

    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.mkShell {
        packages = [
          pkgs.cmake
          pkgs.ninja
          pkgs.gcc-arm-embedded
          (pkgs.python3.withPackages (ps: [ ps.west ps.pyelftools ]))
        ];

        env = {
          ZEPHYR_TOOLCHAIN_VARIANT = "gnuarmemb";
          GNUARMEMB_TOOLCHAIN_PATH = pkgs.gcc-arm-embedded;
          ZMK_WEST_DEPS = self.packages.${system}.firmware.westDeps;
          GIT_CONFIG_COUNT = "1";
          GIT_CONFIG_KEY_0 = "safe.directory";
          GIT_CONFIG_VALUE_0 = "*";
        };
      };
    });
  };
}
