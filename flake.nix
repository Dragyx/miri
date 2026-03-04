{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-25.11";
    # Unfortunatly, we need builtins.convertHash which is not yet in unstable.
    # nixpkgs-small.url = "https://channels.nixos.org/nixos-unstable-small/nixexprs.tar.xz";
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
      # inherit (nixpkgs-small.lib) convertHash;
      inherit (lib) getExe';
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
            "rustc" = "";
            "cargo" = "";
            "rust-src" = "";
            "rust-std" = "";
            "rustc-dev" = "";
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
                  if (sriHash == "") then
                    throw "Failed to compute SRI hash for ${compName} : ${component}"
                  else
                    sriHash;

              in
              if (hash == "") then sriHashValidated else hash
            );
          rustc = (
            pkgs.rust-bin.fromRustcRev {
              rev = rust-lang-commit;
              components = lib.mapAttrs components computeMissingHashes;
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
              export CARGO_TARGET_DIR="$TMPDIR/target"

              # Run library unit tests (these should pass)
              cargo miri test --lib --release

              runHook postCheck
            '';

            buildType = "debug";
            MIRI_SYSROOT = "${self.packages.${system}.rustc}/lib/rustlib/${rust-target}/lib";
            RUSTC_BOOTSTRAP = "1";
            MIRI_SKIP_UI_CHECKS = "1";
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
