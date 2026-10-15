{ self }: { config, lib, pkgs, ... }: let
  cfg = config.services.mayfly;
in {
  options.services.mayfly = {
    enable = lib.mkEnableOption "slopbox temporary file host";
    package = lib.mkOption { type = lib.types.package; default = self.packages.${pkgs.stdenv.hostPlatform.system}.default; description = "slopbox executable package."; };
    url = lib.mkOption { type = lib.types.str; description = "Public HTTPS base URL."; };
    port = lib.mkOption { type = lib.types.port; default = 8791; description = "Loopback HTTP port."; };
  };
  config = lib.mkIf cfg.enable {
    users.users.mayfly = { isSystemUser = true; group = "mayfly"; home = "/var/lib/mayfly"; };
    users.groups.mayfly = {};
    systemd.services.mayfly = {
      description = "slopbox temporary file host";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = { MAYFLY_DATA = "/var/lib/mayfly"; MAYFLY_URL = cfg.url; MAYFLY_PORT = toString cfg.port; ERL_FLAGS = "+S 4:4"; };
      serviceConfig = {
        User = "mayfly";
        Group = "mayfly";
        ExecStart = lib.getExe cfg.package;
        WorkingDirectory = "/var/lib/mayfly";
        Restart = "on-failure";
        RestartSec = 3;
        StateDirectory = "mayfly";
        StateDirectoryMode = "0700";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        MemoryMax = "1G";
        TasksMax = 256;
        LimitNOFILE = 4096;
      };
    };
  };
}
