#!/bin/sh
# ip stub: the private infrastructure interfaces exist — awinfra0 (a /32
# from 198.18.128.0/20) and CloudflareWARP (one v4, one v6). Every other query
# behaves like a host without routes. IP_NO_AWINFRA / IP_NO_WARP hide one.
case "$1 $2 $3 $4 $5" in
  "-o addr show dev awinfra0")
    [ -n "${IP_NO_AWINFRA:-}" ] && { echo 'Device "awinfra0" does not exist.' >&2; exit 1; }
    echo '9: awinfra0    inet 198.18.130.7/32 scope global awinfra0\       valid_lft forever preferred_lft forever'
    exit 0 ;;
  "-o addr show dev CloudflareWARP")
    [ -n "${IP_NO_WARP:-}" ] && { echo 'Device "CloudflareWARP" does not exist.' >&2; exit 1; }
    cat <<'O'
7: CloudflareWARP    inet 100.96.0.12/32 scope global CloudflareWARP\       valid_lft forever preferred_lft forever
7: CloudflareWARP    inet6 2606:4700:110:8a1a::1/128 scope global \       valid_lft forever preferred_lft forever
O
    exit 0 ;;
esac
exit 1
