{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.zenos.maintenance;

  # Directory paths
  stateDir = "/System/ZenOS/Maintenance";
  timestampFile = "${stateDir}/last_maintenance";
  nagTimestampFile = "${stateDir}/last_nag";
  firstRunFile = "${stateDir}/first_run_seen";

  # --- Helper: Send Notification from Root to Active User ---
  # UPDATED: Full paths for all binaries to prevent "command not found" in activation scripts
  notifyScript = pkgs.writeShellScript "zenos-notify-helper" ''
    SUMMARY=$1
    BODY=$2

    # Tools
    LOGINCTL="${pkgs.systemd}/bin/loginctl"
    GREP="${pkgs.gnugrep}/bin/grep"
    AWK="${pkgs.gawk}/bin/awk"
    HEAD="${pkgs.coreutils}/bin/head"
    ID="${pkgs.coreutils}/bin/id"
    SUDO="${pkgs.sudo}/bin/sudo"
    NOTIFY="${pkgs.libnotify}/bin/notify-send"

    # 1. Find the primary user session on seat0
    SESSION_ID=$($LOGINCTL list-sessions | $GREP seat0 | $AWK '{print $1}' | $HEAD -n1)

    if [ -n "$SESSION_ID" ]; then
      USER_ID=$($LOGINCTL show-session -p User --value "$SESSION_ID")
      USER_NAME=$($ID -un "$USER_ID")
      
      # 2. Critical Environment Variables for GUI interaction
      USER_DBUS="/run/user/$USER_ID/bus"
      USER_RUNTIME="/run/user/$USER_ID"
      
      if [ -S "$USER_DBUS" ]; then
        # 3. Execute notify-send as the user with full context
        $SUDO -u "$USER_NAME" \
          DISPLAY=:0 \
          DBUS_SESSION_BUS_ADDRESS="unix:path=$USER_DBUS" \
          XDG_RUNTIME_DIR="$USER_RUNTIME" \
          $NOTIFY "$SUMMARY" "$BODY" \
          -i zenos-symbolic \
          -u critical \
          -a "ZenOS Maintenance"
        
        # Return exit code of notify-send
        exit $?
      fi
    fi
    exit 1
  '';

  # --- 1. The Core Logic (Daily Run) ---
  maintenanceCore = pkgs.writeShellScript "zenos-maintenance-core" ''
    set -e

    # Frequency Check (Once every 24h)
    if [ -f "${timestampFile}" ]; then
      LAST_RUN=$(stat -c %Y "${timestampFile}")
      NOW=$(date +%s)
      AGE=$((NOW - LAST_RUN))
      if [ "$AGE" -lt 86400 ]; then
        echo "Skipping: Maintenance already performed today."
        exit 0
      fi
    fi

    ${notifyScript} "System Maintenance" "Starting daily update & cleanup..."
    echo "Starting ZenOS Maintenance..."

    # Update System
    if [ -n "${cfg.flakePath}" ] && [ -f "${cfg.flakePath}/flake.nix" ]; then
      ${pkgs.nix}/bin/nix flake update --flake "${cfg.flakePath}"
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake "${cfg.flakePath}"
    else
      ${pkgs.nix}/bin/nix-channel --update
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --upgrade
    fi

    # Cleanup
    ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 7d
    ${pkgs.nix}/bin/nix-store --optimise

    # Timestamp
    mkdir -p ${stateDir}
    touch ${timestampFile}
    chmod 644 ${timestampFile}

    ${notifyScript} "System Maintenance" "Daily maintenance complete."
    echo "ZenOS Maintenance Complete."
  '';

  # --- 2. Shutdown Cleanup Script (Safe) ---
  shutdownCleanupScript = pkgs.writeShellScript "zenos-shutdown-cleanup" ''
    echo "Running safe shutdown cleanup..."
    ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 7d
    ${pkgs.nix}/bin/nix-store --optimise
  '';

  # --- 3. Wrappers & Checkers ---
  maintenanceWrapper = pkgs.writeShellScript "zenos-maintenance-wrapper" ''
    ${pkgs.systemd}/bin/systemd-inhibit \
      --what="sleep:shutdown:idle" \
      --who="ZenOS Maintenance" \
      --why="Performing daily system updates" \
      --mode="block" \
      ${maintenanceCore}
  '';

  idleCheckScript = pkgs.writeShellScript "zenos-idle-check" ''
    if [ -f "${timestampFile}" ]; then
      LAST_RUN=$(stat -c %Y "${timestampFile}")
      NOW=$(date +%s)
      if [ $((NOW - LAST_RUN)) -lt 86400 ]; then exit 0; fi
    fi

    SESSION=$(${pkgs.systemd}/bin/loginctl list-sessions --no-legend | grep seat0 | awk '{print $1}' | head -n1)
    if [ -z "$SESSION" ]; then exit 0; fi

    IS_IDLE=$(${pkgs.systemd}/bin/loginctl show-session -p IdleHint --value "$SESSION")
    if [ "$IS_IDLE" != "yes" ]; then exit 0; fi

    IDLE_SINCE=$(${pkgs.systemd}/bin/loginctl show-session -p IdleSinceHintMonotonic --value "$SESSION")
    UPTIME_SEC=$(cat /proc/uptime | awk '{print $1}')
    NOW_MONO=$(echo "$UPTIME_SEC * 1000000" | ${pkgs.bc}/bin/bc | cut -d. -f1)

    if [ $((NOW_MONO - IDLE_SINCE)) -gt $((3600 * 1000000)) ]; then
      ${pkgs.systemd}/bin/systemctl start zenos-maintenance.service
    fi
  '';

  # --- 4. The Watchdog (Nag) ---
  nagScript = pkgs.writeShellScript "zenos-maintenance-nag" ''
    mkdir -p ${stateDir}

    # -- A. Fresh Install / Intro Check --
    if [ ! -f "${timestampFile}" ]; then
      
      # If we haven't shown the "First Time" message yet...
      if [ ! -f "${firstRunFile}" ]; then
        ${pkgs.libnotify}/bin/notify-send \
          "ZenOS Maintenance" \
          "Automatic maintenance is active. It will run daily when the device is idle." \
          -i zenos-symbolic -u critical -a "ZenOS System"
          
        # Mark as seen so we don't spam this message on service restart
        touch "${firstRunFile}"
        
        # Touch nag timestamp to start the 7-day grace period
        touch "${nagTimestampFile}"
        
        exit 0
      fi
      
      LAST_RUN=0
    else
      LAST_RUN=$(stat -c %Y "${timestampFile}")
    fi

    # -- B. Regular Overdue Check --
    NOW=$(date +%s)

    # Check if 7 days overdue
    if [ $((NOW - LAST_RUN)) -le 604800 ]; then exit 0; fi

    # Check Nag Frequency (Weekly Limit)
    if [ -f "${nagTimestampFile}" ]; then
      LAST_NAG=$(stat -c %Y "${nagTimestampFile}")
      if [ $((NOW - LAST_NAG)) -lt 604800 ]; then exit 0; fi
    fi

    ${pkgs.libnotify}/bin/notify-send \
      "Maintenance Overdue" \
      "System hasn't updated in >7 days. Please leave device idle for 1 hour." \
      -i zenos-symbolic -u critical -a "ZenOS System"
      
    touch "${nagTimestampFile}"
  '';

in
{
  options.zenos.maintenance = {
    enable = lib.mkEnableOption "ZenOS Automatic Maintenance";
    nag = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
    };
    dates = lib.mkOption {
      type = lib.types.str;
      default = "03:00";
    };
    flakePath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos";
    };
  };

  config = lib.mkIf cfg.enable {

    # --- Feature: Activation Check (Rebuild Trigger) ---
    system.activationScripts.zenosFirstRunCheck = ''
      # Only trigger if we haven't seen the first run file yet
      if [ ! -f "${firstRunFile}" ] && [ "${toString cfg.nag.enable}" = "1" ]; then
        # UPDATED: Use && operator. Only create files if notification SUCCEEDS.
        # This prevents marking as "seen" if the notification fails silently.
        if ${notifyScript} "ZenOS Maintenance" "Automatic maintenance is active. It will run daily when the device is idle."; then
            mkdir -p ${stateDir}
            touch "${firstRunFile}"
            touch "${nagTimestampFile}"
        else
            echo "ZenOS Maintenance: Notification failed. Will retry on next login."
        fi
      fi
    '';

    # --- Services ---
    systemd.services.zenos-maintenance = {
      description = "ZenOS System Update";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = maintenanceWrapper;
        CPUSchedulingPolicy = "idle";
      };
    };

    systemd.timers.zenos-maintenance = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.dates;
        Persistent = false;
        Unit = "zenos-maintenance.service";
      };
    };

    systemd.services.zenos-maintenance-on-sleep = {
      description = "ZenOS Update (Sleep Hook)";
      before = [
        "sleep.target"
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
      ];
      wantedBy = [
        "sleep.target"
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = maintenanceCore;
        TimeoutSec = "900";
      };
    };

    systemd.services.zenos-shutdown-cleanup = {
      description = "ZenOS Shutdown Garbage Collection";
      wantedBy = [
        "poweroff.target"
        "reboot.target"
        "halt.target"
      ];
      before = [
        "poweroff.target"
        "reboot.target"
        "halt.target"
        "shutdown.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = shutdownCleanupScript;
        TimeoutSec = "120";
      };
    };

    systemd.services.zenos-maintenance-idle-check = {
      description = "Idle Check Trigger";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = idleCheckScript;
      };
      path = [
        pkgs.gawk
        pkgs.bc
        pkgs.systemd
      ];
    };

    systemd.timers.zenos-maintenance-idle-check = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15min";
        OnUnitActiveSec = "15min";
        Unit = "zenos-maintenance-idle-check.service";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0775 root users -"
    ];

    systemd.user.services.zenos-maintenance-nag = lib.mkIf cfg.nag.enable {
      description = "Check ZenOS Maintenance Status";
      script = "${nagScript}";
      serviceConfig = {
        Type = "oneshot";
        PassEnvironment = "DISPLAY DBUS_SESSION_BUS_ADDRESS";
      };
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
    };

    systemd.user.timers.zenos-maintenance-nag = lib.mkIf cfg.nag.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnStartupSec = "10s";
        OnUnitActiveSec = "6h";
      };
    };

    environment.systemPackages = [
      pkgs.libnotify
      pkgs.bc
      pkgs.sudo
    ];
  };
}
