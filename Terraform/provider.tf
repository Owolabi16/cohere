terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 3.5"
    }
  }

  required_version = ">= 0.12"
}

terraform {
  backend "gcs" {
    bucket = "gcp-k8s-cluster-bucket"
    prefix = "terraform/state"
  }
}


provider "google" {
  project = "gcp-kubernetes-cluster-415821"
  region  = var.region
}
