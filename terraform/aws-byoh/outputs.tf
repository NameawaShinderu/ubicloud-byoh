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
  description = "List of secondary private IPs assigned to the data plane ENI. This is the routed_network pool you declare to bin/register-byoh-host."
  value       = var.byoh_secondary_private_ips
}

output "byoh_eip_to_private_ip" {
  description = "Map of public EIP → BYOH private IP. When Ubicloud allocates a VM one of the private IPs, SSH to the matching EIP from anywhere on the internet."
  value = {
    for i, eip in aws_eip.byoh : eip.public_ip => var.byoh_secondary_private_ips[i]
  }
}

output "handoff_instructions" {
  description = "What the operator runs next to bring up Ubicloud on this infrastructure."
  value       = <<-EOT

    ==================================================================
     Ubicloud BYOH test infrastructure is ready.
    ==================================================================

    Control plane (t3.medium, runs postgres + clover + respirate):
      public IP:  ${aws_instance.ctrl.public_ip}
      private IP: ${aws_instance.ctrl.private_ip}
      SSH:        ssh -i ${local_sensitive_file.ssh_private.filename} ubuntu@${aws_instance.ctrl.public_ip}

    Data plane (${var.data_plane_instance_type}, real bare metal):
      public IP:  ${aws_instance.data.public_ip}
      private IP: ${aws_instance.data.private_ip}  ← this is the --main-ip for register-byoh-host
      instance:   ${aws_instance.data.id}
      SSH:        ssh -i ${local_sensitive_file.ssh_private.filename} ubuntu@${aws_instance.data.public_ip}

    BYOH IP pool (3 × secondary private IPs with 1:1 EIP mapping):
    %{for i, eip in aws_eip.byoh~}
      ${var.byoh_secondary_private_ips[i]}  ⇄  EIP ${eip.public_ip}
    %{endfor~}

    What to do next (on YOUR workstation, the control plane, and the data plane):

      1. SSH into the control plane:
         ssh -i ${local_sensitive_file.ssh_private.filename} ubuntu@${aws_instance.ctrl.public_ip}

      2. Clone the Ubicloud BYOH fork:
         git clone <github-url> ubicloud
         cd ubicloud
         git checkout byoh-driver

      3. Run the control plane bootstrap:
         ./scripts/byoh/bootstrap-ctrl-plane.sh

      4. Follow docs/byoh/QUICKSTART.md for the rest:
         - generate the ctrl→data SSH key
         - install it on the data plane's /root/.ssh/authorized_keys
         - run bin/register-byoh-host
         - open http://${aws_instance.ctrl.public_ip}:3000/create-account in your browser
         - create a project, upload SSH key, create a VM

      5. SSH into the created VM from ANYWHERE using the matching EIP:
         ssh ubi@<eip>   # look up the EIP from byoh_eip_to_private_ip above

    To tear all of this down (including EIPs, instances, VPC):
      terraform destroy
  EOT
}
