# shellcheck shell=bash
# aw help — usage.

cmd_help() {
  cat <<EOF
AlwaysWork ${AW_VERSION} — secure, capability-based worker node

USAGE
  aw <command> [options]

LIFECYCLE
  init [--profile P]        Write /etc/alwayswork/worker.yaml
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
  enroll --control URL [--token T|--usb]  Announce this worker; USB or console approval
  enroll                    Resume a pending enrolment or claim (after the console click)
  enroll --status           Show enrollment / claim / decommission state
  provision                 First-boot/hotplug entry point: USB stick, pending claim/enrolment
  decommission [--local]    Leave the fleet: drain, tombstone, wipe, restore the machine
      [--keep-foundation|--keep-agent]   ... but keep the hardening / keep alwayswork
  reset [--purge]           Forget this identity so the node can re-join
  agent [interval]          Report state and reconcile (run as a service)
  service list              Service workloads on this node (postgres, ...)
  service <action> <id>     status|logs|snapshot|backup|restore|upgrade|psql
  bridge --once             Serve the harness's allowlisted requests (path unit)

APPS
  app list [category]       Browse the curated tool catalog
  app search <term>         Search the catalog
  app install <id>...       Install tools on demand
  app remove <id>...        Uninstall tools
  doctor                    Scored security + health audit
  update                    Snapshot, upgrade, health gate, boot probation; --guard, --boot-check
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
  agent                     Foundation + runtime + agent control plane + node web UI
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
