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
  description = "CIDR of the operator's workstation for SSH port 22 ingress. Default is 0.0.0.0/0 for ease of testing — you should tighten this to your /32 public IP in real usage."
  type        = string
  default     = "0.0.0.0/0"
}

variable "ctrl_plane_instance_type" {
  description = "Instance type for the control plane (runs postgres + clover + respirate). t3.medium is plenty for testing."
  type        = string
  default     = "t3.medium"
}

variable "data_plane_instance_type" {
  description = "Instance type for the BYOH data plane. MUST be a bare-metal type (.metal suffix) for SPDK + cloud-hypervisor to work properly. m5d.metal (96 vCPU, 384 GB RAM, 4×900 GB NVMe instance store) is the cheapest real-NVMe option in ap-south-1."
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
  description = "CIDR allowed to reach ports 3000 (web UI) and 443 on the instances. Tighten to your /32, or keep the UI private behind a tunnel."
  type        = string
  default     = "0.0.0.0/0"
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
