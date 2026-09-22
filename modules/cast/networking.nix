{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.cast;
  castUid = config.users.users.${cfg.user}.uid;
  p2pInterface = cfg.wirelessInterface;
  wireless = config.networking.wireless;
  hardening = import ./hardening.nix;
  miracleRouting = pkgs.writeShellApplication {
    name = "miracle-routing";
    runtimeInputs = [ pkgs.iproute2 ];
    text = ''
      route_table=${toString cfg.miraclecast.routeTable}
      routing_mark=${toString cfg.miraclecast.routingMark}
      mark_priority=${toString cfg.miraclecast.routingPriority}
      cast_uid=${toString castUid}

      remove_rule() {
        while ip -4 rule del priority "$mark_priority" uidrange "$cast_uid-$cast_uid" \
          ipproto tcp dport 7236 table "$route_table" >/dev/null 2>&1
        do
          :
        done
        while ip -4 rule del priority "$mark_priority" fwmark "$routing_mark" \
          table "$route_table" >/dev/null 2>&1
        do
          :
        done
      }

      case "''${1:-}" in
        start)
          remove_rule
          # Select the source before connect(), ahead of output hooks.
          ip -4 rule add priority "$mark_priority" uidrange "$cast_uid-$cast_uid" \
            ipproto tcp dport 7236 table "$route_table"
          ip -4 rule add priority "$mark_priority" fwmark "$routing_mark" \
            table "$route_table"
          ;;
        stop)
          remove_rule
          ;;
        *)
          echo "usage: $0 start|stop" >&2
          exit 2
          ;;
      esac
    '';
  };
  waitForWiphy = pkgs.writeShellApplication {
    name = "wait-for-wiphy";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      interface=${lib.escapeShellArg p2pInterface}
      attempt=0

      until readlink --canonicalize-existing \
        "/sys/class/net/$interface/phy80211" >/dev/null 2>&1
      do
        attempt=$((attempt + 1))

        if (( attempt >= 100 )); then
          echo "$interface wiphy did not become ready within 10 seconds" >&2
          exit 1
        fi

        sleep 0.1
      done
    '';
  };
in
lib.mkIf cfg.enable {
  boot.kernel.sysctl."net.core.rmem_max" = 33554432;

  networking.wireless = {
    enable = lib.mkDefault true;
    autoDetectInterfaces = lib.mkDefault false;
    interfaces = [ p2pInterface ];
  };

  networking.wireless.extraConfig = lib.mkAfter ''
    driver_param=p2p_device=1
    persistent_reconnect=1
    config_methods=push_button
    pbc_in_m1=1
  '';

  assertions = [
    {
      assertion = wireless.enable && builtins.elem p2pInterface wireless.interfaces;
      message = "services.cast requires its wirelessInterface in networking.wireless.interfaces with wpa_supplicant enabled";
    }
  ];

  systemd.services."wpa_supplicant-${p2pInterface}" = {
    requires = [ "miracle-wpa.service" ];
    after = [ "miracle-wpa.service" ];
    # NixOS has no option for the global control socket.
    script = lib.mkForce (
      "exec "
      + lib.escapeShellArgs (
        [
          "${pkgs.wpa_supplicant}/bin/wpa_supplicant"
          "-i"
          p2pInterface
          "-g"
          "/run/wpa_supplicant/global"
          "-G"
          "wpa_supplicant"
          "-s"
          "-D"
          wireless.driver
        ]
        ++ lib.optional wireless.dbusControlled "-u"
        ++ (
          if wireless.allowAuxiliaryImperativeNetworks then
            [
              "-c"
              "/etc/wpa_supplicant/imperative.conf"
              "-I"
              "/etc/wpa_supplicant/nixos.conf"
            ]
          else
            [
              "-c"
              "/etc/wpa_supplicant/nixos.conf"
            ]
        )
        ++ lib.concatMap (file: [
          "-I"
          file
        ]) wireless.extraConfigFiles
      )
    );
    serviceConfig = {
      BindPaths = [ "/run/miracle-wpa" ];
      RuntimeDirectoryMode = "0770";
      UMask = lib.mkForce "0007";
    };
  };

  systemd.services.miracle-wpa = {
    description = "Prepare the shared MiracleCast WPA socket directory";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      Group = "wpa_supplicant";
      RuntimeDirectory = "miracle-wpa";
      RuntimeDirectoryMode = "0770";
      RuntimeDirectoryPreserve = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
    };
  };

  systemd.network.config.networkConfig = {
    ManageForeignRoutingPolicyRules = false;
  };

  systemd.network.networks."10-miraclecast" = {
    matchConfig.Name = "p2p-*";
    linkConfig = {
      ActivationPolicy = "manual";
      RequiredForOnline = "no";
    };
    networkConfig = {
      DHCP = "no";
      IPv6AcceptRA = false;
      KeepConfiguration = "yes";
      LinkLocalAddressing = "no";
    };
  };

  networking.firewall = {
    extraReversePathFilterRules = ''
      iifname "p2p-*" accept
    '';
    extraInputRules = ''
      iifname "p2p-*" tcp dport 7236 accept
      iifname "p2p-*" udp dport 7236 accept
      iifname "p2p-*" meta nfproto ipv4 udp sport 67 udp dport 68 accept
    '';
  };

  networking.nftables.tables.cast-transit = {
    family = "inet";
    content = ''
      chain forward {
        type filter hook forward priority filter - 25; policy accept;
        iifname "p2p-*" drop
        oifname "p2p-*" drop
      }
    '';
  };

  systemd.services.miracle-routing = {
    description = "MiracleCast P2P policy routing";
    unitConfig.ConditionPathExists = [ "!/run/display/active-uxplay" ];
    serviceConfig = hardening.daemon // {
      Type = "oneshot";
      RemainAfterExit = true;
      Slice = "miraclecast.slice";
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
      ExecStart = "${miracleRouting}/bin/miracle-routing start";
      ExecStop = "${miracleRouting}/bin/miracle-routing stop";
      RestrictAddressFamilies = [
        "AF_NETLINK"
        "AF_UNIX"
      ];
      TimeoutStopSec = "10s";
    };
  };

  systemd.services.miracle-wifid = rec {
    description = "MiracleCast Wi-Fi Direct manager";
    requires = [ "miracle-wpa.service" ];
    bindsTo = [ "miracle-routing.service" ];
    after =
      bindsTo
      ++ requires
      ++ [
        "dbus.service"
        "wpa_supplicant-${cfg.wirelessInterface}.service"
      ];
    wants = [ "wpa_supplicant-${cfg.wirelessInterface}.service" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      ConditionPathExists = [ "!/run/display/active-uxplay" ];
      StartLimitIntervalSec = 0;
      Upholds = [ "miracle-sink.service" ];
    };
    path = [
      pkgs.miraclecast
      pkgs.iw
      pkgs.wpa_supplicant
    ];
    environment = {
      MIRACLECAST_WPA_CONTROL = "/run/wpa_supplicant/global";
      MIRACLECAST_WPA_CLIENT_DIR = "/run/miracle-wpa";
    };
    serviceConfig = hardening.daemon // {
      Type = "dbus";
      Slice = "miraclecast.slice";
      BusName = "org.freedesktop.miracle.wifi";
      CapabilityBoundingSet = [
        "CAP_NET_ADMIN"
        "CAP_NET_BIND_SERVICE"
        "CAP_NET_RAW"
      ];
      SupplementaryGroups = [ "wpa_supplicant" ];
      ExecStartPre = [ "${waitForWiphy}/bin/wait-for-wiphy" ];
      ExecStart = lib.escapeShellArgs [
        "${pkgs.miraclecast}/bin/miracle-wifid"
        "--interface"
        p2pInterface
        "--friendly-name"
        cfg.friendlyName
        "--route-table"
        (toString cfg.miraclecast.routeTable)
        "--log-level"
        cfg.miraclecast.logLevel
      ];
      NotifyAccess = "main";
      ReadWritePaths = [
        "/run/miracle"
        "-/proc/sys/net/ipv4/conf/${p2pInterface}/drop_unicast_in_l2_multicast"
        "/run/miracle-wpa"
      ];
      Restart = "always";
      RestartSec = "2s";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
        "AF_PACKET"
        "AF_UNIX"
      ];
      RuntimeDirectory = "miracle";
      RuntimeDirectoryMode = "0700";
      TimeoutStopSec = "10s";
      WatchdogSec = "30s";
    };
  };

  networking.iproute2 = {
    enable = lib.mkDefault true;
    rttablesExtraConfig = lib.mkAfter "${toString cfg.miraclecast.routeTable} miraclecast\n";
  };
}
