# NixOS modules

Reusable NixOS services with caller-supplied configuration. This flake contains
no host inventory, credentials, secret files, or deployment commands.

| Export | Purpose |
| --- | --- |
| `nixosModules.cast` | AirPlay and Miracast receiver, direct KMS display ownership, audio and network isolation |
| `nixosModules.amneziawg-go` | Hardened userspace AmneziaWG tunnels with credential files and endpoint refresh |
| `nixosModules.sops-credential-restarts` | Restart services consuming changed SOPS secrets or templates through `LoadCredential` |
| `nixosModules.nix-ci-cache` | Loopback Nix cache serving encrypted objects with `nix-ci-worker` |
| `lib.qemuVM { ... }` | QEMU/KVM service with explicit UID, disk paths, TAP interfaces and serial console |
| `lib.pinnedBindSources { ... }` | Pinned directory bind mounts for NixOS containers |
| `lib.networkingValidation` | MAC address, port-list and uniqueness validation for network declarations |

Modules are opt-in. There is no default module enabling unrelated services.
Linux x86-64 and AArch64 are evaluated against the pinned Nixpkgs revision.

## Inputs and packages

Add the flake to your configuration and let its Nixpkgs input follow yours:

```nix
inputs.nixos-modules.url = "github:awked-com/nixos-modules";
inputs.nixos-modules.inputs.nixpkgs.follows = "nixpkgs";
```

The cast stack requires the patched UxPlay and MiracleCast packages from
[`nixpkgs-patches`](https://github.com/awked-com/nixpkgs-patches). Its display
lifecycle and Wi-Fi control options depend on those patches. The same overlay
provides the AmneziaWG fixes used with this module. Supply it from the consumer:

```nix
inputs.nixpkgs-patches.url = "github:awked-com/nixpkgs-patches";
inputs.nixpkgs-patches.inputs.nixpkgs.follows = "nixpkgs";

# In a NixOS configuration module:
nixpkgs.overlays = [ inputs.nixpkgs-patches.overlays.default ];
```

The cache and pinned bind helpers come from
[`packages`](https://github.com/awked-com/packages). Add its overlay with the same
Nixpkgs `follows` relationship when using those modules, or supply equivalent
packages. The cache module also accepts `services.nix-ci-cache.package`.

## Cast receiver

```nix
imports = [ inputs.nixos-modules.nixosModules.cast ];

services.cast = {
  enable = true;
  friendlyName = "Living room display";
  wirelessInterface = "wlan0";
  airplay.interfaces = [ "lan0" ];
};
users.users.cast.uid = 2000;
```

Choose a free, stable UID. Wi-Fi must support P2P with wpa_supplicant, and the
display must support the configured DRM/KMS pipeline. Hardware decoding, display
connector, framebuffer and plane selection are configurable. The module owns
the local display session and disables its first virtual-terminal getty.
It uses systemd-networkd and nftables rules; configure your network
interfaces and firewall backend accordingly. AirPlay is exposed on the named
interfaces; Miracast uses isolated P2P interfaces.

## AmneziaWG

```nix
imports = [ inputs.nixos-modules.nixosModules.amneziawg-go ];

networking.amneziawg-go.interfaces.awg0 = {
  privateKeyFile = "/run/keys/awg0";
  listenPort = 51820;
  dynamicEndpointRefreshSeconds = 30;
  peers = [{
    name = "peer";
    publicKey = "REPLACE_WITH_PEER_PUBLIC_KEY";
    allowedIPs = [ "2001:db8::/64" ];
    endpoint = "vpn.example.test:51820";
  }];
};
```

Supply runtime private-key files, addresses, MTU, routes and firewall policy.
`extraConfigFile` accepts runtime AmneziaWG configuration, including obfuscation
parameters. Failed DNS refreshes retain the previous peer endpoint.

## QEMU VM

```nix
imports = [
  (inputs.nixos-modules.lib.qemuVM {
    name = "example";
    description = "Example virtual machine";
    uid = 2001;
    vcpu = 2;
    memory = 1024;
    volumes = [{ image = "/var/lib/vms/example.raw"; }];
    interfaces = [{ ifname = "tap-example"; mac = "02:00:00:00:00:01"; }];
  })
];
```

Create raw disk images and their parent directories separately. The service
changes each image's ownership to its VM user and mode to `0600`. Select an
unused UID and interface name, and configure TAP networking separately. KVM is
required. The serial console helper is `/run/qemu-vm/example/console`.

## Pinned container mounts

```nix
imports = [
  (inputs.nixos-modules.lib.pinnedBindSources {
    name = "example";
    sources."/var/lib/example" = {
      path = "/srv/example";
      create = true;
      user = "example";
      group = "example";
      mode = "0700";
    };
  })
];
```

Define the NixOS container and any named users/groups separately. Users and
groups need fixed numeric IDs. The module pins source directory descriptors in
the container service's private runtime directory, adds idmapped bind mounts,
and releases the pins when the container stops. It exposes the original paths
under `services.pinned-bind-sources.inventory` for consumers doing storage audits.

## Credential restarts and the cache

Import `nixosModules.sops-credential-restarts` alongside
[`sops-nix`](https://github.com/Mic92/sops-nix). It derives default `restartUnits`
from enabled systemd services whose `LoadCredential` entries use a secret or
template's absolute path. An explicit `restartUnits` value still overrides it.

```nix
imports = [ inputs.nixos-modules.nixosModules.nix-ci-cache ];
services.nix-ci-cache = {
  enable = true;
  repository = "ghcr.io/example/cache";
  port = 9999;
  identityFile = "/run/keys/cache";
  publicKey = "REPLACE_WITH_CACHE_SIGNING_PUBLIC_KEY";
};
```

The caller installs the age identity at runtime, orders its provider before
`nix-ci-cache.service`, and restarts the service when it changes. No secret
provider is required by the cache module. The SOPS restart helper can handle
credential changes when using SOPS.

## Checks

```sh
nix eval --json .#lib.evaluationTests.x86_64-linux
nix eval --json .#lib.evaluationTests.aarch64-linux
nix flake check
```

Evaluation checks exercise enabled service configuration, credential wiring,
VM identity/device access, container mount inventory and SOPS restart selection.
They use synthetic host values. The helper executables are substituted with
evaluation fixtures where only their paths are needed. These checks do not run
privileged mounts, KVM, network tunnels, AirPlay, Miracast or physical displays;
those require Linux and appropriate hardware.
