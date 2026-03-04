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
      nixpkgs-small,
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
          components = [
            "rustc"
            "cargo"
            "rust-src"
            "rust-std"
            "rustc-dev"
          ];
          componentToHash =
            compName:
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
                # Convert to SRI using nix-hash command at build time
                # sriHash =

                #   builtins.readFile (
                #     pkgs.runCommand "hash-${compName}"
                #       {
                #       }
                #       (
                #         let
                #           nix-hash = getExe' pkgs.nix "nix-hash";
                #         in
                #         ''
                #           hash="$(${nix-hash} --type ${hashAlgo} --flat ${component} || exit 1)"
                #           hash_sri="$(${nix-hash} --type ${hashAlgo} --to-sri $hash || exit 1)"
                #           echo $hash_sri > $out
                #         ''
                #       )
                #   );
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
              sriHashValidated
            );
          rustc = (
            pkgs.rust-bin.fromRustcRev {
              rev = rust-lang-commit;
              components = lib.genAttrs components componentToHash;
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
            ];
            name = "miri";
            src = ./.;
            cargoLock = {
              lockFile = ./Cargo.lock;
            };

            buildType = "debug";
            checkPhase = ''
              runHook preCheck
              export RUSTC=${getExe' self.packages.${system}.rustc "rustc"}
                export MIRI_SYSROOT=./target/${buildType}/)
              cargo test
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
      devShells =

        lib.mapAttrs (system: pkgs: {
          default = pkgs.mkShell {
            shellHook = ''
              export RUSTC={self.packages.{system}.cargo-miri}/bin/miri
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
