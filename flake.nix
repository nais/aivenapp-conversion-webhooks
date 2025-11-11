{
  description = "Build a cargo project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    kubegen.url = "github:farcaller/nix-kube-generators";
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
        kubelib = inputs.kubegen.lib { inherit pkgs; };

        inherit (pkgs) lib;

        craneLib = inputs.crane.mkLib pkgs;
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

        crateData = lib.importTOML ./Cargo.toml;

        # Build *just* the cargo dependencies, so we can reuse
        # all of that work (e.g. via cachix) when running in CI
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # Build the actual crate itself, reusing the dependency
        # artifacts from above.
        aivenapp-conversion-webhooks = craneLib.buildPackage (
          commonArgs
          // {
            inherit cargoArtifacts;
            meta.mainProgram = crateData.package.name;
            # version = crateData.package.version; # Test to see if this had a "data " string prefix
          }
        );
        nixos-vm-test = pkgs.testers.nixosTest {
          name = "${crateData.name}-certificates-integrationtest";
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
        };

        formatter = inputs.treefmt-nix.lib.mkWrapper pkgs {
          programs.nixfmt.enable = true;
          programs.rustfmt.enable = true;
        };

        packages = {
          default = aivenapp-conversion-webhooks;
          vm-test = nixos-vm-test;
          fasit-feature =
            lib.pipe
              {
                inherit (crateData.package) name;
                chart = ./fasit-chart;
                # namespace = "aivenapp-conversion-webhooks";
                extraOpts = [
                  # --set-json stringArray                       set JSON values on the command line (can specify multiple or separate values with commas: key1=jsonval1,key2=jsonval2)
                  # "--set-json=chart.metadata.version=${crateData.package.version}"
                  # "--set-json=chart.metadata.version=CAAAAAAAAAAARL"
                  # "--set-foobar=chart.metadata.version=CAAAAAAAAAAARL"
                  "--set-json='{\"chart\":{\"metadata\":{\"version\": \"${crateData.package.version}\"}}}'"
                ];
                values = {
                  # inherit (crateData.package) version;
                  # aivenapp-conversion-webhooks.replicationMode = 1;
                  # deployment.replicaCount = 1;
                  # persistence = {
                  #   meta.storageClass = "zfspv";
                  #   meta.size = "100Mi";
                  #   data.storageClass = "zfspv";
                  #   data.size = "1Gi";
                  # };
                  # monitoring.metrics.enabled = true;
                  # monitoring.metrics.serviceMonitor.enabled = true;

                  # podAnnotations."io.cilium.proxy-visibility" = "<Egress/53/UDP/DNS>,<Ingress/3900/TCP/HTTP>,<Ingress/3902/TCP/HTTP>,<Ingress/3903/TCP/HTTP>";
                };
              }
              [
                kubelib.buildHelmChart
                builtins.readFile
                kubelib.fromYAML
                # (builtins.map patchService)
                kubelib.mkList
                kubelib.toYAMLFile
              ];
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          image = pkgs.dockerTools.buildLayeredImage {
            name = crateData.package.name;
            tag = "latest";
            contents = [ aivenapp-conversion-webhooks ];
            config = {
              WorkingDir = "/app";
              User = "65532:65532"; # v0v, some number
              Entrypoint = [ "${aivenapp-conversion-webhooks}/bin/aivenapp-conversion-webhooks" ];
              ExposedPorts = [ "3000/tcp" ];
              Env = [ "RUST_LOG=info" ];
              Volumes = {
                "/app" = { };
              };
            };
          };
        };

        apps.default = inputs.flake-utils.lib.mkApp {
          drv = aivenapp-conversion-webhooks;
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
