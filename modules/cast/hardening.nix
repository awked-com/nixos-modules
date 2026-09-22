rec {
  daemon = {
    KeyringMode = "private";
    LockPersonality = true;
    NoNewPrivileges = true;
    PrivateMounts = true;
    PrivateTmp = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectProc = "invisible";
    ProtectSystem = "strict";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "~@clock"
      "~@cpu-emulation"
      "~@debug"
      "~@module"
      "~@obsolete"
      "~@raw-io"
      "~@reboot"
      "~@swap"
    ];
    UMask = "0077";
  };

  mediaClient =
    builtins.removeAttrs daemon [
      "KeyringMode"
      "PrivateMounts"
      "ProtectProc"
      "RestrictRealtime"
      "SystemCallFilter"
    ]
    // {
      ProtectHome = "read-only";
    };
}
