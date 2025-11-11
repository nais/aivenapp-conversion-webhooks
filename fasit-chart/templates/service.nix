{ release }:
{
  apiVersion = "v1";
  kind = "Service";
  metadata = {
    name = "${release.name}-webhook";
    labels = {
      app = "${release.name}-webhook";
    };
  };
  spec = {
    type = "ClusterIP";
    ports = [
      {
        port = 443;
        targetPort = "webhook-server";
        protocol = "TCP";
        name = "http";
      }
    ];
    selector = {
      app = "${release.name}-webhook";
    };
  };
}
