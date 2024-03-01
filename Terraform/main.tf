#--------
#  VPC
#--------

resource "google_project_service" "compute" {
  service = "compute.googleapis.com"
}

resource "google_project_service" "container" {
  service = "container.googleapis.com"
}

resource "google_compute_network" "vpc" {
  name                            = "sam-vpc"
  routing_mode                    = "REGIONAL"
  auto_create_subnetworks         = false
  mtu                             = 1460
  delete_default_routes_on_create = false

  depends_on = [
    google_project_service.compute,
    google_project_service.container
  ]
}

#----------
# Subnet
#----------

resource "google_compute_subnetwork" "subnet" {
  name                     = "private-subnet"
  ip_cidr_range            = "10.0.0.0/18"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "k8s-pod-range"
    ip_cidr_range = "10.48.0.0/14"
  }
  secondary_ip_range {
    range_name    = "k8s-service-range"
    ip_cidr_range = "10.52.0.0/20"
  }
}

#--------------
# Cloud Router 
#--------------

resource "google_compute_router" "router" {
  name    = "sam-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

#-------------
# Cloud Nat
#-------------

resource "google_compute_router_nat" "nat" {
  name   = "sam-nat"
  router = google_compute_router.router.name
  region = var.region

  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  nat_ip_allocate_option             = "MANUAL_ONLY"

  subnetwork {
    name                    = google_compute_subnetwork.subnet.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  nat_ips = [google_compute_address.nat.self_link]
}

resource "google_compute_address" "nat" {
  name         = "nat"
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"

  depends_on = [google_project_service.compute]
}

#-------------
# GKE Cluster
#-------------

resource "google_container_cluster" "cluster" {
  name                     = "sam-cluster"
  location                 = "us-central1-a"
  remove_default_node_pool = true
  initial_node_count       = 1
  network                  = google_compute_network.vpc.self_link
  subnetwork               = google_compute_subnetwork.subnet.self_link
  networking_mode          = "VPC_NATIVE"

  node_locations = [
    "us-central1-b"
  ]

  addons_config {
    http_load_balancing {
      disabled = true
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "gcp-kubernetes-cluster-415821.svc.id.goog"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "k8s-pod-range"
    services_secondary_range_name = "k8s-service-range"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

}

#-------------
# Node groups
#-------------

resource "google_service_account" "kubernetes" {
  account_id = "kubernetes"
}

resource "google_container_node_pool" "Node" {
  name       = "sam-node"
  cluster    = google_container_cluster.cluster.id
  node_count = 1


  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    preemptible  = false
    machine_type = "e2-small"

    labels = {
      role = "sam"
    }

    service_account = google_service_account.kubernetes.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

#---------------
#Load Balancer
#---------------

resource "google_compute_address" "frontend_ip" {
  name   = "frontend-ip"
  region = var.region
}

resource "google_compute_global_forwarding_rule" "default" {
  name       = "k8s-app-forwarding-rule"
  target     = google_compute_target_http_proxy.default-HP.id
  port_range = "80"
  ip_address = google_compute_address.frontend_ip.address
}

#-----------------
# Load Balancer
#-----------------

# instance template
resource "google_compute_instance_template" "default-IT" {
  name         = "l7-xlb-mig-template"
  provider     = google-beta
  project      = var.project
  machine_type = "e2-small"
  tags         = ["allow-health-check"]

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {
      # add external ip to fetch packages
    }
  }
  disk {
    source_image = "debian-cloud/debian-10"
    auto_delete  = true
    boot         = true
  }
}

# MIG
resource "google_compute_instance_group_manager" "default-IG" {
  name     = "l7-xlb-mig1"
  project  = var.project
  provider = google-beta
  zone     = "us-central1-c"
  named_port {
    name = "http"
    port = 8080
  }
  version {
    instance_template = google_compute_instance_template.default-IT.id
    name              = "primary"
  }
  base_instance_name = "vm"
  target_size        = 2
}

# backend service with custom request and response headers
resource "google_compute_backend_service" "default-BS" {
  name                    = "l7-xlb-backend-service"
  provider                = google-beta
  protocol                = "HTTP"
  port_name               = "my-port"
  load_balancing_scheme   = "EXTERNAL"
  timeout_sec             = 10
  enable_cdn              = true
  custom_request_headers  = ["X-Client-Geo-Location: {client_region_subdivision}, {client_city}"]
  custom_response_headers = ["X-Cache-Hit: {cdn_cache_status}"]
  health_checks           = [google_compute_health_check.default.id]
  backend {
    group           = google_compute_instance_group_manager.default-IG.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# reserved IP address
resource "google_compute_global_address" "default-ip" {
  provider = google-beta
  project  = var.project
  name     = "l7-xlb-static-ip"
}

# url map
resource "google_compute_url_map" "default-url" {
  name            = "l7-xlb-url-map"
  provider        = google-beta
  default_service = google_compute_backend_service.default-BS.id
}

# http proxy
resource "google_compute_target_http_proxy" "default-HP" {
  name     = "l7-xlb-target-http-proxy"
  provider = google-beta
  url_map  = google_compute_url_map.default-url.id
}

# forwarding rule
resource "google_compute_global_forwarding_rule" "default-FR" {
  name                  = "l7-xlb-forwarding-rule"
  provider              = google-beta
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "80"
  target                = google_compute_target_http_proxy.default-HP.id
  ip_address            = google_compute_global_address.default-ip.id
}



# health check
resource "google_compute_health_check" "default" {
  name     = "l7-xlb-hc"
  project  = var.project
  provider = google-beta
  http_health_check {
    port_specification = "USE_SERVING_PORT"
  }
}



# allow access from health check ranges
resource "google_compute_firewall" "default" {
  name          = "l7-xlb-fw-allow-hc"
  project       = var.project
  provider      = google-beta
  direction     = "INGRESS"
  network       = google_compute_network.vpc.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  allow {
    protocol = "tcp"
  }
  target_tags = ["allow-health-check"]
}