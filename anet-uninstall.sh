#!/usr/bin/env bash
set -u

if [[ "${EUID}" -ne 0 ]]; then
  echo "Запустите от root: sudo bash $0"
  exit 1
fi

systemctl disable --now anet-vpn anet-nat 2>/dev/null || true
rm -f /etc/systemd/system/anet-vpn.service /etc/systemd/system/anet-nat.service /etc/sysctl.d/99-anet.conf
systemctl daemon-reload

EXT_IF="$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
if [[ -n "${EXT_IF}" ]]; then
  iptables -D FORWARD -i "${EXT_IF}" -o anet-server -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i anet-server -o "${EXT_IF}" -j ACCEPT 2>/dev/null || true
  iptables -t nat -D POSTROUTING -s 172.112.222.0/24 -o "${EXT_IF}" -j MASQUERADE 2>/dev/null || true
fi

rm -rf /opt/anet
echo "ANet полностью удалён."