{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-25.11";
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
          rust-target = pkgs.stdenv.targetPlatform.rust.rustcTarget;
          components = {
            "rustc" = null;
            "cargo" = null;
            "rust-src" = null;
            "rust-std" = null;
            "rustc-dev" = null;
          };
          computeMissingHashes =
            compName: hash:
            (
              let
                component = builtins.fetchurl {
                  url =
                    if compName == "rust-src" then
                      "https://ci-artifacts.rust-lang.org/rustc-builds/${rust-lang-commit}/${compName}-nightly.tar.xz"
                    else
                      "https://ci-artifacts.rust-lang.org/rustc-builds/${rust-lang-commit}/${compName}-nightly-${rust-target}.tar.xz";
                };
                hashAlgo = "sha256";
                sriHash = builtins.convertHash {
                  inherit hashAlgo;
                  hash = builtins.hashFile hashAlgo component;
                  toHashFormat = "sri";
                };
                sriHashValidated =
                  if (hash != null) then
                    hash
                  else if (sriHash == "") then
                    throw "Failed to compute SRI hash for ${compName} : ${component}"
                  else
                    sriHash;

              in
              sriHashValidated
            );
          rustc = (
            pkgs.rust-bin.fromRustcRev {
              rev = rust-lang-commit;
              components = lib.mapAttrs computeMissingHashes components;
            }
          );
          rustComponents = lib.mapAttrs (
            component: _hash:
            lib.findFirst (
              c: "${component}-${c.version}-${c.passthru.platform}" == c.name
            ) (throw "Failed to find component ${component}") self.packages.${system}.rustc.availableComponents
          ) components;
          rustPlatform = pkgs.makeRustPlatform {
            inherit rustc;
            cargo = rustc;
          };
        in
        {
          default = self.packages.${system}.miri;
          inherit rustc;
          inherit (rustComponents)
            rust-src
            rust-std
            rustc-dev
            ;
          miri = rustPlatform.buildRustPackage rec {
            nativeBuildInputs = with self.packages.${system}; [
              miri-script
              cargo-miri
              rustc
              pkgs.libc
              pkgs.eza
            ];
            name = "miri";
            src = ./.;
            cargoLock = {
              lockFile = ./Cargo.lock;
            };
            checkPhase = ''
              runHook preCheck

              cargo test --lib
              runHook postCheck
            '';

            buildType = "debug";
            MIRI_SYSROOT = "${self.packages.${system}.rustc}/lib/rustlib/${rust-target}/lib";
            RUSTC_BOOTSTRAP = "1";

            CC = "${pkgs.gcc}/bin/gcc";
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
            buildType = "release";
          };
        }
      ) pkgsFor;
      devShells =

        lib.mapAttrs (system: pkgs: {
          default = pkgs.mkShell {
            shellHook = ''
              export RUSTC=${self.packages.${system}.rustc}
              export PATH="${self.packages.${system}.miri}/bin:${self.packages.${system}.cargo-miri}/bin:$PATH"
              export MIRI="${self.packages.${system}.miri}/bin/miri"
            '';

            buildInputs = with self.packages.${system}; [
              rustc
              miri
              miri-script
              cargo-miri
            ];
          };
        }) pkgsFor;
    };
}
