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
  }
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
