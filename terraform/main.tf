terraform {
  required_version = ">= 1.5.0"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.50"
    }
  }
}

variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "server_type" {
  type    = string
  default = "cx32"
}

provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_ssh_key" "deployer" {
  name       = "bubblemaps-deployer"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "hcloud_firewall" "bubblemaps" {
  name = "bubblemaps"

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = [
      "0.0.0.0/0",
      "::/0",
    ]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "80"
    source_ips = [
      "0.0.0.0/0",
      "::/0",
    ]
  }
}

resource "hcloud_server" "bubblemaps" {
  name         = "bubblemaps-k3s"
  image        = "ubuntu-24.04"
  server_type  = var.server_type
  location     = "fsn1"
  ssh_keys     = [hcloud_ssh_key.deployer.id]
  firewall_ids = [hcloud_firewall.bubblemaps.id]

  user_data = <<-CLOUD_INIT
    #cloud-config
    package_update: true
    packages:
      - docker.io
    runcmd:
      - systemctl enable --now docker
      - curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 600
  CLOUD_INIT

  labels = {
    project = "bubblemaps"
  }
}

output "public_ip" {
  value = hcloud_server.bubblemaps.ipv4_address
}

output "api_url" {
  value = "http://${hcloud_server.bubblemaps.ipv4_address}"
}
