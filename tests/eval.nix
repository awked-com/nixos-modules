{
  nixpkgs,
  system,
  modules,
  moduleLib,
}:
let
  inherit (nixpkgs) lib;
  evaluate =
    extraModules:
    (lib.nixosSystem {
      inherit system;
      modules = [
        {
          networking.hostName = "module-test";
          system.stateVersion = "25.11";
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
        }
      ]
      ++ extraModules;
    }).config;
  require =
    description: value:
    assert lib.assertMsg value description;
    true;
  cast = evaluate [
    modules.cast
    {
      services.cast = {
        enable = true;
        airplay.interfaces = [ "lan0" ];
      };
      users.users.cast.uid = 2000;
    }
  ];
  wireguard = evaluate [
    modules.amneziawg-go
    {
      networking.amneziawg-go.interfaces.awg0 = {
        privateKeyFile = "/run/keys/awg0";
        listenPort = 51820;
        peers = [
          {
            name = "peer";
            publicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
            allowedIPs = [ "2001:db8::/64" ];
            endpoint = "vpn.example.test:51820";
          }
        ];
        dynamicEndpointRefreshSeconds = 30;
      };
    }
  ];
  vm = evaluate [
    (moduleLib.qemuVM {
      name = "example";
      description = "Example virtual machine";
      uid = 2001;
      vcpu = 2;
      memory = 1024;
      volumes = [ { image = "/var/lib/vms/example.raw"; } ];
      interfaces = [
        {
          ifname = "tap-example";
          mac = "02:00:00:00:00:01";
        }
      ];
    })
  ];
  invalidVM = evaluate [
    (moduleLib.qemuVM {
      name = "invalid";
      description = "Invalid VM fixture";
      uid = 0;
    })
  ];
  pinned = evaluate [
    (moduleLib.pinnedBindSources {
      name = "example";
      sources."/var/lib/example" = {
        path = "/srv/example";
        create = true;
        user = "example";
        group = "example";
        mode = "0700";
      };
    })
    {
      # Only the executable location is needed to evaluate the lifecycle units.
      nixpkgs.overlays = [
        (_: prev: { pinned-bind-sources = prev.writeShellScriptBin "pinned-bind-sources" "exit 0"; })
      ];
      users.users.example = {
        isSystemUser = true;
        uid = 2002;
        group = "example";
      };
      users.groups.example.gid = 2002;
      containers.example.config.system.stateVersion = "25.11";
    }
  ];
  secrets = evaluate [
    modules.sops-credential-restarts
    ({ lib, ... }: {
      # Model the public sops-nix option contract without secret files or identities.
      options.sops = lib.genAttrs [ "secrets" "templates" ] (
        _:
        lib.mkOption {
          default = { };
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                path = lib.mkOption { type = lib.types.str; };
                restartUnits = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                };
              };
            }
          );
        }
      );
      config = {
        sops.secrets.example.path = "/run/secrets/example";
        sops.secrets.manual = {
          path = "/run/secrets/manual";
          restartUnits = [ "manual.service" ];
        };
        sops.templates.example.path = "/run/secrets/template";
        systemd.services.consumer.serviceConfig = {
          ExecStart = "/bin/true";
          LoadCredential = [
            "key:/run/secrets/example"
            "settings:/run/secrets/template"
          ];
        };
        systemd.services.disabled = {
          enable = false;
          serviceConfig.LoadCredential = [ "key:/run/secrets/example" ];
        };
        systemd.services.scalar.serviceConfig = {
          ExecStart = "/bin/true";
          LoadCredential = "key:/run/secrets/example";
        };
        systemd.services.unrelated.serviceConfig.ExecStart = "/bin/true";
      };
    })
  ];
  evaluateCache =
    identityFile:
    evaluate [
      modules.nix-ci-cache
      ({ pkgs, ... }: {
        services.nix-ci-cache = {
          enable = true;
          package = pkgs.writeShellApplication {
            name = "nix-ci-worker";
            text = "exit 0";
          };
          repository = "ghcr.io/example/cache";
          port = 9999;
          inherit identityFile;
          publicKey = "example:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        };
      })
    ];
  cache = evaluateCache "/run/keys/cache";
  invalidCache = evaluateCache "/nix/store/example/identity";
in
{
  castLifecycle = require "Cast receiver lifecycle must coordinate both protocols and the display" (
    cast.services.avahi.allowInterfaces == [ "lan0" ]
    && builtins.elem "display-power.service" cast.systemd.services.uxplay.requires
    && builtins.elem "miracle-sink.service" cast.systemd.services.miracle-wifid.unitConfig.Upholds
    && cast.systemd.services.uxplay.serviceConfig.User == "cast"
  );
  wireguardCredentials =
    require "AmneziaWG must pass credentials through systemd and refresh peer endpoints"
      (
        wireguard.systemd.services.wireguard-awg0.serviceConfig.LoadCredential
        == [ "private-key:/run/keys/awg0" ]
        && wireguard.systemd.services.wireguard-awg0-peer-peer-refresh.serviceConfig.Restart == "always"
        && builtins.elem "wireguard-awg0.service" wireguard.systemd.targets.wireguard-awg0.wants
      );
  qemuIdentityAndDevices = require "VM identity and device access must remain explicit" (
    vm.users.users.vm-example.uid == 2001
    && builtins.elem "/dev/kvm rw" vm.systemd.services."qemu-vm@".serviceConfig.DeviceAllow
    && builtins.elem "/dev/net/tun rw" vm.systemd.services."qemu-vm@example".serviceConfig.DeviceAllow
    &&
      vm.systemd.services."qemu-vm@example".unitConfig.RequiresMountsFor == [ "/var/lib/vms/example.raw" ]
  );
  qemuRejectsRoot = require "The VM service must reject root as its explicit UID" (
    lib.any (
      assertion:
      assertion.message == "vm-qemu invalid: uid must be an explicit positive integer"
      && !assertion.assertion
    ) invalidVM.assertions
  );
  pinnedInventory =
    require "Pinned bind sources must preserve the source inventory and idmapped mount target"
      (
        pinned.services.pinned-bind-sources.inventory."/run/container-bind-example/0" == "/srv/example"
        &&
          pinned.containers.example.bindMounts."/var/lib/example".hostPath == "/run/container-bind-example/0"
        && pinned.containers.example.bindMounts."/var/lib/example".mountPoint == "/var/lib/example:idmap"
        &&
          builtins.elem "/srv/example"
            pinned.systemd.services."container@example".unitConfig.RequiresMountsFor
      );
  credentialRestarts = require "Only consumers of a credential path should restart when it changes" (
    secrets.sops.secrets.example.restartUnits == [
      "consumer.service"
      "scalar.service"
    ]
    && secrets.sops.templates.example.restartUnits == [ "consumer.service" ]
    && secrets.sops.secrets.manual.restartUnits == [ "manual.service" ]
  );
  cacheCredentials =
    require "The cache must load runtime credentials and require signed Nix objects"
      (
        cache.systemd.services.nix-ci-cache.serviceConfig.LoadCredential == [ "identity:/run/keys/cache" ]
        && cache.nix.settings.require-sigs
        && cache.nix.settings.extra-substituters == [ "http://127.0.0.1:9999?priority=30" ]
      );
  cacheRejectsStoreIdentity = require "The cache identity must never be taken from the Nix store" (
    lib.any (
      assertion:
      assertion.message == "Cache credentials must be absolute runtime paths outside the Nix store."
      && !assertion.assertion
    ) invalidCache.assertions
  );
}
