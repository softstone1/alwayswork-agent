# shellcheck shell=bash
# alwayswork · hardware and platform detection.

hw_cores()     { nproc 2>/dev/null || getconf _NPROCESSORS_ONLN; }
hw_mem_mb()    { awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo; }
hw_arch()      { uname -m; }
hw_kernel()    { uname -r; }
hw_root_fs()   { findmnt -no FSTYPE / 2>/dev/null | head -1; }
hw_is_btrfs()  { [[ "$(hw_root_fs)" == "btrfs" ]]; }
hw_os_pretty() { ( . /etc/os-release 2>/dev/null; printf '%s\n' "${PRETTY_NAME:-unknown}" ); }
hw_os_id()     { ( . /etc/os-release 2>/dev/null; printf '%s\n' "${ID:-unknown}" ); }

hw_is_arch() {
  local id; id="$(hw_os_id)"
  [[ "$id" == "arch" || "$id" == "cachyos" ]] && return 0
  grep -qi 'ID_LIKE=.*arch' /etc/os-release 2>/dev/null
}

hw_gpu() {
  have lspci || { echo "(lspci not installed)"; return; }
  lspci 2>/dev/null | grep -Ei 'vga|3d|display' | sed 's/^[^:]*: //' | head -1
}

hw_cpu_model() { sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -1; }

# GPUs as JSON [{model, vramMb, vendor}]: nvidia-smi when present (VRAM
# known), else every VGA/3D device from lspci (model only). Capacity, not load.
hw_gpus_json() {
  if have nvidia-smi; then
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null \
      | awk -F', *' 'NF>=2 {printf "%s\t%s\n", $1, $2}' \
      | jq -R -s 'split("\n") | map(select(length>0) | split("\t") | {model:.[0], vramMb:(.[1]|tonumber), vendor:"nvidia"})' 2>/dev/null && return 0
  fi
  if have lspci; then
    lspci 2>/dev/null | grep -Ei 'vga|3d|display' | sed 's/^[^ ]* [^:]*: //; s/ (rev [^)]*)$//' | cut -c1-128 \
      | jq -R -s 'split("\n") | map(select(length>0) | {model:., vendor:(if test("NVIDIA";"i") then "nvidia" elif test("AMD|ATI";"i") then "amd" elif test("Intel";"i") then "intel" else "other" end)})' 2>/dev/null && return 0
  fi
  printf '[]'
}

hw_free_disk_gb() { df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9'; }
hw_virt()         { systemd-detect-virt 2>/dev/null || echo unknown; }

# Per-container memory budget for limits.mode=auto.
hw_limit_memory_mb() {
  local total reserve maxc per
  total="$(hw_mem_mb)"
  reserve="$(cfg_get '.limits.reserve_for_host_mb' 4096)"
  maxc="$(cfg_get '.limits.max_concurrent' 8)"
  [[ "$maxc" =~ ^[0-9]+$ ]] || maxc=8
  [[ "$reserve" =~ ^[0-9]+$ ]] || reserve=4096
  per=$(( (total - reserve) / maxc ))
  (( per < 512 )) && per=512
  (( per > 8192 )) && per=8192
  printf '%s\n' "$per"
}

hw_report() {
  section "Hardware"
  kv "os"        "$(hw_os_pretty)"
  kv "arch"      "$(hw_arch)"
  kv "kernel"    "$(hw_kernel)"
  kv "cpu"       "$(hw_cores) threads"
  kv "memory"    "$(hw_mem_mb) MiB"
  kv "disk free" "$(hw_free_disk_gb) GiB"
  kv "root fs"   "$(hw_root_fs)"
  kv "gpu"       "$(hw_gpu)"
  kv "virt"      "$(hw_virt)"
}
