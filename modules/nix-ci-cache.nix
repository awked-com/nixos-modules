{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nix-ci-cache;
  storage = pkgs.writeText "nix-ci-cache-storage.json" (
    builtins.toJSON {
      inherit (cfg) repository;
    }
  );
in
{
  options.services.nix-ci-cache = {
    enable = lib.mkEnableOption "a loopback Nix cache backed by encrypted GHCR objects";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nix-ci-worker;
      defaultText = lib.literalExpression "pkgs.nix-ci-worker";
      description = "Package providing the nix-ci-worker cache command.";
    };
    repository = lib.mkOption {
      type = lib.types.str;
      description = "GHCR package containing the encrypted cache, for example ghcr.io/example/cache.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      description = "Port for the loopback cache listener.";
    };
    identityFile = lib.mkOption {
      type = lib.types.str;
      description = "Absolute runtime path to the cache age identity, outside the Nix store.";
    };
    publicKey = lib.mkOption {
      type = lib.types.str;
      description = "Trusted Nix cache signing public key, in name:base64 form.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.identityFile && !(lib.hasPrefix "/nix/store/" cfg.identityFile);
        message = "Cache credentials must be absolute runtime paths outside the Nix store.";
      }
    ];
    nix.settings = {
      extra-substituters = [ "http://127.0.0.1:${toString cfg.port}?priority=30" ];
      extra-trusted-public-keys = [ cfg.publicKey ];
      require-sigs = true;
      narinfo-cache-negative-ttl = 0;
    };
    systemd.services.nix-ci-cache = {
      description = "Decrypt Nix cache objects on loopback";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} cache --config ${storage} --identity %d/identity --port ${toString cfg.port}";
        LoadCredential = [ "identity:${cfg.identityFile}" ];
        DynamicUser = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        TasksMax = 128;
        MemoryMax = "512M";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
