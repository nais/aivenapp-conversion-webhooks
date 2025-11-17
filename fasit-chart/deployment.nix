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
    template.metadata.labels.app = "${release.name}-webhook";
    spec = {
      containers = [
        {
          command = [ (lib.getExe aacw) ];
          image = "europe-north1-docker.pkg.dev/nais-io/nais/images/aacw:${release.imageTag}";
          name = "aacw";
          ports = [
            {
              containerPort = 8443;
              name = "webhook-server";
              protocol = "TCP";
            }
          ];
          volumeMounts = [
            {
              mountPath = "/tmp/k8s-webhook-server/serving-certs";
              name = "aacw-cert";
              readOnly = true;
            }
          ];
        }
      ];
      volumes = [
        {
          name = "aacw-cert";
          secret = {
            defaultMode = 420;
            secretname = "${release.name}-webhook";
          };
        }
      ];
    };
  };
} extraConfig
