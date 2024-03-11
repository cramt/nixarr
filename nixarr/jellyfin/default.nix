{
  config,
  lib,
  ...
}:
let
  cfg = config.nixarr.jellyfin;
  defaultPort = 8096;
  nixarr = config.nixarr;
in with lib; {
  options.nixarr.jellyfin = {
    enable = mkEnableOption "the Jellyfin service.";

    stateDir = mkOption {
      type = types.path;
      default = "${nixarr.stateDir}/jellyfin";
      defaultText = literalExpression ''"''${nixarr.stateDir}/jellyfin"'';
      example = "/home/user/.local/share/nixarr/jellyfin";
      description = "The state directory for Jellyfin.";
    };

    vpn.enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        **Required options:** [`nixarr.vpn.enable`](#nixarr.vpn.enable)  
        **Conflicting options:** [`nixarr.jellyfin.expose.https.enable`](#nixarr.jellyfin.expose.https.enable)

        Route Jellyfin traffic through the VPN.
      '';
    };

    expose = {
      vpn = {
        enable = mkOption {
          type = types.bool;
          default = false;
          example = true;
          description = ''
            **Required options:** 
        
            - [`nixarr.jellyfin.vpn.enable`](#nixarr.jellyfin.vpn.enable)
            - [`nixarr.jellyfin.expose.vpn.port`](#nixarr.jellyfin.expose.vpn.port)
            - [`nixarr.jellyfin.expose.vpn.accessibleFrom`](#nixarr.jellyfin.expose.vpn.accessiblefrom)

            Expose the Jellyfin web service to the internet, allowing anyone to
            access it.

            **Warning:** Do _not_ enable this without setting up Jellyfin
            authentication through localhost first!
          '';
        };

        port = mkOption {
          type = with types; nullOr port;
          default = null;
          example = 12345;
          description = ''
            The port to access jellyfin on. Get this port from your VPN
            provider.
          '';
        };

        accessibleFrom = mkOption {
          type = with types; nullOr str;
          default = null;
          example = "jellyfin.airvpn.org";
          description = ''
            The IP or domain that Jellyfin should be able to be accessed from.
          '';
        };
      };

      https = {
        enable = mkOption {
          type = types.bool;
          default = false;
          example = true;
          description = ''
            **Required options:** 
        
            - [`nixarr.jellyfin.expose.https.acmeMail`](#nixarr.jellyfin.expose.https.acmemail)
            - [`nixarr.jellyfin.expose.https.domainName`](#nixarr.jellyfin.expose.https.domainname)

            **Conflicting options:** [`nixarr.jellyfin.vpn.enable`](#nixarr.jellyfin.vpn.enable)

            Expose the Jellyfin web service to the internet with https support,
            allowing anyone to access it.

            **Warning:** Do _not_ enable this without setting up Jellyfin
            authentication through localhost first!
          '';
        };

        upnp.enable = mkEnableOption "UPNP to try to open ports 80 and 443 on your router.";

        domainName = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "jellyfin.example.com";
          description = "The domain name to host Jellyfin on.";
        };

        acmeMail = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "mail@example.com";
          description = "The ACME mail required for the letsencrypt bot.";
        };
      };
    };
  };

  config =
    mkIf cfg.enable
    {
      assertions = [
        {
          assertion = cfg.vpn.enable -> nixarr.vpn.enable;
          message = ''
            The nixarr.jellyfin.vpn.enable option requires the
            nixarr.vpn.enable option to be set, but it was not.
          '';
        }
        {
          assertion = !(cfg.vpn.enable && cfg.expose.https.enable);
          message = ''
            The nixarr.jellyfin.vpn.enable option conflicts with the
            nixarr.jellyfin.expose.https.enable option. You cannot set both.
          '';
        }
        {
          assertion = cfg.expose.https.enable -> (
            (cfg.expose.https.domainName != null) && 
            (cfg.expose.https.acmeMail != null)
          );
          message = ''
            The nixarr.jellyfin.expose.https.enable option requires the
            following options to be set, but one of them were not:

            - nixarr.jellyfin.expose.domainName
            - nixarr.jellyfin.expose.acmeMail
          '';
        }
        {
          assertion = cfg.expose.vpn.enable -> (
            cfg.vpn.enable && 
            (cfg.expose.vpn.port != null) && 
            (cfg.expose.vpn.accessibleFrom != null)
          );
          message = ''
            The nixarr.jellyfin.expose.vpn.enable option requires the
            following options to be set, but one of them were not:

            - nixarr.jellyfin.vpn.enable
            - nixarr.jellyfin.expose.vpn.port
            - nixarr.jellyfin.expose.vpn.accessibleFrom
          '';
        }
      ];
    
      systemd.tmpfiles.rules = [
        "d '${cfg.stateDir}' 0700 streamer root - -"
      ];

      services.jellyfin = {
        enable = cfg.enable;
        user = "streamer";
        group = "streamer";
        logDir = "${cfg.stateDir}/log";
        cacheDir = "${cfg.stateDir}/cache";
        dataDir = "${cfg.stateDir}/data";
        configDir = "${cfg.stateDir}/config";
      };

      networking.firewall = mkIf cfg.expose.https.enable {
        allowedTCPPorts = [80 443];
      };

      util-nixarr.upnp = mkIf cfg.expose.https.upnp.enable {
        enable = true;
        openTcpPorts = [80 443];
      };

      services.nginx = mkMerge [
        (mkIf (cfg.expose.https.enable || cfg.vpn.enable) {
          enable = true;

          recommendedTlsSettings = true;
          recommendedOptimisation = true;
          recommendedGzipSettings = true;
        })
        (mkIf cfg.expose.https.enable {
          virtualHosts."${builtins.replaceStrings ["\n"] [""] cfg.expose.https.domainName}" = {
            enableACME = true;
            forceSSL = true;
            locations."/" = {
              recommendedProxySettings = true;
              proxyWebsockets = true;
              proxyPass = "http://127.0.0.1:${builtins.toString defaultPort}";
            };
          };
        })
        (mkIf cfg.vpn.enable {
          virtualHosts."127.0.0.1:${builtins.toString defaultPort}" = mkIf cfg.vpn.enable {
            listen = [
              {
                addr = "0.0.0.0";
                port = defaultPort;
              }
            ];
            locations."/" = {
              recommendedProxySettings = true;
              proxyWebsockets = true;
              proxyPass = "http://192.168.15.1:${builtins.toString defaultPort}";
            };
          };
        })
        (mkIf cfg.expose.vpn.enable {
          virtualHosts."${builtins.toString cfg.expose.vpn.accessibleFrom}:${builtins.toString cfg.expose.vpn.port}" = {
            enableACME = true;
            forceSSL = true;
            locations."/" = {
              recommendedProxySettings = true;
              proxyWebsockets = true;
              proxyPass = "http://192.168.15.1:${builtins.toString defaultPort}";
            };
          };
        })
      ];

      security.acme = mkIf cfg.expose.https.enable {
        acceptTerms = true;
        defaults.email = cfg.expose.https.acmeMail;
      };

      # Enable and specify VPN namespace to confine service in.
      systemd.services.jellyfin.vpnconfinement = mkIf cfg.vpn.enable {
        enable = true;
        vpnnamespace = "wg";
      };

      # Port mappings
      # TODO: openports if expose.vpn
      vpnnamespaces.wg = mkIf cfg.vpn.enable {
        portMappings = [{ From = defaultPort; To = defaultPort; }];
      };
    };
}
