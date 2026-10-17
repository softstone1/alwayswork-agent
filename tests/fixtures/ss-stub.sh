#!/bin/sh
# ss stub for the listener audit (lib/health.sh health_listeners_json).
#   SS_MODE=empty  — ss ran, nothing listens
#   SS_MODE=many   — 40 distinct public listeners (the 32 cap)
case "${SS_MODE:-}" in
  empty) exit 0 ;;
  many) i=1; while [ "$i" -le 40 ]; do printf 'tcp   LISTEN 0 4096 0.0.0.0:%s 0.0.0.0:*\n' $((9000 + i)); i=$((i + 1)); done; exit 0 ;;
esac
cat <<'O'
udp   UNCONN 0      0       0.0.0.0%enp1s0:68        0.0.0.0:*    users:(("dhcpcd",pid=5,fd=6))
udp   UNCONN 0      0       127.0.0.53%lo:53         0.0.0.0:*    users:(("systemd-resolve",pid=7,fd=13))
udp   UNCONN 0      0       [fe80::1%enp1s0]:546     [::]:*
udp   UNCONN 0      0       *:5353                   *:*          users:(("avahi-daemon",pid=8,fd=12))
tcp   LISTEN 0      4096    0.0.0.0:22               0.0.0.0:*    users:(("sshd",pid=1,fd=3))
tcp   LISTEN 0      4096    [::]:22                  [::]:*       users:(("sshd",pid=1,fd=4))
tcp   LISTEN 0      4096    [::1]:631                [::]:*
tcp   LISTEN 0      4096    127.0.0.1:5432           0.0.0.0:*
tcp   LISTEN 0      4096    [::ffff:127.0.0.1]:8080  *:*
tcp   LISTEN 0      4096    10.89.0.1:53             0.0.0.0:*    users:(("aardvark-dns",pid=9,fd=5))
tcp   LISTEN 0      4096    [fd00:aa::1]:53          [::]:*
tcp   LISTEN 0      4096    192.168.1.20:8443        0.0.0.0:*    users:(("my app",pid=9,fd=5))
tcp   LISTEN 0      128     10.255.0.7:22            0.0.0.0:*    users:(("sshd",pid=1,fd=7))
tcp   LISTEN 0      128     100.96.0.12:22           0.0.0.0:*    users:(("sshd",pid=1,fd=5))
tcp   LISTEN 0      128     [2606:4700:110:8a1a:0:0:0:1]:22 [::]:*  users:(("sshd",pid=1,fd=6))
tcp   ESTAB  0      0       192.168.1.20:22          1.2.3.4:5555
O
