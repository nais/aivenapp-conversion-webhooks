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
        aivenapp-conversion-webhooks = craneLib.buildPackage (
          commonArgs
          // {
            inherit cargoArtifacts;
            meta.mainProgram = "aivenapp-conversion-webhooks";
          }
        );
        nixos-vm-test = pkgs.testers.nixosTest {
          name = "aacw-webhook";
          nodes.machine =
            { pkgs, ... }:
            {
              environment.systemPackages = [
                pkgs.curl
                pkgs.jq
                pkgs.step-cli
                aivenapp-conversion-webhooks
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

              machine.succeed("TLS_CERT_FILE=/app/tls.crt TLS_KEY_FILE=/app/tls.key ${lib.getExe aivenapp-conversion-webhooks} & disown")
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
          inherit aivenapp-conversion-webhooks;

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
          # my-crate-audit = craneLib.cargoAudit {
          #   inherit src advisory-db;
          # };

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
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux nixos-vm-test;

        packages =
          {
            default = aivenapp-conversion-webhooks;
            vm-test = nixos-vm-test;
          }
          // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            image = pkgs.dockerTools.buildLayeredImage {
              name = "aivenapp-conversion-webhooks";
              tag = "latest";
              contents = [ aivenapp-conversion-webhooks ];
              config = {
                WorkingDir = "/app";
                User = "65532:65532"; # v0v, some number
                Entrypoint = [ "${aivenapp-conversion-webhooks}/bin/aivenapp-conversion-webhooks" ];
                ExposedPorts = [ "3000/tcp" ];
                Env = [ "RUST_LOG=info" ];
                Volumes = { "/app" = {}; };
              };
            };
          };

        apps.default = flake-utils.lib.mkApp {
          drv = aivenapp-conversion-webhooks;
        };

        apps.mk-cert = flake-utils.lib.mkApp {
          drv = pkgs.writeShellApplication {
            name = "mk-cert";
            text = "step certificate create localhost cert.pem key.pem --profile self-signed --subtle --no-password --insecure";
            runtimeInputs = [ pkgs.step-cli ];
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
