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
  default     = "10.99.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR for the public subnet inside the VPC."
  type        = string
  default     = "10.99.1.0/24"
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
  description = "Pool of secondary private IPs assigned to the data plane ENI. Each IP becomes a slot in Ubicloud's routed_network pool. One EIP is allocated + associated with each, so each slot can host a publicly-reachable VM. Pool size = max concurrent VMs publicly reachable from the internet."
  type        = list(string)
  default = [
    "10.99.1.128",
    "10.99.1.129",
    "10.99.1.130",
  ]
}
