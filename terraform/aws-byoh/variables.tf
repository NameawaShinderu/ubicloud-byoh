variable "aws_region" {
  description = "AWS region to deploy the BYOH test env in. Use a region that doesn't overlap with any of your existing production infra."
  type        = string
  default     = "ap-south-1"
}

variable "availability_zone" {
  description = "AZ within the region. Must be an AZ that offers the chosen data_plane_instance_type."
  type        = string
  default     = "ap-south-1a"
}

variable "vpc_cidr" {
  description = "CIDR for the dedicated BYOH test VPC. Must not overlap with any existing VPC in your account."
  type        = string
  default     = "10.98.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR for the public subnet inside the VPC."
  type        = string
  default     = "10.98.1.0/24"
}

variable "operator_ssh_cidr" {
  description = "CIDR of the operator's workstation for SSH port 22 ingress, normally your public IP as a /32. Required: there is no default, so that SSH is never open to the world by accident. 0.0.0.0/0 is accepted but warned about."
  type        = string

  validation {
    condition     = can(cidrhost(var.operator_ssh_cidr, 0)) && can(regex("^[0-9.]+/[0-9]+$", var.operator_ssh_cidr))
    error_message = "operator_ssh_cidr must be an IPv4 CIDR such as 203.0.113.42/32."
  }
}

variable "ctrl_plane_instance_type" {
  description = "Instance type for the control plane (runs postgres + clover + respirate). t3.medium is plenty for testing."
  type        = string
  default     = "t3.medium"
}

variable "data_plane_instance_type" {
  description = "Instance type for the BYOH data plane. For standard (KVM) VMs: an 8th-gen Intel type with nested virtualization (m8i/c8i/r8i; set data_plane_nested_virtualization = true), or a .metal type. A plain type without nested virtualization (m6i/m7i, xlarge or larger) works only with the experimental container or pvm tiers (or the slow emulated tier) (docs/byoh/NO_KVM.md, docs/byoh/platforms/aws.md section 2.1a). The default (m5d.metal) predates nested-virtualization support."
  type        = string
  default     = "m5d.metal"
}

variable "ctrl_root_size_gb" {
  description = "Root EBS volume size for the control plane."
  type        = number
  default     = 40
}

variable "data_root_size_gb" {
  description = "Root EBS volume size for the data plane. Ubicloud's SPDK vhost-user backend serves VM disks from /var/storage which lives on this disk, so size this to cover (image_size + N × VM_disk_size + headroom). 80 GB is ~1 VM's worth; bump to 200 GB if you want more VMs. The 4 × 900 GB instance-store NVMes on m5d.metal are NOT automatically used — that's a known BYOH gap (see docs/providers/generic.md → storage discovery)."
  type        = number
  default     = 120
}

variable "byoh_secondary_private_ips" {
  description = "Pool of secondary private IPs assigned to the data plane ENI. One EIP is allocated + associated with each, and each is written to pools.yaml as a /32 with exposure nat. Pool size = max concurrent VMs publicly reachable from the internet."
  type        = list(string)
  default = [
    "10.98.1.128",
    "10.98.1.129",
    "10.98.1.130",
  ]
}

variable "byoh_internal_private_ips" {
  description = "Extra secondary private IPs on the data plane ENI that get NO Elastic IP. They are written to pools.yaml with exposure internal: VMs on them are reachable only from inside the VPC and reach the internet through the host NAT."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for ip in var.byoh_internal_private_ips : can(regex("^[0-9.]+$", ip)) && can(cidrhost("${ip}/32", 0))])
    error_message = "byoh_internal_private_ips must be plain IPv4 addresses, without a prefix length."
  }
}

variable "byoh_location_name" {
  description = "Name of the BYOH location printed in byoh_location_create_command (lowercase letters, digits and -). Empty means byoh-aws-<workspace>."
  type        = string
  default     = ""

  # Same rule as ByohLocationCli::NAME_FORMAT.
  validation {
    condition     = var.byoh_location_name == "" || can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.byoh_location_name))
    error_message = "byoh_location_name must be 2-63 lowercase letters, digits and -, start with a letter and not end with -."
  }
}

variable "web_ui_cidr" {
  description = "CIDR allowed to reach ports 3000 (web UI) and 443 on the instances: your /32, or the range your customers come from. Required: there is no default. Keep the UI private behind a tunnel by giving your own /32."
  type        = string

  validation {
    condition     = can(cidrhost(var.web_ui_cidr, 0)) && can(regex("^[0-9.]+/[0-9]+$", var.web_ui_cidr))
    error_message = "web_ui_cidr must be an IPv4 CIDR such as 203.0.113.42/32."
  }
}

variable "data_plane_nested_virtualization" {
  description = "Enable nested virtualization on the data plane. Needed for non-.metal 8th-gen Intel types (m8i, c8i, r8i) so /dev/kvm exists inside the instance."
  type        = bool
  default     = false
}

variable "data_plane_open_ingress" {
  description = "Let all internet traffic reach the data plane so Ubicloud's per-VM firewall rules (set by customers in the UI/API) are the only filter, like a real provider network. false = only the operator and the control plane can reach the data plane, so VMs are unreachable from outside."
  type        = bool
  default     = false
}
