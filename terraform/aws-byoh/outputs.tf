output "ctrl_public_ip" {
  description = "Public IPv4 of the control plane (SSH here + visit :3000 for the web UI)"
  value       = aws_instance.ctrl.public_ip
}

output "ctrl_private_ip" {
  description = "Private IPv4 of the control plane (inside the VPC)"
  value       = aws_instance.ctrl.private_ip
}

output "ctrl_instance_id" {
  value = aws_instance.ctrl.id
}

output "data_public_ip" {
  description = "Public IPv4 of the BYOH data plane (use this for SSH-ing into the host itself, NOT the VMs)"
  value       = aws_instance.data.public_ip
}

output "data_private_ip" {
  description = "Private IPv4 of the data plane: the main IP, which host_add_command logs in to"
  value       = aws_instance.data.private_ip
}

output "data_instance_id" {
  value = aws_instance.data.id
}

output "data_eni_id" {
  value = aws_instance.data.primary_network_interface_id
}

output "ssh_private_key_path" {
  description = "Local path to the generated Ed25519 private key. Use with ssh -i <this>."
  value       = local_sensitive_file.ssh_private.filename
}

output "byoh_ip_pool" {
  description = "Secondary private IPs with an EIP (exposure nat in pools.yaml)."
  value       = var.byoh_secondary_private_ips
}

output "byoh_internal_ip_pool" {
  description = "Secondary private IPs without an EIP (exposure internal in pools.yaml)."
  value       = var.byoh_internal_private_ips
}

output "byoh_eip_to_private_ip" {
  description = "Map of public EIP → BYOH private IP. pools.yaml carries the same mapping as the external key of each nat pool."
  value = {
    for i, eip in aws_eip.byoh : eip.public_ip => var.byoh_secondary_private_ips[i]
  }
}

output "pools_yaml_path" {
  description = "Local path of the pools.yaml (version 2) for ubicloud-admin host add --pool-file (or bin/register-byoh-host --pool-file)."
  value       = local_file.pools_yaml.filename
}

locals {
  # Workspace names may hold uppercase, _ or ., which site add
  # rejects, so the fallback maps them onto its alphabet.
  byoh_location_name       = var.byoh_location_name != "" ? var.byoh_location_name : "byoh-aws-${lower(replace(terraform.workspace, "/[^A-Za-z0-9-]/", "-"))}"
  byoh_location_name_valid = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", local.byoh_location_name))
  # Private subnets of the location must stay out of the VPC underlay.
  byoh_overlay_ipv4_cidr = "172.20.0.0/14"
  # The masquerade denies host_mgmt_allow to VMs, so a world-open
  # operator_ssh_cidr must never land there.
  operator_ssh_open = var.operator_ssh_cidr == "0.0.0.0/0"
  byoh_mgmt_allow = join(",", concat(
    ["${aws_instance.ctrl.private_ip}/32"],
    local.operator_ssh_open ? [] : [var.operator_ssh_cidr]
  ))
  # Where a packaged control plane (scripts/byoh/install.sh) keeps the
  # billing rate overlay; ubicloud-admin site add writes there.
  byoh_rates_dir = "/var/lib/ubicloud/billing_rates.d"
  ssh_key_file   = local_sensitive_file.ssh_private.filename
  ctrl_login     = "ubuntu@${aws_instance.ctrl.public_ip}"
}

output "byoh_location_create_command" {
  description = "Command to run on the control plane to create the BYOH location (site) for this VPC."

  precondition {
    condition     = local.byoh_location_name_valid
    error_message = "The BYOH location name \"${local.byoh_location_name}\" is not valid for ubicloud-admin site add (2-63 lowercase letters, digits and -, ending in a letter or digit). Set byoh_location_name."
  }

  value = <<-EOT
    %{if local.operator_ssh_open~}
    # WARNING: operator_ssh_cidr is 0.0.0.0/0, so SSH to both instances is
    # open to the world and the operator is left out of --mgmt-allow. Set it
    # to your /32, apply, and print this command again.
    %{endif~}
    # On a packaged control plane (scripts/byoh/install.sh), site add writes
    # the rates to ${local.byoh_rates_dir} and restarts
    # ubicloud.target so web, respirate and monitor load them.
    # On a development control plane (bootstrap-dev-ctrl-plane.sh), run it
    # from ~/ubicloud as packaging/bin/ubicloud-admin --dev site add ...
    # (without sudo); the rates go to the BILLING_RATES_EXTRA_DIR of .env.rb,
    # and you restart puma and respirate yourself.
    sudo ubicloud-admin site add ${local.byoh_location_name} \
      --display "AWS ${var.aws_region} (BYOH)" \
      --underlay ${var.vpc_cidr} \
      --overlay ${local.byoh_overlay_ipv4_cidr} \
      --cp-reach onhost \
      --cp-source ${aws_instance.ctrl.private_ip}/32 \
      --mgmt-allow ${local.byoh_mgmt_allow} \
      --ula-underlay none \
      --rates-from hetzner-fsn1
  EOT
}

output "host_add_command" {
  description = "Commands that add the data plane as a BYOH host with ubicloud-admin host add: two on the workstation, three on the control plane."

  precondition {
    condition     = local.byoh_location_name_valid
    error_message = "The BYOH location name \"${local.byoh_location_name}\" is not valid for ubicloud-admin site add. Set byoh_location_name."
  }

  value = <<-EOT
    # On your workstation, in terraform/aws-byoh (the first needs the AWS CLI).
    # 1. The data plane's SSH host key fingerprints, which cloud-init prints
    #    to the instance console at first boot (empty until it has booted;
    #    this parse of the console output is UNVERIFIED on current AMIs).
    #    Prints the flags for the host add line below:
    aws ec2 get-console-output --region ${var.aws_region} --instance-id ${aws_instance.data.id} --latest --output text | awk '/BEGIN SSH HOST KEY FINGERPRINTS/ {f = 1} /END SSH HOST KEY FINGERPRINTS/ {f = 0} f {for (i = 1; i <= NF; i++) if ($i ~ /^SHA256:/) printf "--expect-host-key %s ", $i} END {print ""}'
    # 2. Copy the pool file and the EC2 login key to the control plane:
    scp -i ${local.ssh_key_file} ${local_file.pools_yaml.filename} ${local.ssh_key_file} ${local.ctrl_login}:

    # On the control plane (ssh -i ${local.ssh_key_file} ${local.ctrl_login}).
    # Put the flags from step 1 in EXPECT, or set EXPECT= (empty): then host
    # add shows the fingerprints and asks for a typed "yes"; compare them
    # with step 1. Left as it is, EXPECT makes host add stop with a usage
    # error before it changes anything.
    # --ssh-key is the operator login (user ubuntu has passwordless sudo).
    # user-data also copied this EC2 key into root's authorized_keys (for
    # bin/register-byoh-host), and host add leaves that line; step 4
    # removes it. host add makes and keeps its own root key, and deletes
    # its staged copy of this one after the prepare phase. --no-wait
    # returns once the host is registered, so the copy of the EC2 key on
    # the control plane is shredded before the bring-up watch (about 4
    # minutes nested, 15-25 on .metal). The three steps are chained: when
    # host add fails, the key stays for a retry and nothing else runs.
    # On a development control plane, run packaging/bin/ubicloud-admin --dev
    # from ~/ubicloud, without sudo, in place of sudo ubicloud-admin.
    EXPECT='<the --expect-host-key flags printed by step 1>'
    sudo ubicloud-admin host add --site ${local.byoh_location_name} --ssh ubuntu@${aws_instance.data.private_ip} --ssh-key ~/byoh_ssh_key --pool-file ~/pools.yaml $EXPECT --no-wait \
      && shred -u ~/byoh_ssh_key \
      && sudo ubicloud-admin host watch ${aws_instance.data.private_ip}

    # 4. Optional, on the workstation once host add has succeeded: drop the
    #    EC2 key from root's logins on the data plane (it stays the ubuntu
    #    login). It keeps every other line, and changes nothing unless host
    #    add's own key (tagged ubicloud-byoh) would remain:
    #   ssh -i ${local.ssh_key_file} ubuntu@${aws_instance.data.public_ip} 'sudo sh -c "grep -vxFf /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys >/root/.ssh/ak.new; if [ \$? -le 1 ] && grep -q \" # ubicloud-byoh \" /root/.ssh/ak.new; then chmod 600 /root/.ssh/ak.new && mv /root/.ssh/ak.new /root/.ssh/authorized_keys; else rm -f /root/.ssh/ak.new; echo root keys left unchanged >&2; exit 1; fi"'
  EOT
}

output "handoff_instructions" {
  description = "What the operator runs next to bring up Ubicloud on this infrastructure."
  value       = <<-EOT

    ==================================================================
     Ubicloud BYOH test infrastructure is ready.
    ==================================================================

    Control plane (${var.ctrl_plane_instance_type}, runs postgres + clover + respirate + monitor):
      public IP:  ${aws_instance.ctrl.public_ip}
      private IP: ${aws_instance.ctrl.private_ip}
      SSH:        ssh -i ${local_sensitive_file.ssh_private.filename} ubuntu@${aws_instance.ctrl.public_ip}

    Data plane (${var.data_plane_instance_type}):
      public IP:  ${aws_instance.data.public_ip}
      private IP: ${aws_instance.data.private_ip}  ← host add --ssh ubuntu@<this>, and the main IP
      instance:   ${aws_instance.data.id}
      SSH:        ssh -i ${local_sensitive_file.ssh_private.filename} ubuntu@${aws_instance.data.public_ip}

    BYOH pools (${local_file.pools_yaml.filename}):
    %{for i, eip in aws_eip.byoh~}
      ${var.byoh_secondary_private_ips[i]}/32  nat       EIP ${eip.public_ip}
    %{endfor~}
    %{for ip in var.byoh_internal_private_ips~}
      ${ip}/32  internal  no EIP; VPC-only, outbound via the host NAT
    %{endfor~}

    Next steps:

      1. SSH in to the control plane:
         ssh -i ${local.ssh_key_file} ${local.ctrl_login}

      2. Clone the BYOH fork and set up the control plane, packaged
         (sudo bash ~/ubicloud/scripts/byoh/install.sh ..., docs/byoh/INSTALL.md)
         or for development:
         git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
         bash ~/ubicloud/scripts/byoh/bootstrap-dev-ctrl-plane.sh
         The development layout has no ubicloud-admin on PATH: in steps 3-5
         run packaging/bin/ubicloud-admin --dev from ~/ubicloud, without
         sudo, and restart puma and respirate yourself after step 3.

      3. Create the BYOH location (site); run the command in
         terraform output -raw byoh_location_create_command

      4. Add the data plane as a host (preflight, root key, registration,
         bring-up); run the commands in
         terraform output -raw host_add_command

      5. Create an account at http://${aws_instance.ctrl.public_ip}:3000/create-account, then
         let its project see the location:
         sudo ubicloud-admin site grant ${local.byoh_location_name} --project <project ubid>

      6. Create a VM in "AWS ${var.aws_region} (BYOH)". Its Public IPv4 is the EIP:
         ssh ubi@<eip>

    Do not apply this module in the company-mumbai workspace until M7 (P2).

    To tear all of this down (including EIPs, instances, VPC):
      terraform destroy
  EOT
}
