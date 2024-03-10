{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.nixarr;
in {
  imports = [
    ./jellyfin
    ./ddns
    ./radarr
    ./lidarr
    ./readarr
    ./sonarr
    ./openssh
    ./prowlarr
    ./transmission
    ../util
  ];

  options.nixarr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Whether or not to enable the nixarr module. Has the following features:

        - **Run services through a VPN:** You can run any service that this module
          supports through a VPN, fx `nixarr.transmission.vpn.enable = true;`
        - **Automatic Directories, Users and Permissions:** The module automatically
          creates directories and users for your media library. It also sets sane
          permissions.
        - **State Management:** All services support state management and all state
          that they manage is located by default in `/data/.state/nixarr/*`
        - **Optional Automatic Port Forwarding:** This module has a UPNP support that
          lets services request ports from your router automatically, if you enable it.
      
        It is possible, _but not recommended_, to run the "*Arrs" behind a VPN,
        because it can cause rate limiting issues. Generally, you should use
        VPN on transmission and maybe jellyfin, depending on your setup.

        The following services are supported:

        - [Jellyfin](#nixarr.jellyfin.enable)
        - [Lidarr](#nixarr.lidarr.enable)
        - [Prowlarr](#nixarr.prowlarr.enable)
        - [Radarr](#nixarr.radarr.enable)
        - [Readarr](#nixarr.readarr.enable)
        - [Sonarr](#nixarr.sonarr.enable)
        - [Transmission](#nixarr.transmission.enable)

        Remember to read the options.
      '';
    };

    mediaDir = mkOption {
      type = types.path;
      default = "/data/media";
      example = "/home/user/nixarr";
      description = ''
        The location of the media directory for the services.
      '';
    };

    stateDir = mkOption {
      type = types.path;
      default = "/data/.state/nixarr";
      example = "/home/user/.local/share/nixarr";
      description = ''
        The location of the state directory for the services.
      '';
    };

    vpn = {
      enable = mkOption {
        type = types.bool;
        default = false;
        example = true;
        description = ''
          **Required options:** [`nixarr.vpn.wgConf`](#nixarr.vpn.wgconf)

          Whether or not to enable VPN support for the services that nixarr
          supports.
        '';
      };

      wgConf = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/data/.secret/vpn/wg.conf";
        description = "The path to the wireguard configuration file.";
      };

      vpnTestService = {
        enable = mkEnableOption ''
          the vpn test service. Useful for testing DNS leaks or if the VPN
          port forwarding works correctly.
        '';

        port = mkOption {
          type = with types; nullOr port;
          default = null;
          example = 58403;
          description = ''
            The port that netcat listens to on the vpn test service. If set to
            `null`, then netcat will not be started.
          '';
        };
      };

      openTcpPorts = mkOption {
        type = with types; listOf port;
        default = [];
        description = ''
          What TCP ports to allow traffic from. You might need this if you're
          port forwarding on your VPN provider and you're setting up services
          not covered in by this module that uses the VPN.
        '';
        example = [46382 38473];
      };

      openUdpPorts = mkOption {
        type = with types; listOf port;
        default = [];
        description = ''
          What UDP ports to allow traffic from. You might need this if you're
          port forwarding on your VPN provider and you're setting up services
          not covered in by this module that uses the VPN.
        '';
        example = [46382 38473];
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.vpn.enable -> cfg.vpn.wgConf != null;
        message = ''
          The nixarr.vpn.enable option requires the nixarr.vpn.wgConf option
          to be set, but it was not.
        '';
      }
    ];

    users.groups = {
      media = {};
      streamer = {};
      torrenter = {};
    };
    users.users = {
      streamer = {
        isSystemUser = true;
        group = "streamer";
      };
      torrenter = {
        isSystemUser = true;
        group = "torrenter";
      };
    };

    systemd.tmpfiles.rules = [
      # Media dirs
      "d '${cfg.mediaDir}'                      0775 root      media - -"
      "d '${cfg.mediaDir}/library'              0775 streamer  media - -"
      "d '${cfg.mediaDir}/library/shows'        0775 streamer  media - -"
      "d '${cfg.mediaDir}/library/movies'       0775 streamer  media - -"
      "d '${cfg.mediaDir}/library/music'        0775 streamer  media - -"
      "d '${cfg.mediaDir}/library/books'        0775 streamer  media - -"
      "d '${cfg.mediaDir}/torrents'             0755 torrenter media - -"
      "d '${cfg.mediaDir}/torrents/.incomplete' 0755 torrenter media - -"
      "d '${cfg.mediaDir}/torrents/.watch'      0755 torrenter media - -"
      "d '${cfg.mediaDir}/torrents/manual'      0755 torrenter media - -"
      "d '${cfg.mediaDir}/torrents/liadarr'     0755 torrenter media - -"
      "d '${cfg.mediaDir}/torrents/radarr'      0755 torrenter media - -"
      "d '${cfg.mediaDir}/torrents/sonarr'      0755 torrenter media - -"
      "d '${cfg.mediaDir}/torrents/readarr'     0755 torrenter media - -"
    ];

    # TODO: wtf to do about openports
    vpnnamespaces.wg = mkIf cfg.vpn.enable {
      enable = true;
      accessibleFrom = [
        "192.168.1.0/24"
        "127.0.0.1"
      ];
      wireguardConfigFile = cfg.vpn.wgConf;
    };

    # TODO: openports
    systemd.services.vpn-test-service = mkIf cfg.vpn.enable {
      enable = cfg.vpn.vpnTestService.enable;
      vpnconfinement = {
        enable = true;
        vpnnamespace = "wg";
      };

      script = let
        vpn-test = pkgs.writeShellApplication {
          name = "vpn-test";

          runtimeInputs = with pkgs; [util-linux unixtools.ping coreutils curl bash libressl netcat-gnu openresolv dig];

          text = ''
            cd "$(mktemp -d)"

            # Print resolv.conf
            echo "/etc/resolv.conf contains:"
            cat /etc/resolv.conf

            # Query resolvconf
            echo "resolvconf output:"
            resolvconf -l
            echo ""

            # Get ip
            echo "Getting IP:"
            curl -s ipinfo.io

            echo -ne "DNS leak test:"
            curl -s https://raw.githubusercontent.com/macvk/dnsleaktest/b03ab54d574adbe322ca48cbcb0523be720ad38d/dnsleaktest.sh -o dnsleaktest.sh
            chmod +x dnsleaktest.sh
            ./dnsleaktest.sh
          '' + (if cfg.vpn.vpnTestService.port != null then ''
            echo "starting netcat on port ${builtins.toString cfg.vpn.vpnTestService.port}:"
            nc -vnlpu ${builtins.toString cfg.vpn.vpnTestService.port}
          '' else "");
        };
      in "${vpn-test}/bin/vpn-test";

      bindsTo = ["netns@wg.service"];
      requires = ["network-online.target"];
      after = ["wg.service"];
      serviceConfig = {
        #User = "torrenter";
        NetworkNamespacePath = "/var/run/netns/wg";
        BindReadOnlyPaths = ["/etc/netns/wg/resolv.conf:/etc/resolv.conf:norbind" "/data/test.file:/etc/test.file:norbind"];
      };
    };
  };
}
