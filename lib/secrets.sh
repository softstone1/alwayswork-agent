# shellcheck shell=bash
# alwayswork · encrypted secret store (sops + age).
#
# Plaintext never lands in git or on disk. Secrets live in an age-encrypted
# YAML file; capabilities receive them through a runtime-only env file.

sec_backend()   { have sops && have age && echo sops || echo none; }
sec_key_file()  { printf '%s\n' "${SOPS_AGE_KEY_FILE:-$AW_ETC/age.key}"; }
sec_file()      { printf '%s\n' "$AW_ETC/secrets.enc.yaml"; }
sec_exists()    { [[ -f "$(sec_file)" ]]; }

# sops infers the document format from the file extension. A bare mktemp file
# has none, so sops falls back to treating the document as binary and wraps the
# whole thing in "data: |", which then round-trips as garbage. Always work in a
# scratch directory with a .yaml file.
sec_workdir() { mktemp -d "${TMPDIR:-/tmp}/alwayswork-secrets.XXXXXX"; }

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
  if [[ ! -s "$(sec_file)" ]]; then
    # Encrypt to a scratch file first: a failing sops must never leave a
    # zero-byte store behind, which is unreadable and unrecoverable in place.
    local d; d="$(sec_workdir)"
    printf '{}\n' > "$d/store.yaml"
    if SOPS_AGE_KEY_FILE="$key" sops -e --age "$pub" "$d/store.yaml" > "$d/out.yaml" 2>/dev/null && [[ -s "$d/out.yaml" ]]; then
      mv "$d/out.yaml" "$(sec_file)"
    else
      rm -rf "$d"
      die "could not encrypt the secret store for $pub"
    fi
    rm -rf "$d"
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
  local k="$1" v="$2" key pub d
  key="$(sec_key_file)"
  if [[ ! -s "$(sec_file)" ]]; then
    # Missing, zero-byte or unreadable stores are rebuilt. The old code
    # appended to the file and, when sops failed, truncated the live store.
    [[ -f "$(sec_file)" ]] && warn "secret store at $(sec_file) is not usable; rebuilding"
    rm -f "$(sec_file)"
    sec_init
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    [dry-run] secret set %s\n' "$k" >&2; return 0
  fi
  pub="$(sec_public_key)"
  [[ -n "$pub" ]] || die "no age public key in $key; run: aw secrets init"
  d="$(sec_workdir)"
  if ! SOPS_AGE_KEY_FILE="$key" sops -d "$(sec_file)" > "$d/store.yaml" 2>/dev/null; then
    warn "could not decrypt $(sec_file); starting a new store"
    printf '{}\n' > "$d/store.yaml"
  fi
  AW_K="$k" AW_V="$v" yq -i '.[strenv(AW_K)] = strenv(AW_V)' "$d/store.yaml"
  if ! SOPS_AGE_KEY_FILE="$key" sops -e --age "$pub" "$d/store.yaml" > "$d/out.yaml" 2>/dev/null || [[ ! -s "$d/out.yaml" ]]; then
    rm -rf "$d"
    die "could not encrypt the secret store for $pub"
  fi
  mv "$d/out.yaml" "$(sec_file)"
  rm -rf "$d"
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
