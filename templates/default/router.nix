{
  image.label = "NIX";

  deploy.host = "192.168.1.1";

  services.dropbear = {
    enable = true;
    authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIReplaceThisWithYourOwnPublicKeyReplaceThisAA you@example"
    ];
  };
}
