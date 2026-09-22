{
  config,
  lib,
  ...
}:

let
  cfg = config.services.cast;
  inherit (lib) mkEnableOption mkOption types;
in
{
  imports = [
    ./audio.nix
    ./display
    ./airplay.nix
    ./miracast.nix
    ./networking.nix
  ];

  options.services.cast = {
    enable = mkEnableOption "the cast receiver stack";

    user = mkOption {
      type = types.str;
      default = "cast";
      description = "Owner of the cast receiver processes.";
    };

    group = mkOption {
      type = types.str;
      default = "cast";
      description = "Group for cast receiver processes and state.";
    };

    friendlyName = mkOption {
      type = types.str;
      default = "NixOS Cast";
      description = "Name advertised over AirPlay and Miracast.";
    };

    audio.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable AirPlay and Miracast audio playback.";
    };

    wirelessInterface = mkOption {
      type = types.strMatching "[a-zA-Z0-9_.-]{1,15}";
      default = "wlan0";
      description = "Wireless interface used for MiracleCast P2P.";
    };

    graphics = {
      videoDecoder = mkOption {
        type = types.str;
        default = "decodebin3";
        description = "GStreamer H.264 decoder used by the AirPlay and Miracast receivers.";
      };

      extraPackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = "Hardware-acceleration packages for the receiver GPU.";
      };

      vaapiDriver = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "LIBVA driver, or null for the system default.";
      };

      videoCaps = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "GStreamer caps between the decoder and sink; null uses receiver defaults.";
      };
    };

    display = {
      connectorName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "DRM connector for power control; null auto-detects it.";
      };

      framebuffer = mkOption {
        type = types.str;
        default = "/sys/class/graphics/fb0/blank";
        description = "Framebuffer blanking path used for display power.";
      };

      driver = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "DRM driver for kmssink; null lets GStreamer choose.";
      };

      connectorId = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "DRM connector ID for kmssink.";
      };

      planeId = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "DRM plane ID for kmssink.";
      };
    };

    airplay = {
      interfaces = mkOption {
        type = types.listOf (types.strMatching "[a-zA-Z0-9_.-]{1,15}");
        description = "Interfaces allowed to discover and connect to the AirPlay receiver.";
      };

      port = mkOption {
        type = types.port;
        default = 7000;
        description = "UxPlay base TCP/UDP port.";
      };

      mode = mkOption {
        type = types.str;
        default = "1920x1080@60";
        description = "Preferred AirPlay display mode.";
      };

      framerate = mkOption {
        type = types.ints.positive;
        default = 60;
        description = "Maximum AirPlay video frame rate.";
      };
    };

    miraclecast = {
      supportedResolutions = mkOption {
        type = types.str;
        default = "00000180,00000000,00000000";
        description = "Resolution list for the MiracleCast sink.";
      };

      logLevel = mkOption {
        type = types.enum [
          "error"
          "warning"
          "notice"
          "info"
          "debug"
        ];
        default = "debug";
        description = "MiracleCast Wi-Fi manager log level.";
      };

      routeTable = mkOption {
        type = types.ints.between 1 252;
        default = 149;
        description = "Policy-routing table for MiracleCast P2P traffic.";
      };

      routingPriority = mkOption {
        type = types.ints.between 1 32763;
        default = 14900;
        description = "Priority for MiracleCast P2P routing rules.";
      };

      routingMark = mkOption {
        type = types.ints.between 1 4294967295;
        default = 149;
        description = "Packet mark for MiracleCast RTSP traffic.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.airplay.interfaces != [ ];
        message = "services.cast.airplay.interfaces must name at least one trusted interface";
      }
      {
        assertion = config.users.users.${cfg.user}.uid != null;
        message = "services.cast.user (${cfg.user}) must have a fixed UID";
      }
      {
        assertion = cfg.airplay.port <= 65533;
        message = "services.cast.airplay.port must leave room for UxPlay's two additional ports";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = lib.mkDefault true;
      group = lib.mkDefault cfg.group;
      linger = true;
      extraGroups = lib.mkAfter (
        [
          "render"
          "video"
        ]
        ++ lib.optional cfg.audio.enable "audio"
      );
    };
    users.groups.${cfg.group} = lib.mkDefault { };

    hardware.graphics = {
      enable = true;
      extraPackages = lib.mkAfter cfg.graphics.extraPackages;
    };
  };
}
