# ==============================================================
#  terraform/aws-byoh/main.tf
#  Ubicloud BYOH (generic provider) test infrastructure on AWS
# ==============================================================
#
# Provisions a complete Ubicloud BYOH test environment in a single
# AWS region:
#
#   - Dedicated VPC (10.99.0.0/16) isolated from any existing infra
#   - Public subnet with internet gateway + route table
#   - Security group: SSH from operator's IP + web UI from anywhere
#   - Generated Ed25519 keypair (saved to .generated/ locally)
#   - Control plane instance (t3.medium, Ubuntu 24.04)
#   - Data plane instance (m5d.metal bare-metal, Ubuntu 24.04)
#       + N secondary private IPs on the ENI (the BYOH IP pool)
#       + source_dest_check disabled (so kernel can forward to VMs)
#       + user-data: allow root SSH, pre-install ruby-bundler
#   - N Elastic IPs, each 1:1 associated with a secondary private IP
#
# This is the AWS-specific provider pre-work. On Hetzner/OVH/
# Equinix/Leaseweb the equivalent is "order a routed block via the
# provider panel" — no terraform needed because the provider's core
# routers handle routing. AWS is unusual in requiring this kind of
# declarative plumbing.
#
# Usage:
#   cd terraform/aws-byoh
#   cp terraform.tfvars.example terraform.tfvars
#   edit terraform.tfvars with your aws_region + operator_cidr
#   export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
#   terraform init
#   terraform apply
#
# Tear down:
#   terraform destroy

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  project_tag = "ubicloud-byoh-test"
  base_tags = {
    Project   = local.project_tag
    Owner     = "byoh-validation"
    ManagedBy = "terraform"
    Module    = "terraform/aws-byoh"
  }
}

# --- Pick the latest Ubuntu 24.04 LTS AMI (Canonical-owned) ---------
data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# --- VPC + subnet + IGW + route table -------------------------------
resource "aws_vpc" "byoh" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.base_tags, { Name = "ubi-byoh-test-vpc" })
}

resource "aws_subnet" "byoh" {
  vpc_id                  = aws_vpc.byoh.id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags                    = merge(local.base_tags, { Name = "ubi-byoh-test-subnet" })
}

resource "aws_internet_gateway" "byoh" {
  vpc_id = aws_vpc.byoh.id
  tags   = merge(local.base_tags, { Name = "ubi-byoh-test-igw" })
}

resource "aws_route_table" "byoh" {
  vpc_id = aws_vpc.byoh.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.byoh.id
  }
  tags = merge(local.base_tags, { Name = "ubi-byoh-test-rtb" })
}

resource "aws_route_table_association" "byoh" {
  subnet_id      = aws_subnet.byoh.id
  route_table_id = aws_route_table.byoh.id
}

# --- Security group -------------------------------------------------
resource "aws_security_group" "byoh" {
  name        = "ubi-byoh-test-sg"
  description = "Ubicloud BYOH test: SSH + web UI + intra-SG"
  vpc_id      = aws_vpc.byoh.id
  tags        = merge(local.base_tags, { Name = "ubi-byoh-test-sg" })

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.operator_ssh_cidr]
  }

  ingress {
    description = "SSH for VMs (open — VMs get individual EIPs)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Ubicloud web UI (puma)"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS (optional TLS termination)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Intra-SG all traffic (ctrl→data comms + VM-to-VM)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Generated SSH keypair (saved to .generated/ locally) -----------
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "byoh" {
  key_name   = "ubi-byoh-test-key"
  public_key = tls_private_key.ssh.public_key_openssh
  tags       = merge(local.base_tags, { Name = "ubi-byoh-test-key" })
}

resource "local_sensitive_file" "ssh_private" {
  filename        = "${path.module}/.generated/byoh_ssh_key"
  content         = tls_private_key.ssh.private_key_openssh
  file_permission = "0600"
}

resource "local_file" "ssh_public" {
  filename        = "${path.module}/.generated/byoh_ssh_key.pub"
  content         = tls_private_key.ssh.public_key_openssh
  file_permission = "0644"
}

# --- Control plane instance -----------------------------------------
resource "aws_instance" "ctrl" {
  ami                         = data.aws_ami.ubuntu_2404.id
  instance_type               = var.ctrl_plane_instance_type
  key_name                    = aws_key_pair.byoh.key_name
  subnet_id                   = aws_subnet.byoh.id
  vpc_security_group_ids      = [aws_security_group.byoh.id]
  associate_public_ip_address = true
  source_dest_check           = true

  root_block_device {
    volume_size           = var.ctrl_root_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = file("${path.module}/user-data-ctrl.sh")

  tags = merge(local.base_tags, {
    Name = "ubi-byoh-ctrl"
    Role = "control-plane"
  })
}

# --- Data plane instance (bare metal) -------------------------------
resource "aws_instance" "data" {
  ami                         = data.aws_ami.ubuntu_2404.id
  instance_type               = var.data_plane_instance_type
  key_name                    = aws_key_pair.byoh.key_name
  subnet_id                   = aws_subnet.byoh.id
  vpc_security_group_ids      = [aws_security_group.byoh.id]
  associate_public_ip_address = true

  # CRITICAL: the data plane forwards packets destined for the BYOH
  # VM IPs (the secondary private IPs) to the VMs' taps. AWS rejects
  # packets from instances whose source IP doesn't match their primary
  # IP unless source/dest check is disabled. This is the standard
  # pattern for "instance as a router" (NAT instances, VPN gateways,
  # etc.) that AWS officially supports.
  source_dest_check = false

  # The BYOH IP pool — secondary private IPs assigned to the primary
  # ENI at AWS-fabric level. AWS delivers any packet in the VPC
  # destined for these IPs to this instance's ENI. Ubicloud's
  # run_nftables prog then adds per-VM routes (`ip route add <ip>
  # dev <vm-veth>`) so the kernel forwards each packet to the right
  # VM's netns.
  secondary_private_ips = var.byoh_secondary_private_ips

  root_block_device {
    volume_size           = var.data_root_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = file("${path.module}/user-data-data.sh")

  tags = merge(local.base_tags, {
    Name = "ubi-byoh-data"
    Role = "data-plane"
  })
}

# --- Elastic IPs + 1:1 associations with secondary private IPs ------
# Each EIP becomes a publicly-reachable address for one VM. When a
# VM is allocated the matching private IP, it becomes the VM that's
# reachable from the internet via that EIP. AWS edge DNATs inbound
# traffic EIP → private IP → delivered to the instance's ENI → host
# kernel forwards to the VM's tap.
resource "aws_eip" "byoh" {
  count  = length(var.byoh_secondary_private_ips)
  domain = "vpc"
  tags = merge(local.base_tags, {
    Name          = "ubi-byoh-eip-${count.index}"
    PrivateTarget = var.byoh_secondary_private_ips[count.index]
  })
}

resource "aws_eip_association" "byoh" {
  count                = length(var.byoh_secondary_private_ips)
  allocation_id        = aws_eip.byoh[count.index].id
  network_interface_id = aws_instance.data.primary_network_interface_id
  private_ip_address   = var.byoh_secondary_private_ips[count.index]
  depends_on           = [aws_instance.data]
}
