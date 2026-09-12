# shellcheck shell=bash
# alwayswork · headless / always-on power policy.
#
# A worker node should never sleep. Every behaviour here is configurable
# under always_on.* and defaults to safe, reversible settings.

power_logind_conf()   { printf '%s\n' /etc/systemd/logind.conf.d/99-alwayswork.conf; }
power_nm_conf()       { printf '%s\n' /etc/NetworkManager/conf.d/99-alwayswork.conf; }
power_watchdog_conf() { printf '%s\n' /etc/systemd/system.conf.d/99-alwayswork.conf; }

power_apply() {
  if ! cfg_bool '.always_on.enabled' true; then
    info "always_on is disabled; leaving power management to the system"
    return 0
  fi

  if cfg_bool '.always_on.disable_suspend' true; then
    log "power: masking sleep, suspend and hibernate targets"
    run systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
  fi

  if cfg_bool '.always_on.ignore_lid_switch' true || cfg_bool '.always_on.ignore_idle' true; then
    log "power: writing logind policy (effective next boot)"
    {
      printf '[Login]\n'
      if cfg_bool '.always_on.ignore_idle' true; then
        printf 'IdleAction=ignore\n'
      fi
      if cfg_bool '.always_on.ignore_lid_switch' true; then
        printf 'HandleLidSwitch=ignore\n'
        printf 'HandleLidSwitchExternalPower=ignore\n'
        printf 'HandleLidSwitchDocked=ignore\n'
      fi
      printf 'HandleSuspendKey=ignore\n'
      printf 'HandleHibernateKey=ignore\n'
      if cfg_bool '.always_on.ignore_power_key' false; then
        printf 'HandlePowerKey=ignore\n'
      fi
    } | aw_write "$(power_logind_conf)"
  fi

  if cfg_bool '.always_on.wifi_powersave_off' true && [[ -d /etc/NetworkManager ]]; then
    log "power: disabling Wi-Fi powersave"
    {
      printf '[connection]\n'
      printf 'wifi.powersave = 2\n'
    } | aw_write "$(power_nm_conf)"
    run systemctl reload NetworkManager 2>/dev/null || true
  fi

  if cfg_bool '.always_on.watchdog' false; then
    if [[ -e /dev/watchdog || -e /dev/watchdog0 ]]; then
      log "power: enabling systemd hardware watchdog"
      {
        printf '[Manager]\n'
        printf 'RuntimeWatchdogSec=%s\n' "$(cfg_get '.always_on.watchdog_sec' 20)"
      } | aw_write "$(power_watchdog_conf)"
      run systemctl daemon-reexec
    else
      warn "watchdog requested but no /dev/watchdog device is present"
    fi
  fi

  ok "always-on policy applied"
}

power_unapply() {
  log "power: restoring default power management"
  run systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
  run rm -f "$(power_logind_conf)"
  run rm -f "$(power_nm_conf)"
  run rm -f "$(power_watchdog_conf)"
  ok "power policy removed (reboot to fully restore)"
}

power_status() {
  local masked
  masked="$(systemctl is-enabled sleep.target 2>/dev/null || echo unknown)"
  kv "always_on" "$(cfg_bool '.always_on.enabled' true && echo enabled || echo disabled)"
  kv "sleep.target" "$masked"
  if [[ -f "$(power_logind_conf)" ]]; then kv "logind policy" "present"; else kv "logind policy" "absent"; fi
  if [[ -f "$(power_nm_conf)" ]]; then kv "wifi powersave" "disabled"; else kv "wifi powersave" "default"; fi
  if [[ -f "$(power_watchdog_conf)" ]]; then kv "watchdog" "configured"; else kv "watchdog" "off"; fi
}

# One issue per line (empty when clean) — used by doctor.
power_audit() {
  cfg_bool '.always_on.enabled' true || return 0
  if [[ "$(systemctl is-enabled sleep.target 2>/dev/null || true)" != "masked" ]]; then
    printf '%s\n' "sleep.target is not masked (the box may suspend and drop agents)"
  fi
}
