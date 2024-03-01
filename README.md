Next.js Application Deployment on GCP with Kubernetes and PostgreSQL

This project demonstrates deploying a scalable Next.js application on Google Cloud Platform (GCP) utilizing Kubernetes for orchestration and PostgreSQL for data persistence. The infrastructure is provisioned and managed using Terraform, ensuring a reproducible and declarative setup.

Overview
The architecture includes a GCP-managed Kubernetes cluster (GKE) hosting the Next.js application, a PostgreSQL database either deployed within the cluster or as a managed Cloud SQL instance, and Terraform scripts for infrastructure setup. This setup aims to leverage cloud-native technologies for high availability, scalability, and security.

Prerequisites
Google Cloud Platform (GCP) account
Terraform installed on your local machine
Google Cloud SDK (gcloud) and kubectl installed
Docker for building and pushing the Next.js application image
Repository Structure
/terraform: Contains Terraform configurations for provisioning GCP resources.
/kubernetes: Kubernetes manifests for deploying the Next.js application and related services.
Dockerfile: Dockerfile for containerizing the Next.js application.
README.md: Documentation for setting up and deploying the project.
Architecture.