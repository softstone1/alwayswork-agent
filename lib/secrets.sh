# shellcheck shell=bash
# alwayswork · encrypted secret store (sops + age).
#
# Plaintext never lands in git or on disk. Secrets live in an age-encrypted
# YAML file; capabilities receive them through a runtime-only env file.

sec_backend()   { have sops && have age && echo sops || echo none; }
sec_key_file()  { printf '%s\n' "${SOPS_AGE_KEY_FILE:-$AW_ETC/age.key}"; }
sec_file()      { printf '%s\n' "$AW_ETC/secrets.enc.yaml"; }
sec_exists()    { [[ -f "$(sec_file)" ]]; }

sec_public_key() {
  local key; key="$(sec_key_file)"
  [[ -f "$key" ]] || return 0
  sed -n 's/^# public key: //p' "$key" | head -1
}

sec_init() {
  local backend; backend="$(sec_backend)"
  [[ "$backend" == "sops" ]] || die "secrets need sops and age installed"
  ensure_dir "$AW_ETC"
  local key; key="$(sec_key_file)"
  if [[ ! -f "$key" ]]; then
    log "Generating age key at $key"
    if [[ "$DRY_RUN" == "1" ]]; then
      printf '    [dry-run] age-keygen -o %s\n' "$key" >&2
    else
      age-keygen -o "$key" 2>/dev/null
      chmod 600 "$key"
    fi
  fi
  [[ "$DRY_RUN" == "1" ]] && return 0
  local pub; pub="$(sec_public_key)"
  [[ -n "$pub" ]] || die "could not read age public key from $key"
  if [[ ! -f "$(sec_file)" ]]; then
    local tmp; tmp="$(mktemp)"
    printf '{}\n' > "$tmp"
    SOPS_AGE_KEY_FILE="$key" sops -e --age "$pub" "$tmp" > "$(sec_file)"
    rm -f "$tmp"
    chmod 600 "$(sec_file)"
  fi
  ok "secret store ready ($(sec_file))"
}

sec_list() {
  sec_exists || return 0
  SOPS_AGE_KEY_FILE="$(sec_key_file)" sops -d "$(sec_file)" 2>/dev/null | yq -r 'keys | .[]'
}

sec_get() {
  local k="$1"
  sec_exists || return 0
  AW_K="$k" SOPS_AGE_KEY_FILE="$(sec_key_file)" sops -d "$(sec_file)" 2>/dev/null \
    | AW_K="$k" yq -r '.[strenv(AW_K)] // ""' 2>/dev/null || true
}

sec_has() { [[ -n "$(sec_get "$1")" ]]; }

sec_set() {
  local k="$1" v="$2"
  sec_exists || sec_init
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] secret set %s\n' "$k" >&2; return 0
  fi
  local tmp; tmp="$(mktemp)"
  chmod 600 "$tmp"
  SOPS_AGE_KEY_FILE="$(sec_key_file)" sops -d "$(sec_file)" > "$tmp"
  AW_K="$k" AW_V="$v" yq -i '.[strenv(AW_K)] = strenv(AW_V)' "$tmp"
  SOPS_AGE_KEY_FILE="$(sec_key_file)" sops -e "$tmp" > "$(sec_file)"
  rm -f "$tmp"
  chmod 600 "$(sec_file)"
  ok "secret '$k' stored"
}

sec_env() {
  local dest="$1"
  sec_exists || die "no secret store yet; run: aw secrets init"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] decrypt secrets to %s\n' "$dest" >&2; return 0
  fi
  SOPS_AGE_KEY_FILE="$(sec_key_file)" sops -d "$(sec_file)" > "$dest"
  chmod 600 "$dest"
}
