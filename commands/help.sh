# shellcheck shell=bash
# aw help — usage.

cmd_help() {
  cat <<EOF
Anakut Worker ${AW_VERSION} — secure, capability-based worker node

USAGE
  aw <command> [options]

LIFECYCLE
  init [--profile P]        Write /etc/anakut-worker/worker.yaml
  bootstrap                 Secure the machine + install the foundation
  apply                     Reconcile installed capabilities to config

CAPABILITIES
  list [--available]        Show the catalog
  enable <cap>... [--k v]   Install + persist a capability (with dependencies)
  disable <cap>...          Cleanly remove a capability
  capability add <path>     Register an out-of-tree capability

OPERATIONS
  status                    Node, runtime and capability status
  power <status|apply|off>  Headless / always-on power policy
  clean                     Remove orphans, caches and junk

APPS
  app list [category]       Browse the curated tool catalog
  app search <term>         Search the catalog
  app install <id>...       Install tools on demand
  app remove <id>...        Uninstall tools
  doctor                    Scored security + health audit
  update                    Snapshot, upgrade, roll back on failure
  snapshot <list|create|rollback> [arg]
  secrets <init|set|get|list|env>

GLOBAL FLAGS
  --dry-run                 Print actions without changing anything
  --yes, -y                 Non-interactive
  --json                    Machine-readable output (status)
  --version, -V             Print version
  --help, -h                This help

PROFILES
  foundation                Secured base node only
  worker                    Foundation + runtime + backups + monitoring
  agent                     Foundation + runtime + agent control plane
  assistant                 Foundation + runtime + automation hub
  full                      Everything the catalog ships

EXAMPLES
  sudo aw init --profile foundation && sudo aw bootstrap
  sudo aw enable runtime.docker
  sudo aw enable access.tunnel --domain worker.example.com
  sudo aw doctor

Docs: docs/DESIGN.md, docs/CAPABILITIES.md, docs/SECURITY.md, docs/ROLLOUT.md
EOF
}
