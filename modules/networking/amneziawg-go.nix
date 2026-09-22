{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;
  interfaces = config.networking.amneziawg-go.interfaces;

  awg = lib.getExe pkgs.amneziawg-tools;
  amneziawgGo = lib.getExe pkgs.amneziawg-go;
  ip = lib.getExe' pkgs.iproute2 "ip";
  sleep = lib.getExe' pkgs.coreutils "sleep";
  timeout = "${lib.getExe' pkgs.coreutils "timeout"} --kill-after=5s 60s";

  sandbox = {
    DynamicUser = true;
    User = "amneziawg";
    # Stopping one unit must not remove other tunnels' shared UAPI sockets.
    RuntimeDirectory = "amneziawg";
    RuntimeDirectoryMode = "0700";
    RuntimeDirectoryPreserve = true;
    UMask = "0077";
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectProc = "invisible";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
      "AF_NETLINK"
    ];
    MemorySwapMax = 0;
    TasksMax = 512;
  };

  awgSet = args: "${timeout} ${awg} ${lib.escapeShellArgs ([ "set" ] ++ args)}";

  mkEndpointCommand =
    interfaceName: interface: peer:
    if interface.endpointIPv4Only then
      ''
        endpoint=${lib.escapeShellArg peer.endpoint}
        if ! addresses="$(${timeout} ${lib.getExe' pkgs.getent "getent"} ahostsv4 "''${endpoint%:*}")" || [[ -z "$addresses" ]]; then
          echo "No IPv4 address found for $endpoint" >&2
          exit 1
        fi
        read -r address _ <<< "$addresses"
        ${
          awgSet [
            interfaceName
            "peer"
            peer.publicKey
            "endpoint"
          ]
        } "$address:''${endpoint##*:}"
      ''
    else
      awgSet [
        interfaceName
        "peer"
        peer.publicKey
        "endpoint"
        peer.endpoint
      ];

  mkPeerCommand =
    interfaceName: interface: peer:
    awgSet (
      [
        interfaceName
        "peer"
        peer.publicKey
      ]
      ++ lib.optionals (peer.presharedKeyFile != null) [
        "preshared-key"
        "peer-${peer.name}"
      ]
      ++
        lib.optionals
          (
            peer.endpoint != null && !interface.endpointIPv4Only && interface.dynamicEndpointRefreshSeconds == 0
          )
          [
            "endpoint"
            peer.endpoint
          ]
      ++ lib.optionals (peer.persistentKeepalive != null) [
        "persistent-keepalive"
        (toString peer.persistentKeepalive)
      ]
      ++ [
        "allowed-ips"
        (lib.concatStringsSep "," peer.allowedIPs)
      ]
    )
    + lib.optionalString (
      peer.endpoint != null && interface.endpointIPv4Only && interface.dynamicEndpointRefreshSeconds == 0
    ) "\n${mkEndpointCommand interfaceName interface peer}";

  refreshServiceName = interfaceName: peer: "wireguard-${interfaceName}-peer-${peer.name}-refresh";

  refreshPeers =
    interface:
    if interface.dynamicEndpointRefreshSeconds != 0 then
      builtins.filter (peer: peer.endpoint != null) interface.peers
    else
      [ ];

  mkRefreshService =
    interfaceName: interface: peer:
    let
      seconds = interface.dynamicEndpointRefreshSeconds;
    in
    lib.nameValuePair (refreshServiceName interfaceName peer) {
      description = "AmneziaWG peer endpoint refresh - ${interfaceName} - ${peer.name}";
      requires = [ "wireguard-${interfaceName}.service" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "wireguard-${interfaceName}.service"
      ];
      partOf = [ "wireguard-${interfaceName}.service" ];
      environment.WG_ENDPOINT_RESOLUTION_RETRIES = "0";
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = sandbox // {
        Type = "simple";
        CapabilityBoundingSet = [ ];
        PrivateDevices = true;
        MemoryMax = "128M";
        Restart = "always";
        RestartSec = seconds;
        TimeoutStopSec = 15;
      };
      script = ''
        while true; do
          # DNS can fail during activation; retain the last endpoint.
          if ! (
            ${mkEndpointCommand interfaceName interface peer}
          ); then
            echo "Endpoint refresh failed; retrying in ${toString seconds}s" >&2
          fi
          ${sleep} ${toString seconds}
        done
      '';
    };

  mkInterfaceService =
    interfaceName: interface:
    let
      refreshServices = map (peer: "${refreshServiceName interfaceName peer}.service") (
        refreshPeers interface
      );
      capabilities = [
        "CAP_NET_ADMIN"
      ]
      ++ lib.optional (interface.listenPort > 0 && interface.listenPort < 1024) "CAP_NET_BIND_SERVICE";
    in
    lib.nameValuePair "wireguard-${interfaceName}" {
      description = "AmneziaWG userspace tunnel - ${interfaceName}";
      after = [
        "network-pre.target"
        "sops-install-secrets.service"
      ];
      wants = [ "network.target" ] ++ refreshServices;
      before = [ "network.target" ];
      environment.WG_ENDPOINT_RESOLUTION_RETRIES = "0";
      unitConfig = {
        StartLimitIntervalSec = 0;
        Upholds = refreshServices;
      };
      serviceConfig = sandbox // {
        Type = "exec";
        CapabilityBoundingSet = capabilities;
        AmbientCapabilities = capabilities;
        DevicePolicy = "closed";
        DeviceAllow = [ "/dev/net/tun rw" ];
        MemoryHigh = "512M";
        MemoryMax = "1G";
        LoadCredential = [
          "private-key:${interface.privateKeyFile}"
        ]
        ++ lib.optional (interface.extraConfigFile != null) "config:${interface.extraConfigFile}"
        ++ map (peer: "peer-${peer.name}:${peer.presharedKeyFile}") (
          builtins.filter (peer: peer.presharedKeyFile != null) interface.peers
        );
        ExecStart = "${amneziawgGo} -f ${lib.escapeShellArg interfaceName}";
        Restart = "always";
        RestartSec = 5;
        TimeoutStartSec = 90;
        TimeoutStopSec = 15;
      };
      postStart = ''
        cd "$CREDENTIALS_DIRECTORY"
        while [ ! -S "/run/amneziawg/${interfaceName}.sock" ]; do
          ${sleep} 0.1
        done
        ${lib.optionalString (interface.extraConfigFile != null) ''
          if ! ${timeout} ${awg} setconf ${lib.escapeShellArg interfaceName} config 2>/dev/null; then
            echo ${lib.escapeShellArg "Failed to load AmneziaWG configuration from ${interface.extraConfigFile}"} >&2
            exit 1
          fi
        ''}
        ${awgSet [
          interfaceName
          "private-key"
          "private-key"
          "listen-port"
          (toString interface.listenPort)
          "fwmark"
          interface.fwMark
        ]}
        ${lib.concatMapStringsSep "\n" (mkPeerCommand interfaceName interface) interface.peers}
        ${ip} link set up dev ${lib.escapeShellArg interfaceName}
      '';
    };

  mkInterfaceTarget =
    interfaceName: interface:
    let
      units = [
        "wireguard-${interfaceName}.service"
      ]
      ++ map (peer: "${refreshServiceName interfaceName peer}.service") (refreshPeers interface);
    in
    lib.nameValuePair "wireguard-${interfaceName}" {
      description = "AmneziaWG userspace tunnel - ${interfaceName}";
      wantedBy = [ "multi-user.target" ];
      wants = units;
      after = units;
    };
in
{
  options.networking.amneziawg-go.interfaces = mkOption {
    default = { };
    description = ''
      AmneziaWG userspace tunnels. Addresses, MTU, routes and firewall policy
      are configured separately by the host. Unit names are wireguard-<interface>.
    '';
    type = types.attrsOf (
      types.submodule {
        options = {
          privateKeyFile = mkOption {
            type = types.str;
            description = "Runtime path to the private key, outside the Nix store.";
          };
          listenPort = mkOption {
            type = types.port;
            default = 0;
            description = "UDP listen port; zero selects a random port.";
          };
          fwMark = mkOption {
            type = types.str;
            default = "off";
            description = "Firewall mark for outgoing packets, as a decimal or hexadecimal string, or off.";
          };
          extraConfigFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Runtime path to an awg INI configuration with [Interface] and optional
              [Peer] sections, such as a SOPS template containing secret parameters.
              Loaded before the declared interface options and peers.
            '';
          };
          endpointIPv4Only = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Resolve declared peer endpoints to IPv4 when they are first configured
              and during refresh. Failed lookups retry without falling back to IPv6.
              Endpoints supplied only through extraConfigFile are not affected.
            '';
          };
          dynamicEndpointRefreshSeconds = mkOption {
            type = types.ints.unsigned;
            default = 0;
            description = ''
              Interval for re-resolving configured peer endpoints; zero disables refresh.
              When enabled, each peer's endpoint is first resolved independently after
              tunnel startup, so failed DNS lookups do not prevent other peers connecting.
            '';
          };
          peers = mkOption {
            default = [ ];
            type = types.listOf (
              types.submodule {
                options = {
                  name = mkOption {
                    type = types.strMatching "[a-zA-Z0-9_-]+";
                    description = "Unique peer name within the interface, used in refresh unit names.";
                  };
                  publicKey = mkOption {
                    type = types.str;
                    description = "Peer public key.";
                  };
                  presharedKeyFile = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = "Optional runtime path to the preshared key, outside the Nix store.";
                  };
                  allowedIPs = mkOption {
                    type = types.listOf types.str;
                    description = "IPv4 or IPv6 prefixes accepted from and sent to this peer; does not install routes.";
                  };
                  endpoint = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    description = "Peer endpoint as host:port or [IPv6]:port; omit for roaming peers.";
                  };
                  persistentKeepalive = mkOption {
                    type = types.nullOr (
                      types.either (types.ints.between 0 65535) (
                        types.addCheck (types.strMatching "(0|[1-9][0-9]{0,4})-(0|[1-9][0-9]{0,4})") (
                          value:
                          let
                            bounds = map builtins.fromJSON (lib.splitString "-" value);
                            lower = builtins.head bounds;
                            upper = builtins.elemAt bounds 1;
                          in
                          lower <= upper && upper <= 65535
                        )
                      )
                    );
                    default = null;
                    description = "Keepalive interval in seconds, or a randomized min-max range; zero disables keepalives.";
                  };
                };
              }
            );
            description = "Tunnel peers.";
          };
        };
      }
    );
  };

  config = lib.mkIf (interfaces != { }) {
    assertions = lib.mapAttrsToList (name: interface: {
      assertion =
        builtins.match "[a-zA-Z0-9_-]{1,15}" name != null
        &&
          builtins.length (lib.unique (map (peer: peer.name) interface.peers))
          == builtins.length interface.peers;
      message = "AmneziaWG interface ${name} needs a valid interface name (1-15 letters, digits, underscores or hyphens) and unique peer names.";
    }) interfaces;

    environment.systemPackages = [ pkgs.amneziawg-tools ];
    systemd.services =
      lib.mapAttrs' mkInterfaceService interfaces
      // lib.listToAttrs (
        lib.concatLists (
          lib.mapAttrsToList (
            interfaceName: interface: map (mkRefreshService interfaceName interface) (refreshPeers interface)
          ) interfaces
        )
      );
    systemd.targets = lib.mapAttrs' mkInterfaceTarget interfaces;
  };
}
