terraform {
  required_version = ">= 1.9"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

# Authenticates from GITHUB_TOKEN in the environment: a token that can create the repository and
# change its settings. docs/repository-as-code.md records what that costs and why it is not in CI.
provider "github" {
  owner = var.owner
}

variable "owner" {
  description = "The account that owns the repository. In terraform.tfvars, which is git-ignored, for the same reason as the project id: one identifier, one home."
  type        = string
}

variable "name" {
  description = "The repository name."
  type        = string
  default     = "hyperchat"
}

variable "default_branch" {
  description = "The branch protection attaches to. It has to exist before this root is applied in full; see docs/repository-as-code.md."
  type        = string
  default     = "main"
}

resource "github_repository" "repo" {
  name        = var.name
  description = "A containerised agent on Cloud Run: evals, tracing, and a coding agent joined as an untrusted contributor"
  visibility  = "public"
  has_issues  = true
  has_wiki    = false
  auto_init   = false

  # `auto_init = false` on purpose: the history in this working directory is the history of the
  # repository, and an initial README commit would have to be reconciled with it before the first
  # push — which is a merge in a repository whose whole point is that it has one clean root.

  topics = [
    "fastapi",
    "docker",
    "terraform",
    "google-cloud",
    "cloud-run",
    "artifact-registry",
    "github-actions",
    "llm",
    "ai-agents",
    "langgraph",
    "evals",
    "prompt-injection",
  ]

  # Both free on a public repository, and both are the mechanism that makes "no secret has ever
  # been near this" a property rather than an intention.
  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }
}

# Reported alerts, and something that acts on them. The switch lives here rather than in
# `security_and_analysis`, which has six children and this is not one of them: the setting belongs
# where the other settings are, or it belongs to whoever remembers clicking it.
resource "github_repository_dependabot_security_updates" "repo" {
  repository = github_repository.repo.name
  enabled    = true
}

resource "github_branch_protection" "default" {
  repository_id = github_repository.repo.node_id
  pattern       = var.default_branch

  enforce_admins      = true
  allows_force_pushes = false
  allows_deletions    = false

  # One required check, and it is `ci`: the name the API reports for the job, not the workflow's
  # `name:` and not the job's `id`.
  #
  # `ref-not-main-cannot-auth` is deliberately *not* required. It is skipped on a fork pull request,
  # and a check that is skipped never reports success, so requiring it would block every contribution
  # from the fork — the opposite of what it is there to protect. The gate that protects `main` is the
  # one that runs everywhere.
  required_status_checks {
    # `strict = false`, which is a decision rather than a default: a branch that is behind `main` may
    # merge on a check that ran against its own base, instead of being required to be up to date
    # first. With one contributor and a serial merge order that costs nothing, and the review
    # invariant already requires the merged object to be the reviewed one — which a forced rebase
    # breaks. Turn it on the day two people merge concurrently and the base a check ran against stops
    # being the base that merges.
    strict   = false
    contexts = ["ci"]
  }

  # No required_pull_request_reviews: one account cannot approve its own pull request, and a required
  # approval that nobody can give blocks every merge. `enforce_admins = true` is what makes the rest
  # real rather than advisory for the only account that exists.
}

output "full_name" {
  description = "owner/name, read by the Makefile so the remote and the API calls agree."
  value       = github_repository.repo.full_name
}

output "ssh_clone_url" {
  description = "What `make github-remote` points origin at."
  value       = github_repository.repo.ssh_clone_url
}

output "html_url" {
  description = "The address, once there is a branch to look at."
  value       = github_repository.repo.html_url
}
