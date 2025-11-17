{
  lib,
  aacw,
  release,
  extraConfig,
}:
lib.recursiveUpdate {
  apiVersion = "apps/v1";
  kind = "Deployment";
  metadata = {
    labels.app = "${release.name}-webhook";
    name = "${release.name}-webhook";
  };
  spec = {
    replicas = 2;
    selector.matchLabels.app = "${release.name}-webhook";
    template = {
      metadata.labels.app = "${release.name}-webhook";
      spec = {
        containers = [
          {
            command = [ "${aacw}/bin/aiven-conversion-webhooks" ];
            image = "europe-north1-docker.pkg.dev/nais-io/nais/feature/${release.name}:${release.imageTag}";
            name = "aacw";
            ports = [
              {
                containerPort = 3000;
                name = "webhook-server";
                protocol = "TCP";
              }
            ];
            volumeMounts = [
              {
                mountPath = "/app";
                name = "aacw-cert";
                readOnly = true;
              }
            ];
            securityContext = {
              allowPrivilegeEscalation = false;
              capabilities.drop = [ "ALL" ];
              privileged = false;
              readOnlyRootFilesystem = true;
              runAsGroup = 1069;
              runAsNonRoot = true;
              runAsUser = 1069;
              seccompProfile.type = "RuntimeDefault";
            };
          }
        ];
        volumes = [
          {
            name = "aacw-cert";
            projected.sources = [
              {
                secret = {
                  items = [
                    {
                      key = "tls.crt";
                      path = "tls.crt";
                    }
                    {
                      key = "tls.key";
                      path = "tls.key";
                    }
                  ];
                  name = "${release.name}-webhook";
                };
              }
            ];
          }
        ];
      };
    };
  };
} extraConfig
