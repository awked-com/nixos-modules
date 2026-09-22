{
  config,
  lib,
  ...
}:

{
  config = lib.mkIf (config.services.cast.enable && config.services.cast.audio.enable) {
    services.pipewire = {
      enable = true;
      audio.enable = true;
      wireplumber.enable = true;
    };

    systemd.user.services.wireplumber = {
      environment = {
        HOME = "%t/wireplumber";
        XDG_STATE_HOME = "%t/wireplumber";
      };
      serviceConfig.RuntimeDirectory = "wireplumber";
    };

    security.rtkit.enable = true;
  };
}
