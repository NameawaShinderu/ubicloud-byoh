#!/bin/bash
# Run on: ctrl plane VM (or via SSH from Proxmox host)
# Purpose: Live monitoring dashboard
# Usage: bash 05-monitor.sh [once|loop]

DATA_IP=${DATA_IP:-10.98.1.30}
MODE=${1:-loop}

dashboard() {
  clear
  echo "==== UBICLOUD MONITOR - $(date) ===="
  echo

  echo "-- CTRL PLANE SERVICES --"
  tmux ls 2>/dev/null
  curl -sI http://localhost:3000/ 2>/dev/null | head -1

  echo
  echo "-- VM HOST --"
  cd ~/ubicloud
  export PATH=$HOME/.local/share/mise/shims:$PATH
  export RACK_ENV=development
  bundle exec ruby -e '
    require_relative "loader"
    DB[:vm_host].each do |h|
      puts "  alloc=#{h[:allocation_state]} cores=#{h[:total_cores]}(used #{h[:used_cores]}) mem=#{h[:total_mem_gib]}GB hugepages=#{h[:total_hugepages_1g]}(used #{h[:used_hugepages_1g]}) accepts_slices=#{h[:accepts_slices]}"
    end
    puts "  (no host)" if DB[:vm_host].count == 0
  ' 2>/dev/null

  echo
  echo "-- VMs --"
  bundle exec ruby -e '
    require_relative "loader"
    DB[:vm].each do |v|
      puts "  #{v[:name].to_s.ljust(22)} state=#{v[:display_state].to_s.ljust(18)} ip=#{v[:ephemeral_net4]} vcpus=#{v[:vcpus]} mem=#{v[:memory_gib]}GB"
    end
    puts "  (no VMs yet)" if DB[:vm].count == 0
  ' 2>/dev/null

  echo
  echo "-- ACTIVE STRANDS --"
  bundle exec ruby -e '
    require_relative "loader"
    rows = DB["SELECT label, try FROM strand WHERE exitval IS NULL ORDER BY try DESC"].limit(10).all
    rows.each { |s| puts "  #{s[:label].to_s.ljust(35)} try=#{s[:try]}" }
    puts "  (no active strands)" if rows.empty?
  ' 2>/dev/null

  echo
  echo "-- LAST RESPIRATE ERRORS --"
  tail -3 /tmp/respirate.err 2>/dev/null || echo "  (none)"

  echo
  echo "-- DATA PLANE HEALTH --"
  ssh -o ConnectTimeout=3 root@$DATA_IP 'uptime | head -1; echo "  hugepages: $(grep HugePages_Total /proc/meminfo | awk "{print \$2}") total / $(grep HugePages_Free /proc/meminfo | awk "{print \$2}") free"; echo "  cloud-hyp procs: $(pgrep -fc cloud-hyp)"; echo "  vhost services: $(systemctl list-units --state=running --no-legend | grep -c "\-storage.service")"' 2>/dev/null || echo "  (unreachable)"
}

if [[ "$MODE" == "once" ]]; then
  dashboard
else
  while true; do
    dashboard
    echo
    echo "[Refreshes every 10s. Ctrl+C to exit]"
    sleep 10
  done
fi
