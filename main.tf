###############################################################################
# cancel-probe: a ~5 minute apply that creates nothing.
#
# Purpose: find out what GitHub Actions cancellation actually DOES to a running
# terraform process, with no cloud resources in the way.
#
# This does NOT reproduce "the cloud operation keeps running" -- everything here
# is local, so a kill really does stop it. That comes in a later step. What this
# tells you now:
#
#   * how many seconds elapse between clicking Cancel and the step dying
#   * whether terraform receives SIGINT and prints its graceful-shutdown message
#     ("Interrupt received. Please wait for Terraform to exit...")
#   * whether it finishes the in-flight stage before exiting, or dies mid-stage
#   * whether `if: cancelled()` / `if: always()` steps run, and how long they get
#
# Five stages, 60s each, each printing a timestamped heartbeat so you know
# exactly where the cancel landed.
#
# Stage 3 is deliberately a different mechanism: time_sleep waits INSIDE the
# provider process, while the others wait in a local-exec CHILD process. Signal
# handling differs between the two, and that difference is the interesting part.
#
#   terraform init
#   terraform apply -auto-approve
#
# Note on quoting: the shell blocks below contain no '%' characters on purpose.
# HCL treats %{ as a template directive, and date's +%H style formats are a
# constant source of escaping bugs here. `date -uIseconds` and bash's $SECONDS
# avoid the problem entirely.
###############################################################################

###############################################################################
# Remote state, on Azure Blob, so the GitHub Actions Plan step exercises real
# state locking (not just local resources).
#
# Bootstrapping this from nothing is a two-step dance, because the storage
# account that holds this module's state can't be created by the same apply
# that's already storing state inside it:
#
#   1. Comment out the `backend "azurerm" {}` block below, then:
#        terraform init
#        terraform apply -target=azurerm_storage_account.tfstate \
#                         -target=azurerm_storage_container.tfstate \
#                         -target=azurerm_role_assignment.me_blob \
#                         -target=azurerm_user_assigned_identity.github \
#                         -target=azurerm_federated_identity_credential.github_main \
#                         -target=azurerm_role_assignment.github_blob
#   2. Copy the storage_account_name output into the backend block, uncomment
#      it, then:
#        terraform init -migrate-state
#      This moves local state (including the storage account resources
#      themselves) into the blob it just created.
#
# After that, `terraform apply` with no -target manages everything, including
# the cancel-probe stages below, through the remote backend.
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # storage_account_name comes from `terraform output storage_account_name`
  # -- see the bootstrap instructions above. Leave this block commented out
  # until that storage account exists.
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-cancel-guard"
    storage_account_name = "stcgtfstatef0d9qy"
    container_name       = "tfstate"
    key                  = "cancel-guard.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "github_oidc_subject" {
  description = <<-EOT
    The exact subject claim GitHub presents. Standard form for a repo with
    default (non-immutable) subject claims is:
      repo:chamber-prime/cancel-guard:ref:refs/heads/main
    If auth fails with AADSTS700213, the repo has immutable subject claims
    enabled -- copy the exact subject out of that error instead, e.g.
      repo:chamber-prime@<ownerId>/cancel-guard@<repoId>:ref:refs/heads/main
  EOT
  type        = string
  default     = "repo:chamber-prime@312469008/cancel-guard@1338427675:ref:refs/heads/main"
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-tfstate-cancel-guard"
  location = var.location
}

resource "azurerm_storage_account" "tfstate" {
  name                     = "stcgtfstate${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = azurerm_resource_group.tfstate.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  # Reachable over the internet (GitHub-hosted runners need a network path
  # in), but the container below stays private -- no anonymous blob access.
  # Auth is OIDC + RBAC only, never a public container.
  public_network_access_enabled = true

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# Bootstrap operator (you) also needs data-plane access to seed/migrate state.
resource "azurerm_role_assignment" "me_blob" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

########################################
# GitHub Actions OIDC identity
########################################

resource "azurerm_user_assigned_identity" "github" {
  name                = "id-github-cancel-guard"
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location
}

resource "azurerm_federated_identity_credential" "github_main" {
  name                      = "github-main"
  user_assigned_identity_id = azurerm_user_assigned_identity.github.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = var.github_oidc_subject
}

# Data plane only -- this identity's whole job is reading/writing/locking
# the state blob from the terraform plan step. It creates no cloud resources.
resource "azurerm_role_assignment" "github_blob" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.github.principal_id
  principal_type       = "ServicePrincipal"
}

output "storage_account_name" {
  value = azurerm_storage_account.tfstate.name
}

output "resource_group_name" {
  value = azurerm_resource_group.tfstate.name
}

# Set these as repo variables in GitHub (Settings -> Secrets and variables ->
# Actions -> Variables): AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID
output "github_identity_client_id" {
  value = azurerm_user_assigned_identity.github.client_id
}

output "azure_tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "azure_subscription_id" {
  value = data.azurerm_client_config.current.subscription_id
}

variable "stage_seconds" {
  description = "Seconds per stage. 5 stages, so 60 gives a ~5 minute apply."
  type        = number
  default     = 60
}

# ---------------------------------------------------------------------------
# Stage 1 -- local-exec, i.e. a CHILD process of terraform
# ---------------------------------------------------------------------------
resource "null_resource" "stage_1" {
  triggers = { always = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -u
      echo "=============================================="
      echo "STAGE 1 START  $(date -uIseconds)"
      echo "=============================================="
      SECONDS=0
      while [ "$SECONDS" -lt ${var.stage_seconds} ]; do
        echo "[$(date -uIseconds)] stage 1 alive, $(( ${var.stage_seconds} - SECONDS ))s remaining"
        sleep 5
      done
      echo "STAGE 1 COMPLETE  $(date -uIseconds)"
    EOT
  }
}

# ---------------------------------------------------------------------------
# Stage 2 -- local-exec child process
# ---------------------------------------------------------------------------
resource "null_resource" "stage_2" {
  depends_on = [null_resource.stage_1]
  triggers   = { always = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -u
      echo "=============================================="
      echo "STAGE 2 START  $(date -uIseconds)"
      echo "=============================================="
      SECONDS=0
      while [ "$SECONDS" -lt ${var.stage_seconds} ]; do
        echo "[$(date -uIseconds)] stage 2 alive, $(( ${var.stage_seconds} - SECONDS ))s remaining"
        sleep 5
      done
      echo "STAGE 2 COMPLETE  $(date -uIseconds)"
    EOT
  }
}

# ---------------------------------------------------------------------------
# Stage 3 -- the contrast. This wait happens inside the PROVIDER process, not in
# a child shell, and produces no output while it runs. Cancel here and compare
# terraform's behaviour with stages 1/2/4/5.
# ---------------------------------------------------------------------------
resource "null_resource" "stage_3_start" {
  depends_on = [null_resource.stage_2]
  triggers   = { always = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "echo \"STAGE 3 START (provider-side wait, silent for ${var.stage_seconds}s)  $(date -uIseconds)\""
  }
}

resource "time_sleep" "stage_3" {
  depends_on      = [null_resource.stage_3_start]
  create_duration = "${var.stage_seconds}s"
  triggers        = { always = timestamp() }
}

resource "null_resource" "stage_3_end" {
  depends_on = [time_sleep.stage_3]
  triggers   = { always = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "echo \"STAGE 3 COMPLETE  $(date -uIseconds)\""
  }
}

# ---------------------------------------------------------------------------
# Stage 4 -- local-exec child process
# ---------------------------------------------------------------------------
resource "null_resource" "stage_4" {
  depends_on = [null_resource.stage_3_end]
  triggers   = { always = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -u
      echo "=============================================="
      echo "STAGE 4 START  $(date -uIseconds)"
      echo "=============================================="
      SECONDS=0
      while [ "$SECONDS" -lt ${var.stage_seconds} ]; do
        echo "[$(date -uIseconds)] stage 4 alive, $(( ${var.stage_seconds} - SECONDS ))s remaining"
        sleep 5
      done
      echo "STAGE 4 COMPLETE  $(date -uIseconds)"
    EOT
  }
}

# ---------------------------------------------------------------------------
# Stage 5 -- local-exec child process
# ---------------------------------------------------------------------------
resource "null_resource" "stage_5" {
  depends_on = [null_resource.stage_4]
  triggers   = { always = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -u
      echo "=============================================="
      echo "STAGE 5 START  $(date -uIseconds)"
      echo "=============================================="
      SECONDS=0
      while [ "$SECONDS" -lt ${var.stage_seconds} ]; do
        echo "[$(date -uIseconds)] stage 5 alive, $(( ${var.stage_seconds} - SECONDS ))s remaining"
        sleep 5
      done
      echo "APPLY REACHED THE END -- you did not cancel in time  $(date -uIseconds)"
    EOT
  }
}
