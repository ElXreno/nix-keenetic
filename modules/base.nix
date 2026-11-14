{ pkgs, ... }:
let
  certificates = "/etc/ssl/certs/ca-certificates.crt";
in
{
  environment.etc = {
    "resolv.conf".source = "/tmp/resolv.conf";
    hosts.source = "/tmp/hosts";
    "ssl/certs/ca-certificates.crt".source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  };

  environment.variables = {
    SSL_CERT_FILE = certificates;
    NIX_SSL_CERT_FILE = certificates;
  };

  environment.profileExtra = ''
    if [ -r /tmp/TZ ]; then
      TZ=$(cat /tmp/TZ)
      export TZ
    fi
  '';
}
