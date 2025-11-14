{
  description = "Build a cargo project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    crane.url = "github:ipetkov/crane";
    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs =
    inputs:
    inputs.flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = inputs.nixpkgs.legacyPackages.${system};

        inherit (pkgs) lib;

        craneLib = inputs.crane.mkLib pkgs;
        src = craneLib.cleanCargoSource ./.;
        # Use short git SHA only; support shallow checkouts. Fallback to GITHUB_SHA or "dev".
        githubSha = builtins.getEnv "GITHUB_SHA";
        commitSha =
          if inputs.self ? "shortRev" then
            inputs.self.shortRev
          else if githubSha != "" then
            builtins.substring 0 7 githubSha
          else
            "";
        dockerTag = if commitSha != "" then commitSha else "dev";
        version = "v${crateData.package.version}-${dockerTag}";

        # Common arguments can be set here to avoid repeating them later
        commonArgs = {
          inherit src;
          strictDeps = true;

          buildInputs = [
            # Add additional build inputs here
          ]
          ++ lib.optionals pkgs.stdenv.isDarwin [
            # Additional darwin specific inputs can be set here
            pkgs.libiconv
          ];

          # Additional environment variables can be set directly
          # MY_CUSTOM_VAR = "some value";
        };

        crateData = lib.importTOML ./Cargo.toml;

        # Build *just* the cargo dependencies, so we can reuse
        # all of that work (e.g. via cachix) when running in CI
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # Build the actual crate itself, reusing the dependency
        # artifacts from above.
        aacw = craneLib.buildPackage (
          commonArgs
          // {
            inherit cargoArtifacts version;
            meta.mainProgram = crateData.package.name;
          }
        );
        sbom = craneLib.mkCargoDerivation (
          commonArgs
          // {
            # Require the caller to specify cargoArtifacts we can use
            inherit cargoArtifacts;

            # A suffix name used by the derivation, useful for logging
            pnameSuffix = "-sbom";

            # Set the cargo command we will use and pass through the flags
            installPhase = "mv bom.json $out";
            buildPhaseCargoCommand = "cargo cyclonedx -f json --all --override-filename bom";
            nativeBuildInputs = (commonArgs.nativeBuildInputs or [ ]) ++ [ pkgs.cargo-cyclonedx ];
          }
        );

        nixos-vm-test = pkgs.testers.nixosTest {
          name = "certificates-integrationtest";
          nodes.machine =
            { pkgs, ... }:
            {
              environment.systemPackages = [
                pkgs.curl
                pkgs.jq
                pkgs.step-cli
                aacw
              ];
            };
          testScript = # python
            ''
              machine.start()
              machine.wait_for_unit("multi-user.target")
              machine.succeed("mkdir -p /app")
              machine.succeed("${
                lib.getExe (
                  pkgs.writeShellApplication {
                    name = "generate-self-signed-certs";
                    text = ''
                      set -euo pipefail
                      cd /app
                      step certificate create localhost tls.crt tls.key --profile self-signed --subtle --no-password --insecure
                    '';
                    runtimeInputs = [ pkgs.step-cli ];
                  }
                )
              }")

              machine.succeed("TLS_CERT_FILE=/app/tls.crt TLS_KEY_FILE=/app/tls.key ${lib.getExe aacw} & disown")
              machine.wait_for_open_port(3000)

              out = machine.succeed("curl -sk https://localhost:3000/health")
              out = machine.succeed("curl -sk https://localhost:3000/ready")
              assert out.strip() == "ok"

              machine.succeed("""cat >/tmp/payload.json <<'EOF'
              {"apiVersion":"apiextensions.k8s.io/v1","kind":"ConversionReview","request":{"uid":"123","desiredAPIVersion":"v2","objects":[{"apiVersion":"v1","kind":"AivenApp","spec":{"secretName":"supersecret","kafka":{}}}]}}
              EOF
              """)
              resp = machine.succeed("curl -sk https://localhost:3000/convert -H 'content-type: application/json' --data @/tmp/payload.json")
              # Basic parse to ensure it's valid JSON
              machine.succeed("printf %s \"$resp\" | jq . >/dev/null")
            '';
        };
      in
      {
        checks = {
          inherit aacw sbom;

          # Run clippy (and deny all warnings) on the crate source,
          # again, reusing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          # my-crate-clippy = craneLib.cargoClippy (
          #   commonArgs
          #   // {
          #     inherit cargoArtifacts;
          #     cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          #   }
          # );

          my-crate-doc = craneLib.cargoDoc (
            commonArgs
            // {
              inherit cargoArtifacts;
              # This can be commented out or tweaked as necessary, e.g. set to
              # `--deny rustdoc::broken-intra-doc-links` to only enforce that lint
              env.RUSTDOCFLAGS = "--deny warnings";
            }
          );

          # Check formatting
          # my-crate-fmt = craneLib.cargoFmt {
          #   inherit src;
          # };

          # # Audit dependencies
          my-crate-audit = craneLib.cargoAudit {
            inherit src;
            inherit (inputs) advisory-db;
          };

          # # Audit licenses
          # my-crate-deny = craneLib.cargoDeny {
          #   inherit src;
          # };

          # Run tests with cargo-nextest
          # Consider setting `doCheck = false` on `my-crate` if you do not want
          # the tests to run twice
          my-crate-nextest = craneLib.cargoNextest (
            commonArgs
            // {
              inherit cargoArtifacts;
              partitions = 1;
              partitionType = "count";
              cargoNextestPartitionsExtraArgs = "--no-tests=pass";
            }
          );
        };

        formatter = inputs.treefmt-nix.lib.mkWrapper pkgs {
          programs.nixfmt.enable = true;
          programs.rustfmt.enable = true;
        };

        packages = {
          inherit aacw sbom;
          default = aacw;
          vm-test = nixos-vm-test;

          version = pkgs.writeText "version" version;
          fasit-feature =
            let
              release = {
                inherit (crateData.package) name;
                imageTag = version;
                namespace = "nais-system";
              };
            in
            lib.pipe
              {
                chart = import ./fasit-chart/Chart.nix { inherit version; };
                feature = import ./fasit-chart/Feature.nix { };
                issuer = import ./fasit-chart/certissuer.nix {
                  inherit lib release;
                  extraConfig = { };
                };
                deployment = import ./fasit-chart/deployment.nix {
                  inherit lib aacw release;
                  extraConfig = { };
                };
                service = import ./fasit-chart/service.nix {
                  inherit lib release;
                  extraConfig = { };
                };
                certificate = import ./fasit-chart/certificate.nix {
                  inherit lib release;
                  extraConfig = { };
                };
              }
              [
                (lib.mapAttrs (
                  name: data:
                  pkgs.writeTextFile {
                    inherit name;
                    text = builtins.toJSON data;
                  }
                ))
                (
                  files:
                  pkgs.stdenv.mkDerivation {
                    name = "helm-chart";
                    dontUnpack = true;
                    buildPhase = ''
                      mkdir -p $out/templates
                      touch $out/values.yaml
                      cp ${files.chart} $out/Chart.yaml
                      cp ${files.feature} $out/Feature.yaml
                      cp ${files.issuer} $out/templates/Issuer.yaml
                      cp ${files.deployment} $out/templates/Deployment.yaml
                      cp ${files.service} $out/templates/Service.yaml
                      cp ${files.certificate} $out/templates/Certificate.yaml
                    '';
                  }
                )
              ];
        }

        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          image =
            (pkgs.dockerTools.buildLayeredImage {
              name = crateData.package.name;
              tag = version;
              contents = [ aacw ];
              config = {
                WorkingDir = "/app";
                User = "65532:65532";
                Entrypoint = [ (lib.getExe aacw) ];
                ExposedPorts = {
                  "3000/tcp" = { };
                };
                Env = [ "RUST_LOG=info" ];
                Volumes = {
                  "/app" = { };
                };
              };
            }).overrideAttrs
              (old: {
                imageName = crateData.package.name;
                imageTag = version;
              });
        };

        apps.default = inputs.flake-utils.lib.mkApp {
          drv = aacw;
        };

        # Print the current version/tag
        apps.version = inputs.flake-utils.lib.mkApp {
          drv = pkgs.writeShellApplication {
            name = "print-version";
            text = ''
              printf %s "${version}"
            '';
          };
        };

        apps.mk-cert = inputs.flake-utils.lib.mkApp {
          drv = pkgs.writeShellApplication {
            name = "mk-cert";
            text = "step certificate create localhost cert.pem key.pem --profile self-signed --subtle --no-password --insecure";
            runtimeInputs = [ pkgs.step-cli ];
          };
        };

        devShells.default = craneLib.devShell {
          # Inherit inputs from checks.
          checks = inputs.self.checks.${system};

          # Additional dev-shell environment variables can be set directly
          # MY_CUSTOM_DEVELOPMENT_VAR = "something else";

          # Extra inputs can be added here; cargo and rustc are provided by default.
          packages = [
            pkgs.rust-analyzer
            pkgs.step-cli
            pkgs.kubernetes-helm
          ];
        };
      }
    );
}
