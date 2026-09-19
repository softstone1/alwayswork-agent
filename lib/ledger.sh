# shellcheck shell=bash
# alwayswork · footprint ledger: record every change before it is made, so
# `aw decommission` can replay it in reverse and hand back the machine as it
# was. Contract: docs/DECOMMISSION.md.
#
# Sourced by bin/alwayswork after lib/distro.sh; never executed directly.
# Needs from the sourcer: log/info/ok/warn/err, have, run, ensure_dir,
# DRY_RUN, AW_STATE, AW_ROOT, AW_ETC (lib/core.sh); pkg_is_installed and
# pkg_remove (lib/distro.sh); fw_backend/fw_active (lib/firewall.sh) for the
# firewall kind.
#
# Storage: $AW_STATE/ledger.jsonl, one JSON object per line, append-only.
# Prior file contents and firewall exports live in $AW_STATE/ledger.d/<sha>.
#
# Every entry carries {t, by, kind, ...}. `by` is whoever made the change:
# "install", the aw command name ("bootstrap", "provision", ...) or the
# capability id while its install hook runs (AW_LEDGER_BY, set by callers).
#
# One entry per (kind, identity): a recorder that finds an entry for the
# same file/package/unit already in the ledger records nothing, so `aw apply`
# converging every tick never grows the ledger and the FIRST entry — the
# state before AlwaysWork ever touched the thing — is what restore returns
# to.

ledger_file() { printf '%s\n' "$AW_STATE/ledger.jsonl"; }
ledger_dir()  { printf '%s\n' "$AW_STATE/ledger.d"; }

# ledger_record <kind> [field...] — append one entry. A field is key=value
# (a JSON string) or key:=json (a raw JSON value: true, false, null, number).
# Honours DRY_RUN: prints the entry and writes nothing.
ledger_record() {
  local kind="$1"; shift
  local -a args=()
  local f k v
  for f in "$@"; do
    if [[ "$f" == *:=* ]]; then
      k="${f%%:=*}"; v="${f#*:=}"
      args+=(--argjson "$k" "$v")
    else
      k="${f%%=*}"; v="${f#*=}"
      args+=(--arg "$k" "$v")
    fi
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { warn "ledger: bad field name '$k'"; return 1; }
  done
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    %s[dry-run]%s ledger %s %s\n' "$C_DIM" "$C_RESET" "$kind" "$*" >&2
    return 0
  fi
  local line
  line="$(jq -cn --argjson t "$(date +%s)" --arg by "${AW_LEDGER_BY:-aw}" --arg kind "$kind" \
    "${args[@]}" '$ARGS.named')" || { warn "ledger: could not encode a $kind entry"; return 1; }
  ensure_dir "$AW_STATE"
  printf '%s\n' "$line" >> "$(ledger_file)"
}

# ledger_has <kind> [field value] — true when an entry of this kind (and,
# when given, with .field == value) is already recorded.
ledger_has() {
  local kind="$1" field="${2:-}" val="${3:-}" f
  f="$(ledger_file)"
  [[ -s "$f" ]] || return 1
  jq -e -n --arg k "$kind" --arg f "$field" --arg v "$val" \
    '[inputs | select(.kind == $k and ($f == "" or .[$f] == $v))] | length > 0' \
    "$f" >/dev/null 2>&1
}

# Keep a copy of a file under ledger.d, named by its sha256. Prints the sha.
_ledger_keep_copy() {
  local path="$1" sha
  sha="$(sha256sum "$path" | cut -d' ' -f1)"
  if [[ "$DRY_RUN" != "1" ]]; then
    ensure_dir "$(ledger_dir)"
    [[ -f "$(ledger_dir)/$sha" ]] || cp -p "$path" "$(ledger_dir)/$sha"
  fi
  printf '%s\n' "$sha"
}

# --- recorders: capture prior state, then append ---------------------------

# ledger_file_before <path> — a file we are about to write or replace.
ledger_file_before() {
  local path="$1" sha
  ledger_has file path "$path" && return 0
  if [[ -L "$path" ]]; then
    ledger_record file "path=$path" "existed:=true" "link=$(readlink "$path")"
  elif [[ -f "$path" ]]; then
    sha="$(_ledger_keep_copy "$path")" || return 1
    ledger_record file "path=$path" "existed:=true" "sha=$sha"
  elif [[ -e "$path" ]]; then
    # A directory or device where we expected a file: recorded, left alone.
    ledger_record file "path=$path" "existed:=true"
  else
    ledger_record file "path=$path" "existed:=false"
  fi
}

# ledger_unit <name> — a systemd unit we are about to install. When the unit
# already existed its prior state is kept so restore can put it back instead
# of deleting it (the file entry recorded alongside restores the content).
ledger_unit() {
  local name="$1" existed=false en=false ac=false
  ledger_has unit name "$name" && return 0
  [[ -f "/etc/systemd/system/$name" ]] && existed=true
  if have systemctl; then
    systemctl is-enabled --quiet "$name" 2>/dev/null && en=true
    systemctl is-active --quiet "$name" 2>/dev/null && ac=true
  fi
  ledger_record unit "name=$name" "existed:=$existed" "priorEnabled:=$en" "priorActive:=$ac"
}

# ledger_pkg_before <pkg...> — packages we are about to install (names as
# the caller passes them, i.e. Arch names; pkg_remove translates on restore).
ledger_pkg_before() {
  local p prior
  for p in "$@"; do
    ledger_has pkg name "$p" && continue
    # Subshell: on an unsupported distro pkg_is_installed dies; here that is
    # just "not installed" — pkg_install itself refuses right after.
    if ( pkg_is_installed "$p" ) >/dev/null 2>&1; then prior=true; else prior=false; fi
    ledger_record pkg "name=$p" "priorInstalled:=$prior"
  done
}

# ledger_service_before <unit> — a service whose enabled/active state we are
# about to change (sshd, docker, ...).
ledger_service_before() {
  local unit="$1" en=false ac=false
  ledger_has service name "$unit" && return 0
  if have systemctl; then
    systemctl is-enabled --quiet "$unit" 2>/dev/null && en=true
    systemctl is-active --quiet "$unit" 2>/dev/null && ac=true
  fi
  ledger_record service "name=$unit" "priorEnabled:=$en" "priorActive:=$ac"
}

# ledger_firewall_before — the firewall as it was before fw_ensure. The
# backend's own export is kept under ledger.d for the operator; the files
# the backend actually loads its state from are recorded as `file` entries
# AFTER the firewall entry, so on the reverse replay they are written back
# first and the firewall entry then reloads (or disables) the backend.
ledger_firewall_before() {
  local backend active=false snap sha
  ledger_has firewall && return 0
  backend="$(fw_backend)"
  fw_active && active=true
  snap="$(mktemp "${TMPDIR:-/tmp}/aw-fw.XXXXXX")" || return 1
  case "$backend" in
    ufw)       ufw status verbose > "$snap" 2>/dev/null || true ;;
    nft)       nft list ruleset > "$snap" 2>/dev/null || true ;;
    firewalld) { printf 'default-zone=%s\n' "$(firewall-cmd --get-default-zone 2>/dev/null || true)"
                 firewall-cmd --list-all 2>/dev/null || true; } > "$snap" ;;
    *)         : > "$snap" ;;
  esac
  sha="$(_ledger_keep_copy "$snap")"
  rm -f "$snap"
  ledger_record firewall "backend=$backend" "priorActive:=$active" "priorRules=$sha" || return 1
  local f
  case "$backend" in
    ufw)
      for f in /etc/default/ufw /etc/ufw/ufw.conf /etc/ufw/user.rules /etc/ufw/user6.rules; do
        ledger_file_before "$f" || true
      done ;;
    firewalld)
      ledger_file_before /etc/firewalld/firewalld.conf || true ;;
  esac
}

# ledger_ssh_before — sshd as it was before apply_ssh_policy. The drop-ins
# we write go through aw_write (file entries); `dropins` names the pattern
# restore also sweeps so nothing of ours is left in sshd_config.d.
ledger_ssh_before() {
  local en=false ac=false
  ledger_has ssh && return 0
  if have systemctl; then
    systemctl is-enabled --quiet sshd 2>/dev/null && en=true
    systemctl is-active --quiet sshd 2>/dev/null && ac=true
  fi
  ledger_record ssh "unit=sshd" "priorEnabled:=$en" "priorActive:=$ac" \
    "dropins=/etc/ssh/sshd_config.d/*alwayswork*.conf"
}

# ledger_hostname_before — the hostname before provisioning renames the box.
ledger_hostname_before() {
  ledger_has hostname && return 0
  ledger_record hostname "prior=$(hostname)"
}

# ledger_dir_before <path> — a directory we are about to create.
ledger_dir_before() {
  local path="$1" existed=false
  ledger_has dir path "$path" && return 0
  [[ -d "$path" ]] && existed=true
  ledger_record dir "path=$path" "existed:=$existed"
}

# --- restore ---------------------------------------------------------------

# Progress lives in the decommission marker (.restored: ledger line numbers
# already undone) so an interrupted restore resumes where it stopped.
_ledger_marker() {
  if have decommission_marker; then decommission_marker
  else printf '%s\n' "$AW_STATE/decommission.json"; fi
}

_ledger_restored_list() {
  local m; m="$(_ledger_marker)"
  [[ -f "$m" ]] || return 0
  jq -r '(.restored // [])[]' "$m" 2>/dev/null || true
}

_ledger_mark_restored() {
  local n="$1" m
  [[ "$DRY_RUN" == "1" ]] && return 0
  m="$(_ledger_marker)"
  ensure_dir "$AW_STATE"
  if [[ -f "$m" ]]; then
    jq --argjson n "$n" '.restored = ((.restored // []) + [$n] | unique)' "$m" > "$m.tmp" \
      && mv "$m.tmp" "$m"
  else
    jq -n --argjson n "$n" --argjson t "$(date +%s)" \
      '{started_at:$t, phases:[], plane:"unknown", complete:false, restored:[$n]}' > "$m"
  fi
  chmod 600 "$m" 2>/dev/null || true
}

# systemctl through run(), skipped when there is no systemd to talk to
# (containers, the test harness) — the dry-run plan is still printed.
_ledger_systemctl() {
  if [[ "$DRY_RUN" != "1" ]] && ! have systemctl; then return 0; fi
  run systemctl "$@"
}

# _ledger_unit_is_self <unit> — true when this very process runs inside that
# unit (the agent acting on a drain order, or the provision service resuming
# at boot). Stopping it would kill the restore halfway: such a unit is only
# disabled, and the process exits on its own when the run is over.
_ledger_unit_is_self() {
  [[ -n "${INVOCATION_ID:-}" ]] || return 1
  have systemctl || return 1
  [[ "$(systemctl show -p InvocationID --value "$1" 2>/dev/null)" == "$INVOCATION_ID" ]]
}

_ledger_unit_down() {
  local unit="$1"
  if _ledger_unit_is_self "$unit"; then
    info "ledger: $unit is running this restore; disabled, stops when done"
    _ledger_systemctl disable "$unit" || true
  else
    _ledger_systemctl disable --now "$unit" || true
  fi
}

# _ledger_service_restore <unit> <priorEnabled> <priorActive> [reload]
_ledger_service_restore() {
  local unit="$1" en="$2" ac="$3" reload="${4:-0}"
  if [[ "$en" == "true" ]]; then _ledger_systemctl enable "$unit" || return 1
  else _ledger_systemctl disable "$unit" || true; fi
  if [[ "$ac" == "true" ]]; then
    if (( reload )); then _ledger_systemctl restart "$unit" || return 1
    else _ledger_systemctl start "$unit" || return 1; fi
  else
    _ledger_unit_down "$unit"
  fi
}

_ledger_undo_file() {
  local n="$1" line="$2" path existed sha link copy cur
  IFS=$'\t' read -r path existed sha link < <(jq -r '[.path, (.existed|tostring), (.sha // ""), (.link // "")] | @tsv' <<<"$line")
  [[ -n "$path" ]] || return 1
  if [[ "$existed" != "true" ]]; then
    info "restore #$n file: delete $path"
    run rm -f "$path"
    return
  fi
  if [[ -n "$link" ]]; then
    info "restore #$n file: relink $path -> $link"
    run ln -sfn "$link" "$path"
    return
  fi
  if [[ -z "$sha" ]]; then
    info "restore #$n file: $path existed before; left in place"
    return 0
  fi
  copy="$(ledger_dir)/$sha"
  if [[ -f "$path" ]]; then
    cur="$(sha256sum "$path" | cut -d' ' -f1)"
    [[ "$cur" == "$sha" ]] && { info "restore #$n file: $path already has its prior content"; return 0; }
  fi
  if [[ ! -f "$copy" && "$DRY_RUN" != "1" ]]; then
    warn "restore #$n file: no saved copy for $path ($sha); left in place"
    return 1
  fi
  info "restore #$n file: write back prior $path"
  ensure_dir "$(dirname "$path")"
  run cp -p "$copy" "$path"
}

_ledger_undo_unit() {
  local n="$1" line="$2" name existed en ac
  IFS=$'\t' read -r name existed en ac < <(jq -r '[.name, (.existed // false | tostring), (.priorEnabled // false | tostring), (.priorActive // false | tostring)] | @tsv' <<<"$line")
  [[ -n "$name" ]] || return 1
  if [[ "$existed" == "true" ]]; then
    info "restore #$n unit: $name existed before; restoring enabled=$en active=$ac"
    _ledger_service_restore "$name" "$en" "$ac" 1 || return 1
    return 0
  fi
  info "restore #$n unit: disable and remove $name"
  _ledger_unit_down "$name"
  run rm -f "/etc/systemd/system/$name"
  _ledger_systemctl daemon-reload || true
}

_ledger_undo_pkg() {
  local n="$1" line="$2" name prior
  IFS=$'\t' read -r name prior < <(jq -r '[.name, (.priorInstalled // false | tostring)] | @tsv' <<<"$line")
  [[ -n "$name" ]] || return 1
  if [[ "$prior" == "true" ]]; then
    info "restore #$n pkg: $name was already installed; kept"
    return 0
  fi
  if [[ "$DRY_RUN" != "1" ]] && ! ( pkg_is_installed "$name" ) >/dev/null 2>&1; then
    info "restore #$n pkg: $name already absent"
    return 0
  fi
  info "restore #$n pkg: remove $name"
  pkg_remove "$name"
}

_ledger_undo_service() {
  local n="$1" line="$2" name en ac
  IFS=$'\t' read -r name en ac < <(jq -r '[.name, (.priorEnabled // false | tostring), (.priorActive // false | tostring)] | @tsv' <<<"$line")
  [[ -n "$name" ]] || return 1
  info "restore #$n service: $name enabled=$en active=$ac"
  _ledger_service_restore "$name" "$en" "$ac"
}

_ledger_undo_firewall() {
  local n="$1" line="$2" backend active sha copy
  IFS=$'\t' read -r backend active sha < <(jq -r '[(.backend // "none"), (.priorActive // false | tostring), (.priorRules // "")] | @tsv' <<<"$line")
  copy="$(ledger_dir)/$sha"
  case "$backend" in
    ufw)
      if [[ "$DRY_RUN" != "1" ]] && ! have ufw; then info "restore #$n firewall: ufw is gone; nothing to restore"; return 0; fi
      if [[ "$active" == "true" ]]; then
        info "restore #$n firewall: reload ufw with its prior rules"
        run ufw --force reload || return 1
      else
        info "restore #$n firewall: ufw was inactive; disable"
        run ufw --force disable || return 1
      fi ;;
    nft)
      if [[ "$DRY_RUN" != "1" ]] && ! have nft; then info "restore #$n firewall: nft is gone; nothing to restore"; return 0; fi
      info "restore #$n firewall: load the prior nftables ruleset"
      run nft flush ruleset || return 1
      if [[ -s "$copy" || "$DRY_RUN" == "1" ]]; then run nft -f "$copy" || return 1; fi ;;
    firewalld)
      if [[ "$active" == "true" ]]; then
        info "restore #$n firewall: reload firewalld with its prior config"
        run firewall-cmd --reload || return 1
      else
        info "restore #$n firewall: firewalld was inactive; disable"
        _ledger_systemctl disable --now firewalld || true
      fi ;;
    *) info "restore #$n firewall: no backend was recorded; nothing to do" ;;
  esac
}

_ledger_undo_ssh() {
  local n="$1" line="$2" unit en ac glob f
  IFS=$'\t' read -r unit en ac glob < <(jq -r '[(.unit // "sshd"), (.priorEnabled // false | tostring), (.priorActive // false | tostring), (.dropins // "")] | @tsv' <<<"$line")
  info "restore #$n ssh: remove our drop-ins; $unit enabled=$en active=$ac"
  if [[ -n "$glob" ]]; then
    # shellcheck disable=SC2086,SC2231
    for f in $glob; do
      [[ -e "$f" ]] || continue
      run rm -f "$f"
    done
  fi
  _ledger_service_restore "$unit" "$en" "$ac" 1
}

_ledger_undo_hostname() {
  local n="$1" line="$2" prior
  prior="$(jq -r '.prior // ""' <<<"$line")"
  [[ -n "$prior" ]] || return 1
  info "restore #$n hostname: $prior"
  if have hostnamectl || [[ "$DRY_RUN" == "1" ]]; then run hostnamectl set-hostname "$prior"
  else run hostname "$prior"; fi
}

_ledger_undo_dir() {
  local n="$1" line="$2" path existed
  IFS=$'\t' read -r path existed < <(jq -r '[.path, (.existed // false | tostring)] | @tsv' <<<"$line")
  [[ -n "$path" ]] || return 1
  if [[ "$existed" == "true" ]]; then
    info "restore #$n dir: $path existed before; kept"
    return 0
  fi
  if [[ ! -d "$path" ]]; then
    info "restore #$n dir: $path already gone"
    return 0
  fi
  if [[ -n "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" && "$DRY_RUN" != "1" ]]; then
    info "restore #$n dir: $path is not empty; left in place"
    return 0
  fi
  info "restore #$n dir: remove $path"
  run rmdir "$path"
}

_ledger_undo() {
  local kind="$1" line="$2" n="$3"
  case "$kind" in
    file)     _ledger_undo_file "$n" "$line" ;;
    unit)     _ledger_undo_unit "$n" "$line" ;;
    pkg)      _ledger_undo_pkg "$n" "$line" ;;
    service)  _ledger_undo_service "$n" "$line" ;;
    firewall) _ledger_undo_firewall "$n" "$line" ;;
    ssh)      _ledger_undo_ssh "$n" "$line" ;;
    hostname) _ledger_undo_hostname "$n" "$line" ;;
    dir)      _ledger_undo_dir "$n" "$line" ;;
    *)        warn "restore #$n: unknown ledger kind '$kind'"; return 1 ;;
  esac
}

# ledger_restore [--keep-foundation] — replay the ledger in reverse. Entries
# already marked restored are skipped; a failing entry is logged and the
# replay continues. Returns non-zero when any entry failed. With
# --keep-foundation the firewall and ssh kinds and everything the installer
# and the core capability recorded stay: the hardened base and aw remain.
ledger_restore() {
  local keep_foundation=0 a f
  for a in "$@"; do
    case "$a" in
      --keep-foundation) keep_foundation=1 ;;
      *) die "ledger_restore: unknown option: $a" ;;
    esac
  done
  f="$(ledger_file)"
  if [[ ! -s "$f" ]]; then
    info "ledger: nothing recorded; nothing to restore"
    return 0
  fi
  local -a lines=()
  mapfile -t lines < "$f"
  local done_list=" " n
  while IFS= read -r n; do
    [[ -n "$n" ]] && done_list="${done_list}${n} "
  done < <(_ledger_restored_list)
  local i line kind by restored=0 failed=0 kept=0 skipped=0 how=""
  local jq_n="" jq_line=""
  (( keep_foundation )) && how=" (keeping the foundation)"
  log "ledger: restoring ${#lines[@]} recorded change(s) in reverse$how"
  for (( i = ${#lines[@]} - 1; i >= 0; i-- )); do
    n=$(( i + 1 )); line="${lines[i]}"
    [[ -n "$line" ]] || continue
    if [[ "$done_list" == *" $n "* ]]; then skipped=$(( skipped + 1 )); continue; fi
    kind="$(jq -r '.kind // ""' <<<"$line" 2>/dev/null || true)"
    by="$(jq -r '.by // ""' <<<"$line" 2>/dev/null || true)"
    if [[ -z "$kind" ]]; then
      warn "ledger: line $n is not a ledger entry; skipping"
      failed=$(( failed + 1 )); continue
    fi
    if (( keep_foundation )); then
      case "$kind" in
        firewall|ssh) info "restore #$n $kind: kept (--keep-foundation)"; kept=$(( kept + 1 )); continue ;;
        service)
          # sshd's enabled/active state is part of the SSH hardening too.
          case "$(jq -r '.name // ""' <<<"$line")" in
            ssh|sshd|ssh.service|sshd.service)
              info "restore #$n $kind: sshd kept (--keep-foundation)"; kept=$(( kept + 1 )); continue ;;
          esac ;;
      esac
      case "$by" in
        install|core) info "restore #$n $kind: kept (foundation, by $by)"; kept=$(( kept + 1 )); continue ;;
      esac
    fi
    # The replay itself runs on jq: if the installer brought it, it goes
    # last, after every other entry has been undone and marked.
    if [[ "$kind" == "pkg" && "$(jq -r '.name // ""' <<<"$line")" == "jq" ]]; then
      jq_n="$n"; jq_line="$line"; continue
    fi
    if _ledger_undo "$kind" "$line" "$n"; then
      _ledger_mark_restored "$n"
      restored=$(( restored + 1 ))
    else
      err "restore #$n $kind: failed; continuing with the rest"
      failed=$(( failed + 1 ))
    fi
  done
  if [[ -n "$jq_n" ]]; then
    # Marked before it is removed: once jq is gone the marker cannot be
    # updated. A failed removal is loud; the operator finishes by hand.
    _ledger_mark_restored "$jq_n"
    if _ledger_undo pkg "$jq_line" "$jq_n"; then restored=$(( restored + 1 ))
    else err "restore #$jq_n pkg: jq could not be removed; remove it by hand"; failed=$(( failed + 1 )); fi
  fi
  _LEDGER_RESTORE_FAILED="$failed"
  info "ledger: $restored restored, $skipped already done, $kept kept, $failed failed"
  (( failed == 0 ))
}

# ledger_self_remove — the last step of a full restore: the agent removes
# itself, from the copy of its code this process already holds. Refuses
# outside /opt and under the test harness unless AW_LEDGER_ALLOW_SELF_REMOVE=1
# says otherwise; a dry-run only prints the plan.
ledger_self_remove() {
  local root="$AW_ROOT" u l
  if [[ "$DRY_RUN" != "1" && "${AW_LEDGER_ALLOW_SELF_REMOVE:-0}" != "1" ]]; then
    if [[ "$root" != /opt/* ]]; then
      warn "ledger: refusing to remove $root (not under /opt); remove alwayswork by hand"
      return 1
    fi
    if [[ "${AW_TEST:-0}" == "1" ]]; then
      warn "ledger: refusing to remove alwayswork under AW_TEST"
      return 1
    fi
  fi
  log "ledger: removing alwayswork itself"
  for u in alwayswork-provision.timer alwayswork-provision.service alwayswork-agent.service; do
    _ledger_unit_down "$u"
    run rm -f "/etc/systemd/system/$u"
  done
  _ledger_systemctl daemon-reload || true
  for l in /usr/local/bin/aw /usr/local/bin/alwayswork; do
    if [[ -L "$l" && "$(readlink "$l")" == "$root/"* ]]; then run rm -f "$l"; fi
  done
  run rm -rf "$root" "$AW_ETC" "$AW_LOG_DIR" "$AW_STATE"
}
