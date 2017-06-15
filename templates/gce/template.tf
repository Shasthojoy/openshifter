variable "account" {
  type = "string"
  default = "{{.Gce.Account}}"
}

variable "infra" {
  type = "string"
  default = "{{if .Nodes.Infra}}true{{else}}false{{end}}"
}

variable "nodes" {
  type = "string"
  default = "{{.Nodes.Count}}"
}

variable "type" {
  type = "string"
  default = "{{.Type}}"
}

variable "ssh_key" {
  type = "string"
  default = "{{.Ssh.Key}}"
}

variable "post_install" {
  type = "list"
  default = [
    "sudo bash -c 'yum -y update'",
    "sudo bash -c 'yum install -y docker'",
    "sudo bash -c 'echo DEVS=/dev/sdb >> /etc/sysconfig/docker-storage-setup'",
    "sudo bash -c 'echo VG=DOCKER >> /etc/sysconfig/docker-storage-setup'",
    "sudo bash -c 'echo SETUP_LVM_THIN_POOL=yes >> /etc/sysconfig/docker-storage-setup'",
    "sudo bash -c 'echo DATA_SIZE=\"70%FREE\" >> /etc/sysconfig/docker-storage-setup'",
    "sudo bash -c 'systemctl stop docker'",
    "sudo bash -c 'rm -rf /var/lib/docker'",
    "sudo bash -c 'wipefs --all /dev/sdb'",
    "sudo bash -c 'docker-storage-setup'",
    "sudo bash -c 'systemctl start docker'",
    "sudo bash -c 'lvcreate -l 100%FREE -n PVS DOCKER'",
    "sudo bash -c 'mkfs.xfs /dev/mapper/DOCKER-PVS'",
    "sudo bash -c 'mkdir -p /var/lib/origin/openshift.local.volumes'",
    "sudo bash -c 'mount /dev/mapper/DOCKER-PVS /var/lib/origin/openshift.local.volumes'",
    "sudo bash -c 'echo \"/dev/mapper/DOCKER-PVS /var/lib/origin/openshift.local.volumes xfs defaults 0 1\" >> /etc/fstab'",
    "sudo bash -c 'mkdir -p /pvs'",
    {{if and (eq .Components.pvs true) (eq .Pvs.Type "gluster")}}
    "sudo bash -c 'yum install -y centos-release-gluster310'",
    "sudo bash -c 'yum install -y glusterfs gluster-cli glusterfs-libs glusterfs-fuse'",
    "sudo bash -c 'mount -t glusterfs {{.Name}}-pvs:/pvs /pvs'",
    {{end}}
  ]
}

variable "pvs_install" {
  type = "list"
  default = [
    "sudo bash -c ''",
    "sudo bash -c 'yum -y update'",
    "sudo bash -c 'yum install -y centos-release-gluster310'",
    "sudo bash -c 'yum install -y glusterfs gluster-cli glusterfs-libs glusterfs-server'",
    "sudo bash -c 'pvcreate /dev/sdb'",
    "sudo bash -c 'vgcreate PVS /dev/sdb'",
    "sudo bash -c 'lvcreate -l 100%FREE -n PVS PVS'",
    "sudo bash -c 'mkfs.xfs -i size=512 /dev/mapper/PVS-PVS'",
    "sudo bash -c 'mkdir -p /data/brick1'",
    "sudo bash -c 'echo \"/dev/mapper/PVS-PVS /data/brick1 xfs defaults 1 2\" >> /etc/fstab'",
    "sudo bash -c 'mount -a && mount'",
    "sudo bash -c 'systemctl start glusterd'",
    "sudo bash -c 'systemctl enable glusterd'",
    "sudo bash -c 'mkdir -p /data/brick1/pvs'",
    "sudo bash -c 'gluster volume create pvs {{.Name}}-pvs:/data/brick1/pvs'",
    "sudo bash -c 'gluster volume start pvs'",
    "sudo bash -c 'gluster volume info'",
  ]
}

provider "google" {
  credentials = "${file(var.account)}"
  project     = "{{.Gce.Project}}"
  region      = "{{.Gce.Region}}"
}

resource "google_compute_network" "network" {
  name                    = "{{.Name}}"
  auto_create_subnetworks = "true"
}

resource "google_compute_firewall" "firewall-all" {
  name    = "{{.Name}}-all"
  network = "${google_compute_network.network.name}"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "firewall-internal" {
  name    = "{{.Name}}-internal"
  network = "${google_compute_network.network.name}"

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  source_ranges = ["10.128.0.0/9"]
}

resource "google_compute_firewall" "firewall-master" {
  name    = "{{.Name}}-master"
  network = "${google_compute_network.network.name}"

  allow {
    protocol = "tcp"
    ports    = ["8443"]
  }

  target_tags = ["master"]
}

resource "google_compute_firewall" "firewall-infra" {
  name    = "{{.Name}}-infra"
  network = "${google_compute_network.network.name}"

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "30000-32767"]
  }

  target_tags = ["infra"]
}

resource "google_compute_address" "address_master" {
  name = "{{.Name}}-master"
}

resource "google_compute_address" "address_infra" {
  count = "{{if .Nodes.Infra}}1{{else}}0{{end}}"
  name = "{{.Name}}-infra"
}

resource "google_compute_disk" "disk_master_root" {
  name  = "{{.Name}}-master-root"
  type  = "pd-ssd"
  zone  = "{{.Gce.Zone}}"
  image = "${var.type == "ocp" ? "rhel-cloud/rhel-7" : "centos-cloud/centos-7"}"
}

resource "google_compute_disk" "disk_master_docker" {
  name  = "{{.Name}}-master-docker"
  type  = "pd-ssd"
  zone  = "{{.Gce.Zone}}"
  size  = "{{.Nodes.Disk.Size}}"
}

resource "google_compute_instance" "master" {
  count        = 1
  name         = "{{.Name}}-master"
  machine_type = "{{.Nodes.Type}}"
  zone         = "{{.Gce.Zone}}"

  tags         = ["master", "${var.infra == "true" ? "master" : "infra"}", "${var.nodes == "0" ? "node" : "master"}"]

  {{if and (eq .Components.pvs true) (eq .Pvs.Type "gluster")}}
  depends_on = ["google_compute_instance.pvs"]
  {{end}}

  disk {
    disk = "${google_compute_disk.disk_master_root.name}"
  }

  disk {
    disk = "${google_compute_disk.disk_master_docker.name}"
  }

  metadata {
    ssh-keys = "openshift:${file("${var.ssh_key}.pub")}"
  }

  network_interface {
    network = "${google_compute_network.network.name}"
    access_config {
      nat_ip = "${google_compute_address.address_master.address}"
    }
  }

  {{if ne .Gce.ServiceAccount ""}}
  service_account {
    email  = "{{.Gce.ServiceAccount}}"
    scopes = ["userinfo-email", "compute-rw", "storage-rw"]
  }
  {{end}}

  provisioner "remote-exec" {
    connection {
      user = "openshift"
      private_key = "${file("${var.ssh_key}")}"
    }
    inline = "${var.post_install}"
  }

}

resource "google_compute_disk" "disk_infra_root" {
  count = "{{if .Nodes.Infra}}1{{else}}0{{end}}"
  name  = "{{.Name}}-infra-root"
  type  = "pd-ssd"
  zone  = "{{.Gce.Zone}}"
  image = "${var.type == "ocp" ? "rhel-cloud/rhel-7" : "centos-cloud/centos-7"}"
}

resource "google_compute_disk" "disk_infra_docker" {
  count = "{{if .Nodes.Infra}}1{{else}}0{{end}}"
  name  = "{{.Name}}-infra-docker"
  type  = "pd-ssd"
  zone  = "{{.Gce.Zone}}"
  size  = "{{.Nodes.Disk.Size}}"
}

resource "google_compute_instance" "infra" {
  count        = "{{if .Nodes.Infra}}1{{else}}0{{end}}"
  name         = "{{.Name}}-infra"
  machine_type = "{{.Nodes.Type}}"
  zone         = "{{.Gce.Zone}}"
  tags = ["infra"]

  {{if and (eq .Components.pvs true) (eq .Pvs.Type "gluster")}}
  depends_on = ["google_compute_instance.pvs"]
  {{end}}

  disk {
    disk = "${google_compute_disk.disk_infra_root.name}"
  }

  disk {
    disk = "${google_compute_disk.disk_infra_docker.name}"
  }

  metadata {
    ssh-keys = "openshift:${file("${var.ssh_key}.pub")}"
  }

  network_interface {
    network = "${google_compute_network.network.name}"
    access_config {
      nat_ip = "${google_compute_address.address_infra.address}"
    }
  }

  {{if ne .Gce.ServiceAccount ""}}
  service_account {
    email  = "{{.Gce.ServiceAccount}}"
    scopes = ["userinfo-email", "compute-rw", "storage-rw"]
  }
  {{end}}

  provisioner "remote-exec" {
    connection {
      user = "openshift"
      private_key = "${file("${var.ssh_key}")}"
    }
    inline = "${var.post_install}"
  }

}

{{if and (eq .Components.pvs true) (eq .Pvs.Type "gluster")}}
resource "google_compute_disk" "disk_pvs_root" {
  name  = "{{.Name}}-pvs-root"
  type  = "pd-ssd"
  zone  = "{{.Gce.Zone}}"
  image = "${var.type == "ocp" ? "rhel-cloud/rhel-7" : "centos-cloud/centos-7"}"
}

resource "google_compute_disk" "disk_pvs_docker" {
  name  = "{{.Name}}-pvs-docker"
  type  = "pd-ssd"
  zone  = "{{.Gce.Zone}}"
  size  = "{{.Nodes.Disk.Size}}"
}

resource "google_compute_instance" "pvs" {
  count        = "1"
  name         = "{{.Name}}-pvs"
  machine_type = "n1-standard-1"
  zone         = "{{.Gce.Zone}}"
  tags         = ["pvs"]

  disk {
    disk = "{{.Name}}-pvs-root"
  }

  disk {
    disk = "{{.Name}}-pvs-docker"
  }

  metadata {
    ssh-keys = "openshift:${file("${var.ssh_key}.pub")}"
  }

  network_interface {
    network = "${google_compute_network.network.name}"
    access_config {
    }
  }

  {{if ne .Gce.ServiceAccount ""}}
  service_account {
    email  = "{{.Gce.ServiceAccount}}"
    scopes = ["userinfo-email", "compute-rw", "storage-rw"]
  }
  {{end}}

  provisioner "remote-exec" {
    connection {
      user = "openshift"
      private_key = "${file("${var.ssh_key}")}"
    }
    inline = "${var.pvs_install}"
  }

}
{{end}}

resource "google_compute_disk" "disk_node_root" {
  count = "${var.nodes}"
  name  = "{{.Name}}-node-${count.index}-root"
  type  = "pd-ssd"
  zone  = "{{.Gce.Zone}}"
  image = "${var.type == "ocp" ? "rhel-cloud/rhel-7" : "centos-cloud/centos-7"}"
}

resource "google_compute_disk" "disk_node_docker" {
  count = "${var.nodes}"
  name  = "{{.Name}}-node-${count.index}-docker"
  type  = "pd-ssd"
  zone  = "{{.Gce.Zone}}"
  size  = "{{.Nodes.Disk.Size}}"
}

resource "google_compute_instance" "node" {
  count        = "${var.nodes}"
  name         = "{{.Name}}-node-${count.index}"
  machine_type = "{{.Nodes.Type}}"
  zone         = "{{.Gce.Zone}}"
  tags         = ["node"]

  {{if and (eq .Components.pvs true) (eq .Pvs.Type "gluster")}}
  depends_on = ["google_compute_instance.pvs"]
  {{end}}

  disk {
    disk = "{{.Name}}-node-${count.index}-root"
  }

  disk {
    disk = "{{.Name}}-node-${count.index}-docker"
  }

  metadata {
    ssh-keys = "openshift:${file("${var.ssh_key}.pub")}"
  }

  network_interface {
    network = "${google_compute_network.network.name}"
    access_config {
    }
  }

  {{if ne .Gce.ServiceAccount ""}}
  service_account {
    email  = "{{.Gce.ServiceAccount}}"
    scopes = ["userinfo-email", "compute-rw", "storage-rw"]
  }
  {{end}}

  provisioner "remote-exec" {
    connection {
      user = "openshift"
      private_key = "${file("${var.ssh_key}")}"
    }
    inline = "${var.post_install}"
  }

}

{{if ne .Dns.Zone "nip"}}
resource "google_dns_record_set" "dns_master" {
  name = "console.{{.Name}}.{{.Dns.Suffix}}."
  type = "A"
  ttl  = 60

  managed_zone = "{{.Dns.Zone}}"

  rrdatas = ["${google_compute_address.address_master.address}"]
}

resource "google_dns_record_set" "dns_apps" {
  name = "*.apps.{{.Name}}.{{.Dns.Suffix}}."
  type = "A"
  ttl  = 60

  managed_zone = "{{.Dns.Zone}}"

  rrdatas = ["{{if .Nodes.Infra}}${google_compute_address.address_infra.address}{{else}}${google_compute_address.address_master.address}{{end}}"]
}
{{end}}

output "master" {
  value = "${google_compute_address.address_master.address}"
}

output "infra" {
  value = "{{if .Nodes.Infra}}${google_compute_address.address_infra.address}{{else}}${google_compute_address.address_master.address}{{end}}"
}

output "nodes" {
  value = "${join(",", google_compute_instance.node.*.network_interface.0.access_config.0.assigned_nat_ip)}"
}
