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
  description = "Private IPv4 of the data plane (this is the main_ip4 you pass to bin/register-byoh-host)"
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
  description = "Local path of the pools.yaml (version 2) to pass to bin/register-byoh-host --pool-file."
  value       = local_file.pools_yaml.filename
}

locals {
  byoh_location_name = var.byoh_location_name != "" ? var.byoh_location_name : "byoh-aws-${terraform.workspace}"
  # Private subnets of the location must stay out of the VPC underlay.
  byoh_overlay_ipv4_cidr = "172.20.0.0/14"
  # The masquerade denies host_mgmt_allow to VMs, so a world-open
  # operator_ssh_cidr must never land there.
  operator_ssh_open = var.operator_ssh_cidr == "0.0.0.0/0"
  byoh_mgmt_allow = join(",", concat(
    ["${aws_instance.ctrl.private_ip}/32"],
    local.operator_ssh_open ? [] : [var.operator_ssh_cidr]
  ))
  byoh_rates_dir = "/etc/ubicloud/billing_rates.d"
}

output "byoh_location_create_command" {
  description = "Commands to run on the control plane, from the repo root, to create the BYOH location for this VPC."
  value       = <<-EOT
    %{if local.operator_ssh_open~}
    # WARNING: operator_ssh_cidr is 0.0.0.0/0, so SSH to both instances is
    # open to the world and the operator is left out of --mgmt-allow. Set it
    # to your /32, apply, and print this command again.
    %{endif~}
    # The rate overlay must be set for web, respirate AND monitor: add
    #   ENV["BILLING_RATES_EXTRA_DIR"] ||= "${local.byoh_rates_dir}"
    # to .env.rb, and keep the directory in your backups.
    sudo install -d -o "$USER" ${local.byoh_rates_dir}
    export BILLING_RATES_EXTRA_DIR=${local.byoh_rates_dir}
    bundle exec bin/byoh-location create \
      --name ${local.byoh_location_name} \
      --display-name ${local.byoh_location_name} \
      --ui-name "AWS ${var.aws_region} (BYOH)" \
      --underlay ${var.vpc_cidr} \
      --overlay ${local.byoh_overlay_ipv4_cidr} \
      --cp-reach onhost \
      --cp-source ${aws_instance.ctrl.private_ip}/32 \
      --mgmt-allow ${local.byoh_mgmt_allow} \
      --ula-underlay none \
      --rates-from hetzner-fsn1
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
      private IP: ${aws_instance.data.private_ip}  ← the --main-ip for register-byoh-host
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

      1. Copy the pool file and the host key to the control plane, then SSH in:
         scp -i ${local_sensitive_file.ssh_private.filename} ${local_file.pools_yaml.filename} ${local_sensitive_file.ssh_private.filename} ubuntu@${aws_instance.ctrl.public_ip}:
         ssh -i ${local_sensitive_file.ssh_private.filename} ubuntu@${aws_instance.ctrl.public_ip}

      2. Clone the BYOH fork and bootstrap the control plane:
         git clone -b byoh-driver https://github.com/NameawaShinderu/ubicloud-byoh.git ~/ubicloud
         bash ~/ubicloud/scripts/byoh/bootstrap-ctrl-plane.sh

      3. Create the BYOH location (cd ~/ubicloud): run the commands in
         terraform output -raw byoh_location_create_command
         then restart web, respirate and monitor so they load the rates.

      4. Register the data plane:
         bundle exec bin/register-byoh-host --location ${local.byoh_location_name} \
           --main-ip ${aws_instance.data.private_ip} --pool-file ~/pools.yaml \
           --ssh-key ~/byoh_ssh_key --default-boot-image ubuntu-noble --yes

      5. Create an account at http://${aws_instance.ctrl.public_ip}:3000/create-account, then
         let its project see the location:
         bundle exec bin/byoh-location grant --location ${local.byoh_location_name} --project <project ubid>

      6. Create a VM in "AWS ${var.aws_region} (BYOH)". Its Public IPv4 is the EIP:
         ssh ubi@<eip>

    Do not apply this module in the company-mumbai workspace until M7 (P2).

    To tear all of this down (including EIPs, instances, VPC):
      terraform destroy
  EOT
}
