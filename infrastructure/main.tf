terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}


# -----------------------------------------------------------------------------
# 1. Project Configuration & Variables
# -----------------------------------------------------------------------------
variable "gcp_project_id" {
  description = "Google Cloud Project ID"
  default     = "artems-hub"
}

variable "gcp_region" {
  description = "The region for Cloud Run and Artifact Registry"
  default     = "us-east1"
}

variable "app_name" {
  description = "The name for the Cloud Run service and Artifact Repo"
  default     = "artems-hub"
}

variable "custom_domain" {
  description = "The custom domain name to map to the Cloud Run service."
  default     = "artemshub.com.de"
}

variable "github_org" {
  description = "GitHub organization or username."
  default     = "ArtKomarov"
}

variable "github_repo" {
  description = "GitHub repository name."
  default     = "ArtemsHub"
}

# Configure the GCP provider
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

data "google_project" "project" {}

# Enable the necessary APIs
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "iamcredentials.googleapis.com", # Required for Workload Identity Federation
  ])
  project            = var.gcp_project_id
  service            = each.key
  disable_on_destroy = false
}

# -----------------------------------------------------------------------------
# 2. Artifact Registry (Docker Image Repository)
# -----------------------------------------------------------------------------

resource "google_artifact_registry_repository" "repo" {
  project       = var.gcp_project_id
  location      = var.gcp_region
  repository_id = "${var.app_name}-repo" # artems-hub-repo
  format        = "DOCKER"
  description   = "Docker repository for Artem's Hub"
  depends_on    = [google_project_service.apis]

  # Cost Management: Define cleanup policies to prevent image buildup
  cleanup_policies {
    id     = "free-tier-limit-count"
    action = "KEEP"
    most_recent_versions {
      # Keep the 10 most recently created images globally (regardless of age)
      keep_count = 10
    }
  }
  # Try to delete everything (the shield stops it from hitting the top 10)
  cleanup_policies {
    id     = "delete-old-versions"
    action = "DELETE"
    condition {
      tag_state = "ANY"
    }
  }
}

# -----------------------------------------------------------------------------
# 3. Cloud Run Service Definition
# -----------------------------------------------------------------------------

resource "google_cloud_run_v2_service" "service" {
  project     = var.gcp_project_id
  location    = var.gcp_region
  name        = var.app_name
  description = "Portfolio website"
  # Explicitly allow all public traffic
  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    # Cost Optimization: Scaling limits
    scaling {
      min_instance_count = 0 # Ensures scale-to-zero when idle
      max_instance_count = 1 # Crucial for free-tier cost control
    }

    containers {
      image = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${google_artifact_registry_repository.repo.repository_id}/${var.app_name}:latest"
      # Cost Optimization: Resource limits
      resources {
        cpu_idle          = true
        startup_cpu_boost = true
        limits = {
          memory = "256Mi"
          cpu    = "1000m"
        }
      }
    }
  }

  # Allow unauthenticated access (since this is a public portfolio)
  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  lifecycle {
    prevent_destroy = true
    # We ignore changes to the image (managed by GitHub Actions) 
    # and labels/annotations/client info (added by the deploy action metadata)
    ignore_changes = [
      template[0].containers[0].image,
      template[0].labels,
      template[0].annotations,
      client,
      client_version
    ]
  }
}

# -----------------------------------------------------------------------------
# 4. Custom Domain Mapping
# -----------------------------------------------------------------------------

resource "google_cloud_run_domain_mapping" "domain_mapping" {
  location = var.gcp_region
  name     = var.custom_domain

  metadata {
    namespace = var.gcp_project_id
  }

  spec {
    # 'route_name' specifies the name of the Cloud Run service to map to.
    route_name = google_cloud_run_v2_service.service.name
  }

  # Ensures the Cloud Run service is stable before attempting to map the domain
  depends_on = [google_cloud_run_v2_service.service]
}


# -----------------------------------------------------------------------------
# 5. Workload Identity Federation (WIF) for Secure CI/CD
# -----------------------------------------------------------------------------

# 5a. Dedicated Service Account for CI/CD
resource "google_service_account" "github_sa" {
  project      = var.gcp_project_id
  account_id   = "github-deployer"
  display_name = "GitHub Actions Cloud Run Deployer"
}

# 5b. Workload Identity Pool (One per project/organization)
resource "google_iam_workload_identity_pool" "github_pool" {
  project                   = var.gcp_project_id
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions Pool"
}

# 5c. Provider that links the Pool to GitHub
resource "google_iam_workload_identity_pool_provider" "github_provider" {
  project                            = var.gcp_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub Provider"

  # Standard attribute mapping for OIDC
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
  }

  attribute_condition = "attribute.repository == \"${var.github_org}/${var.github_repo}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# 5d. IAM Binding: Allow the GitHub Repo to impersonate the Service Account
resource "google_service_account_iam_member" "github_access" {
  service_account_id = google_service_account.github_sa.name
  role               = "roles/iam.workloadIdentityUser"

  # This condition only allows tokens coming from the specific GitHub repository (ArtKomarov/ArtemsHub)
  member = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/attribute.repository/${var.github_org}/${var.github_repo}"
}

# 5e. IAM Binding: Give the Service Account permissions to build/deploy/manage
resource "google_project_iam_member" "deployer_roles" {
  for_each = toset([
    "roles/artifactregistry.writer", # To push Docker images
    "roles/run.admin",               # To manage and deploy Cloud Run services
    "roles/iam.serviceAccountUser",  # To deploy Cloud Run service as itself
  ])
  project = var.gcp_project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.github_sa.email}"
}


# -----------------------------------------------------------------------------
# OUTPUTS
# -----------------------------------------------------------------------------

# Output the Service Account email needed for the GitHub Actions workflow file
output "gcp_service_account_email" {
  description = "Service Account Email for GitHub Actions"
  value       = google_service_account.github_sa.email
}

# Output the WIF Provider name needed for the GitHub Actions workflow file
output "wif_provider_name" {
  description = "Workload Identity Provider Name for GitHub Actions"
  value       = "projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github_pool.workload_identity_pool_id}/providers/${google_iam_workload_identity_pool_provider.github_provider.workload_identity_pool_provider_id}"
}
