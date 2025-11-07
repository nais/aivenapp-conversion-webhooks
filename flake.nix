{
  description = "Build a cargo project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane.url = "github:ipetkov/crane";

    flake-utils.url = "github:numtide/flake-utils";

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      crane,
      flake-utils,
      advisory-db,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        inherit (pkgs) lib;

        craneLib = crane.mkLib pkgs;
        src = craneLib.cleanCargoSource ./.;

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

        # Build *just* the cargo dependencies, so we can reuse
        # all of that work (e.g. via cachix) when running in CI
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # Build the actual crate itself, reusing the dependency
        # artifacts from above.
        my-crate = craneLib.buildPackage (
          commonArgs
          // {
            inherit cargoArtifacts;
          }
        );
      in
      {
        checks = {
          # Build the crate as part of `nix flake check` for convenience
          inherit my-crate;

          # Run clippy (and deny all warnings) on the crate source,
          # again, reusing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          my-crate-clippy = craneLib.cargoClippy (
            commonArgs
            // {
              inherit cargoArtifacts;
              cargoClippyExtraArgs = "--all-targets -- --deny warnings";
            }
          );

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
          my-crate-fmt = craneLib.cargoFmt {
            inherit src;
          };

          my-crate-toml-fmt = craneLib.taploFmt {
            src = pkgs.lib.sources.sourceFilesBySuffices src [ ".toml" ];
            # taplo arguments can be further customized below as needed
            # taploExtraArgs = "--config ./taplo.toml";
          };

          # Audit dependencies
          my-crate-audit = craneLib.cargoAudit {
            inherit src advisory-db;
          };

          # Audit licenses
          my-crate-deny = craneLib.cargoDeny {
            inherit src;
          };

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
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          nixos-vm-test = pkgs.nixosTest {
            name = "aacw-webhook";
            nodes.machine = { pkgs, ... }: {
              environment.systemPackages = [
                pkgs.curl
                pkgs.jq
                pkgs.step-cli
                my-crate
              ];


              systemd.services.aacw = {
                description = "AivenApp Conversion Webhook";
                wantedBy = [ "multi-user.target" ];
                after = [ "network.target" ];
                serviceConfig = {
                  Type = "simple";
                  WorkingDirectory = "/var/lib/aacw";
                  ExecStartPre = lib.mkForce "${pkgs.bash}/bin/bash -c 'mkdir -p /var/lib/aacw && cd /var/lib/aacw && ${pkgs.step-cli}/bin/step certificate create localhost cert.pem key.pem --profile self-signed --subtle --no-password --insecure'";
                  ExecStart = "${my-crate}/bin/aivenapp-conversion-webhooks";
                  Restart = "on-failure";
                  RestartSec = 1;
                };
              };
            };
            testScript = ''
              machine.start()
              machine.wait_for_unit("multi-user.target")
              machine.wait_for_unit("aacw.service")
              machine.wait_for_open_port(3000)

              # Prepare a minimal ConversionReview request targeting v2
              payload='{"apiVersion":"apiextensions.k8s.io/v1","kind":"ConversionReview","request":{"uid":"123","desiredAPIVersion":"v2","objects":[{"apiVersion":"v1","kind":"AivenApp","spec":{"secretName":"supersecret","kafka":{}}}]}}'

              # Send to the webhook over TLS; ignore verification because it's self-signed
              resp=$(curl -sk https://localhost:3000/convert -H 'content-type: application/json' --data "$payload")
              echo "$resp" | jq .

              # Validate that secretName moved under spec.kafka
              echo "$resp" | jq -e '.response.convertedObjects[0].spec.kafka.secretName == "supersecret"'
            '';
          };
        };

        packages = {
          default = my-crate;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = my-crate;
        };

        apps.mk-cert = flake-utils.lib.mkApp { drv = pkgs.writeShellApplication {
          name = "mk-cert";
          text = "step certificate create localhost cert.pem key.pem --profile self-signed --subtle --no-password --insecure";
          runtimeInputs = [pkgs.step-cli];
        };
                                            };

        devShells.default = craneLib.devShell {
          # Inherit inputs from checks.
          checks = self.checks.${system};

          # Additional dev-shell environment variables can be set directly
          # MY_CUSTOM_DEVELOPMENT_VAR = "something else";

          # Extra inputs can be added here; cargo and rustc are provided by default.
          packages = [
            pkgs.rust-analyzer
            pkgs.step-cli
          ];
        };
      }
    );
}
