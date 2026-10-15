set -ueo pipefail
if id vm4hjdwr &>/dev/null; then
  procs=$(ps -u vm4hjdwr -o pid,comm,args --no-headers) || [ $? -eq 1 ]
  if [ -n "$procs" ]; then
    echo "Terminating "vm4hjdwr" processes:"
    echo "$procs"
    sudo pkill -u vm4hjdwr || [ $? -eq 1 ]
    sleep 1
  fi
  sudo userdel -r vm4hjdwr
fi
if getent group vm4hjdwr &>/dev/null; then sudo groupdel vm4hjdwr; fi
sudo adduser --disabled-password --gecos '' --home /vm/vm4hjdwr --uid 1111 vm4hjdwr
# Enable KVM access for VM user
sudo usermod -a -G kvm vm4hjdwr
