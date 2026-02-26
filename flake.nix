{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      rust-overlay,
      nixpkgs,
    }:
    let
      inherit (nixpkgs) lib;
      systems = lib.systems.flakeExposed;
      pkgsFor = lib.genAttrs systems (
        system:
        import nixpkgs {
          inherit system;
          overlays = [
            rust-overlay.overlays.default
          ];
        }
      );
      # The rust version to be used for compiling miri is given by the commit given
      # in ./rust-version. We need to create the rust toolchain from this specific
      # commit.
      rust-lang-commit = lib.trim (builtins.readFile ./rust-version);
    in
    {
      packages = lib.mapAttrs (
        system: pkgs:
        let
          rustc = (
            pkgs.rust-bin.fromRustcRev {
              rev = rust-lang-commit;
              components = {
                rustc = "sha256-yWThZ66Mcyy+hBPIQNw9HTwI0j6Yv3OHyOnm4kls7kI=";
                rust-src = "sha256-Eb5XuVcHEBfQmzBEFT6cL7xjkVkQOXBo5Ng82ZjVz8Y=";
                rust-std = "sha256-ialn9Zxp9o09daONKjgVcRFm9KWDOYTGC6qIb6T/jqM=";
                rustc-dev = "sha256-6Iohot3JiWdrau0D3rMiTwqoV65cDW5wYnEEIzuvBKI=";
                # llvm-tools-preview = "sha256-ialn9Zxd9o09daONKjgVcRFm9KWDOaTGC6qIb6T/jqM=";
                cargo = "sha256-WXK6hZExYIYPhJCyC/zvVEKWwgHxNlVFutytG9tVoRY=";
              };
            }
          );
          rustPlatform = pkgs.makeRustPlatform {
            inherit rustc;
            inherit (rustc)
              rust-src
              rust-std
              rustc-dev
              llvm-tools-preview
              ;
            cargo = rustc;
          };
        in
        {
          default = self.packages.${system}.miri;
          inherit rustc;
          miri = rustPlatform.buildRustPackage {
            nativeBuildInputs = with self.packages.${system}; [
              miri-script
              cargo-miri
            ];
            name = "miri";
            src = ./.;
            cargoLock = {
              lockFile = ./Cargo.lock;
            };

            buildType = "debug";
            checkPhase = ''
              runHook preCheck
              export RUSTC=${self.packages.${system}.rustc}
              # cargo miri test runner
              runHook postCheck
            '';
          };
          genmc-sys = rustPlatform.buildRustPackage {
            name = "genmc-sys";
            src = ./genmc-sys;
            cargoLock = {
              lockFile = ./Cargo.lock;
            };
            buildType = "release";
          };
          miri-script = rustPlatform.buildRustPackage {
            name = "miri-script";
            src = lib.fileset.toSource {
              root = ./miri-script;
              fileset = ./miri-script;
            };
            cargoLock = {
              lockFile = ./miri-script/Cargo.lock;
            };
            buildType = "release";
          };

          cargo-miri = rustPlatform.buildRustPackage {
            name = "cargo-miri";
            src = lib.fileset.toSource {
              root = ./cargo-miri;
              fileset = ./cargo-miri;
            };
            cargoLock = {
              lockFile = ./cargo-miri/Cargo.lock;
            };
            # FIXME: maybe move?
            postInstall = ''
              ln $out/bin/cargo-miri $out/bin/miri
            '';
            buildType = "release";
          };
        }
      ) pkgsFor;
      devShells = lib.mapAttrs (system: pkgs: {
        default = pkgs.mkShell {
          shellHook = ''
            export RUSTC=${self.packages.${system}.cargo-miri}/bin/miri
          '';

          buildInputs = with self.packages.${system}; [
            rustc
            miri
            # miri-script
            cargo-miri
          ];
        };
      }) pkgsFor;
    };
}
