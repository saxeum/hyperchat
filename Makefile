# Every operation this repository supports, in the order it happens:
#   github -> registry -> login -> build -> push -> deploy.  `make help-all` lists them.
#
# The tag is the commit and the registry refuses to overwrite a tag, so pushing the same commit twice
# fails on purpose. A rebuild is `make push TAG=<sha>-2`.

IMAGE      ?= hyperchat
TAG        ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
REGION     ?= australia-southeast1
REPOSITORY ?= hyperchat
SERVICE    ?= hyperchat
PORT       ?= 8080
# How many requests `make limits` expects to be allowed before 429. Small on purpose: each allowed
# request is a provider call, and the check is about the boundary rather than the throughput.
LIMIT      ?= 3

TERRAFORM = terraform -chdir=terraform/registry
TERRAFORM_GITHUB = terraform -chdir=terraform/github
TERRAFORM_APP = terraform -chdir=terraform/app
BRANCH ?= main
# The project is read from the applied registry root rather than repeated here. Two places holding
# the same identifier is how an image ends up in a registry that nothing reads. The registry state is
# itself in the bucket named after the project, so before that root has been initialised the one
# git-ignored copy in its tfvars is what answers — the same single copy, read directly.
PROJECT ?= $(shell $(TERRAFORM) output -raw project 2>/dev/null || \
	sed -n 's/^project *= *"\(.*\)"/\1/p' terraform/registry/terraform.tfvars 2>/dev/null)
# Only the app root has remote state: it is the root a merge applies, so a runner must reach and lock
# it. `registry` and `github` are applied once by a human, keep their state in the checkout that
# applied them, and take no backend argument. The bucket is derived here and passed as partial backend
# configuration — written in the block, it would put the project id in the repository.
STATE_BUCKET = $(if $(PROJECT),$(PROJECT)-tfstate,$(error PROJECT is unset: it names the state bucket, so pass PROJECT=<id> or keep terraform/registry/terraform.tfvars))
BACKEND = -backend-config="bucket=$(STATE_BUCKET)"
# And the service URL from the applied Cloud Run root, so smoke has one address to call.
# The state lives in a GCS bucket now (#42), not in this checkout, so there is no local file to guard:
# a machine that has the variables reaches the same state as this one. What replaced the guard is the
# bucket's own locking and versioning, which are the owning root's to declare and are not repeated here.
APP_URL ?= $(shell $(TERRAFORM_APP) output -raw url 2>/dev/null)
# And the repository comes from the applied GitHub root, for the same reason.
FULL_NAME ?= $(shell $(TERRAFORM_GITHUB) output -raw full_name 2>/dev/null)
# And the organisation, from the same output, for the calls that are about seats rather than the
# repository. One identifier, one home.
OWNER ?= $(firstword $(subst /, ,$(FULL_NAME)))

REGISTRY = $(REGION)-docker.pkg.dev/$(PROJECT)/$(REPOSITORY)
LOCAL    = $(IMAGE):$(TAG)
REMOTE   = $(REGISTRY)/$(IMAGE):$(TAG)

.DEFAULT_GOAL := help

.PHONY: help info lint test eval build dev run stop token chat github github-plan github-create github-remote \
        github-apply github-status pipeline-audit registry-plan registry-apply login push limits report \
        registry-status registry-verify image-exists image-digest deploy-plan deploy smoke help-all

help: ## The commands a newcomer needs; `make help-all` lists every target
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z0-9_-]+: ## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

help-all: ## Every target, including the one-time and platform ones
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z0-9_-]+: ## / || /^[a-zA-Z0-9_-]+: ### / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

info: ### Print what the next command will use, before it uses it
	@printf '  project     %s\n' "$(if $(PROJECT),$(PROJECT),<unset: run make registry-apply>)"
	@printf '  region      %s\n' "$(REGION)"
	@printf '  repository  %s\n' "$(REPOSITORY)"
	@printf '  tag         %s\n' "$(TAG)"
	@printf '  push to     %s\n' "$(if $(PROJECT),$(REMOTE),<unset>)"
	@printf '  service     %s\n' "$(SERVICE)"
	@printf '  deploy to   %s\n' "$(if $(APP_URL),$(APP_URL),<unset: run make deploy>)"

lint: ## Check formatting and lint (no credentials; ruff itself comes from PyPI)
	@uv run ruff format --check . && uv run ruff check --output-format=concise .

test: ## Run the tests
	uv run pytest -q

limits: ### Assert the per-caller rate limit: LIMIT requests allowed, the next two refused
	@[ -n "$(APP_URL)" ] || { \
		echo "APP_URL is unset: there is no applied state in terraform/app." >&2; \
		echo "run 'make deploy' once, or pass APP_URL=<url>" >&2; \
		exit 1; }
	@$(LOCAL_ENV); scripts/limits.sh "$(APP_URL)" "$(LIMIT)"

report: ## Run the eval and write docs/eval-report.md and the README line from it
	@$(LOCAL_ENV); uv run python scripts/eval.py --report docs/eval-report.md

eval: ## Every case in the dataset through the graph, beside a baseline that is not a model
	@$(LOCAL_ENV); uv run python scripts/eval.py

build: ### Build the image for this commit, pulling the base image
	docker build --pull -t $(LOCAL) .

# The environment both local targets need, in one place so the two cannot drift: `.env` for the
# audience and the allowlist, and each credential from a file outside the checkout. A `.env` that sets
# either key is refused rather than preferred — docs/authentication.md has the reason.
#
# The two keys are two checks rather than one loop because each refusal names the file the value
# belongs in, and a message that says "the key" about either of two keys is the message somebody acts
# on wrongly. `LANGSMITH_API_KEY` is optional: without it the command runs untraced and says so on its
# first line, which is the same report the service gives.
LOCAL_ENV = if [ -f .env ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?PROVIDER_API_KEY=' .env; then \
              echo "PROVIDER_API_KEY is in .env, and it is a credential: it does not go in a checkout." >&2; \
              echo "keep it in $$HOME/.config/hyperchat/agent-deepseek.token, or export it for one command." >&2; \
              exit 1; fi; \
            if [ -f .env ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?LANGSMITH_API_KEY=' .env; then \
              echo "LANGSMITH_API_KEY is in .env, and it is a credential: it does not go in a checkout." >&2; \
              echo "keep it in $$HOME/.config/hyperchat/langsmith.token, or export it for one command." >&2; \
              exit 1; fi; \
            set -a; [ -f .env ] && . ./.env; set +a; \
            if [ -z "$$PROVIDER_API_KEY" ] && [ -f "$$HOME/.config/hyperchat/agent-deepseek.token" ]; then \
              PROVIDER_API_KEY=$$(cat "$$HOME/.config/hyperchat/agent-deepseek.token"); export PROVIDER_API_KEY; fi; \
            if [ -z "$$LANGSMITH_API_KEY" ] && [ -f "$$HOME/.config/hyperchat/langsmith.token" ]; then \
              LANGSMITH_API_KEY=$$(cat "$$HOME/.config/hyperchat/langsmith.token"); export LANGSMITH_API_KEY; fi

dev: ## Run the app from the source tree on PORT, reading .env; no image
	@$(LOCAL_ENV); uv run uvicorn hyperchat.main:api --host 127.0.0.1 --port $(PORT)

run: ### Run the image on PORT, with .env passed in so the fail-closed config is satisfied
	docker run --rm --name $(IMAGE) --env-file .env -p $(PORT):8080 $(LOCAL)

token: ### Print a Google ID token for EXPECTED_AUDIENCE (needs gcloud, logged in as a user)
	@scripts/token.sh

# The claims are the point, and one of them is the allowlist key. `sub` is what `ALLOWED_SUBS` matches
# — not `email`, which is for display — and reading it out of a real token is the only way to know it,
# because it is a Google subject rather than anything this repository mints or can compute.
token-info: ### Decode the header and claims of a freshly minted token
	@$(MAKE) --no-print-directory token | python3 -c 'import base64,json,sys; p=sys.stdin.read().strip().split("."); d=lambda s: json.loads(base64.urlsafe_b64decode(s+"="*(-len(s)%4))); print(json.dumps({"header":d(p[0]),"claims":d(p[1])},indent=2,sort_keys=True))' 

# The same graph the endpoint serves, run directly: no HTTP and no token, because authentication is a
# property of the route rather than of the graph. This is the debugging tool, and it is the object
# that runs in the service rather than a second implementation of it.
#
# `$$MESSAGE` is deliberate: make turns `$$` into `$`, leaving the shell to expand `$MESSAGE` at run
# time. `$(MESSAGE)` would have make expand the value first, so `$HOME` or `$5` inside the message
# would be eaten before Python saw it. MESSAGE belongs in the environment, not in make's arguments.
chat: ## One message from MESSAGE in the environment through the graph (reads .env, and the key from outside it)
	@$(LOCAL_ENV); uv run python -m hyperchat.chat "$$MESSAGE"

stop: ### Stop the running container
	@docker stop $(IMAGE) 2>/dev/null || true

github: ### Create the repository, point origin at it, push, then protect the branch
	@[ -n "$$GITHUB_TOKEN" ] || { \
		echo "GITHUB_TOKEN is unset: the GitHub provider authenticates with it." >&2; \
		echo "see docs/repository-as-code.md for what that token can do" >&2; \
		exit 1; }
	@[ -z "$$(git status --porcelain)" ] || { \
		echo "uncommitted changes: nothing publishes them, and they are easy to lose" >&2; \
		echo "commit them first, then run this again" >&2; \
		git status --short; \
		exit 1; }
	@echo "== repository"; $(MAKE) --no-print-directory github-create
	@echo "== origin"; $(MAKE) --no-print-directory github-remote
	@echo "== first push"; git push -u origin $(BRANCH)
	@echo "== protection"; $(MAKE) --no-print-directory github-apply
	@echo "== published: $$($(TERRAFORM_GITHUB) output -raw html_url)"

github-plan: ### Show what the GitHub root creates, without creating it
	$(TERRAFORM_GITHUB) init -input=false
	$(TERRAFORM_GITHUB) plan -input=false

github-create: ### Create the repository, so there is somewhere to push
	$(TERRAFORM_GITHUB) init -input=false
	$(TERRAFORM_GITHUB) apply -input=false -target=github_repository.repo

github-remote: ### Point origin at the repository this root created
	@[ -n "$(FULL_NAME)" ] || { \
		echo "FULL_NAME is unset: no applied state in terraform/github." >&2; \
		echo "run 'make github-create' once, or pass FULL_NAME=owner/name" >&2; \
		exit 1; }
	@git remote get-url origin >/dev/null 2>&1 \
		&& git remote set-url origin "$$($(TERRAFORM_GITHUB) output -raw ssh_clone_url)" \
		|| git remote add origin "$$($(TERRAFORM_GITHUB) output -raw ssh_clone_url)"

github-apply: ### Apply the rest, so branch protection lands once the branch exists
	$(TERRAFORM_GITHUB) init -input=false
	$(TERRAFORM_GITHUB) apply -input=false

# Who can reach the repository is not in the Terraform root: the contributor joins as a fork, so
# there is no collaborator resource to drift and, equally, nothing to notice a collaborator added by
# hand.
#
# Three states, and two of them look identical from the wrong endpoint: a member or owner is in
# `collaborators` and not in `?affiliation=outside`; an accepted outside collaborator is in
# `?affiliation=outside`; an invitation not yet accepted is in neither, only in `/invitations`.
# Reading the accepted list alone makes "no access" and "invited, never clicked" the same output.
# `?affiliation=all` is deliberately not used: it reports the owner as `admin`, so a line meant for
# the contributor would describe the owner. `filled_seats` is read because a seat going from 1 to 2
# is how a grant added as membership — the half that costs money — becomes visible.
#
# Every line prints when the answer is nothing, and says `unreadable` rather than `none` when the API
# refuses or the field is absent: an absence that was never asked for is not an absence, and a target
# that stops at the first refusal cannot report on the rest. The exit status is non-zero if anything
# was unreadable, so this stays an observation rather than a check, and still fails when it is blind.
github-status: ### Print the live repository settings, protection and access. An observation, not a check
	@[ -n "$(FULL_NAME)" ] || { \
		echo "FULL_NAME is unset: no applied state in terraform/github." >&2; \
		echo "run 'make github-create' once, or pass FULL_NAME=owner/name" >&2; \
		exit 1; }
	@failed=0; err=$$(mktemp); trap 'rm -f "$$err"' EXIT; \
	report() { \
		label=$$1; shift; pad=''; [ -z "$$label" ] || pad=$$(printf '  %-22s ' "$$label"); \
		if out=$$("$$@" 2>"$$err"); then printf '%s%s\n' "$$pad" "$$out"; \
		else failed=1; printf '%sunreadable: %s\n' "$$pad" "$$(tr '\n' ' ' <"$$err")"; fi; }; \
	report '' gh api /repos/$(FULL_NAME) \
		--jq '"repository " + .full_name + " exists"'; \
	report '' gh api /repos/$(FULL_NAME) \
		--jq '{visibility, security: (.security_and_analysis | map_values(.status))}'; \
	report '' gh api /repos/$(FULL_NAME)/branches/$(BRANCH)/protection \
		--jq '{admins: .enforce_admins.enabled, force_push: .allow_force_pushes.enabled, deletion: .allow_deletions.enabled, reviews: .required_pull_request_reviews, checks: .required_status_checks}'; \
	echo "== access"; \
	report 'outside collaborators' gh api "/repos/$(FULL_NAME)/collaborators?affiliation=outside" \
		--jq '[.[] | "\(.login) (\(.role_name))"] | if length == 0 then "none" else join(", ") end'; \
	report 'pending invitations' gh api "/repos/$(FULL_NAME)/invitations" \
		--jq '[.[] | "\(.id) (\(.invitee.login))"] | if length == 0 then "none" else join(", ") end'; \
	report 'org filled seats' gh api "/orgs/$(OWNER)" \
		--jq '.plan.filled_seats // "unreadable: no plan in the response"'; \
	exit $$failed

registry-plan: ### Show what the registry root creates, without creating it
	$(TERRAFORM) init -input=false
	$(TERRAFORM) plan -input=false

registry-apply: ### Create the registry. Once, by the human, before the first push
	$(TERRAFORM) init -input=false
	$(TERRAFORM) apply -input=false

login: ### Authorise docker for the registry host, as your own gcloud identity
	@gcloud auth configure-docker $(REGION)-docker.pkg.dev --quiet

push: ### Tag and push the image for this commit
	@[ -n "$(PROJECT)" ] || { \
		echo "PROJECT is unset: there is no applied state in terraform/registry." >&2; \
		echo "run 'make registry-apply' once, or pass PROJECT=<id>" >&2; \
		exit 1; }
	docker tag $(LOCAL) $(REMOTE)
	docker push $(REMOTE)

registry-status: ### Print the live registry and its IAM policy. An observation, not a check
	@[ -n "$(PROJECT)" ] || { \
		echo "PROJECT is unset: there is no applied state in terraform/registry." >&2; \
		echo "run 'make registry-apply' once, or pass PROJECT=<id>" >&2; \
		exit 1; }
	@gcloud artifacts repositories describe $(REPOSITORY) \
		--location=$(REGION) --project=$(PROJECT) \
		--format='table(name.basename(),format,dockerConfig.immutableTags)'
	@echo "== iam policy: no bindings is the intended answer"
	@gcloud artifacts repositories get-iam-policy $(REPOSITORY) \
		--location=$(REGION) --project=$(PROJECT) \
		--format='value(bindings.members)'

# The service image is the commit tag; `make registry-verify` shows what the service is actually
# running beside the digest that tag resolves to. It is an observation, not a check: a service can be
# deliberately on an older tag, and the useful answer is both values rather than a pass/fail.
image-exists: ### Exit 0 when TAG's image is in the registry, 1 when it is not. Prints nothing
	@command -v gcloud >/dev/null 2>&1 || exit 1
	@gcloud artifacts docker images describe "$(REMOTE)" --project=$(PROJECT) \
		--format='value(image_summary.digest)' >/dev/null 2>&1

image-digest: ### Print TAG's registry digest, or fail if it was never pushed
	@gcloud artifacts docker images describe "$(REMOTE)" --project=$(PROJECT) \
		--format='value(image_summary.digest)'

registry-verify: ### Show the deployed image and the registry digest for TAG (needs gcloud)
	@[ -n "$(PROJECT)" ] || { \
		echo "PROJECT is unset: there is no applied state in terraform/registry." >&2; \
		echo "run 'make registry-apply' once, or pass PROJECT=<id>" >&2; \
		exit 1; }
	@[ -n "$(APP_URL)" ] || { \
		echo "APP_URL is unset: there is no applied state in terraform/app." >&2; \
		echo "run 'make deploy' once, or pass APP_URL=<url>" >&2; \
		exit 1; }
	@echo "== deployed image"
	@gcloud run services describe $(SERVICE) --region=$(REGION) --project=$(PROJECT) \
		--format='value(template.spec.containers[0].image)'
	@echo "== registry digest for TAG=$(TAG)"
	@gcloud artifacts docker images describe "$(REMOTE)" \
		--project=$(PROJECT) --format='value(image_summary.digest)'

# Empty on purpose, so `make deploy` from a terminal shows the plan and waits for the answer. CI has
# no stdin to answer that prompt with: the first appended dispatch sat on it holding the state lock
# until it was cancelled. There the approval is the merge, or the dispatch itself, so the workflow
# sets this to -auto-approve.
AUTO_APPROVE ?=

# The secret version is an ordinary resource now, so secret -> version -> grant -> service is one
# dependency graph rather than three interleaved commands. The value is write-only and arrives as
# TF_VAR_provider_api_key from the token file outside the checkout.
deploy-plan: ### Show what the Cloud Run root would change, without changing it
	@[ -n "$(PROJECT)" ] || { \
		echo "PROJECT is unset: there is no applied state in terraform/registry." >&2; \
		echo "run 'make registry-apply' once, or pass PROJECT=<id>" >&2; \
		exit 1; }
	@$(LOCAL_ENV); [ -n "$$PROVIDER_API_KEY" ] || { \
			echo "TF_VAR_provider_api_key would be empty: set PROVIDER_API_KEY in $$HOME/.config/hyperchat/agent-deepseek.token or the environment." >&2; \
			exit 1; }; \
		tracing=$$([ -n "$$LANGSMITH_API_KEY" ] && echo true || echo false); \
		TF_VAR_provider_api_key="$$PROVIDER_API_KEY" TF_VAR_langsmith_api_key="$$LANGSMITH_API_KEY" \
			$(TERRAFORM_APP) init -input=false $(BACKEND); \
		TF_VAR_provider_api_key="$$PROVIDER_API_KEY" TF_VAR_langsmith_api_key="$$LANGSMITH_API_KEY" \
			$(TERRAFORM_APP) plan -input=false -var="project=$(PROJECT)" -var="image=$(REMOTE)" \
				-var="langsmith_tracing=$$tracing"

deploy: ## Deploy this commit's image, secret version and service to Cloud Run in one apply
	@[ -n "$(PROJECT)" ] || { \
		echo "PROJECT is unset: there is no applied state in terraform/registry." >&2; \
		echo "run 'make registry-apply' once, or pass PROJECT=<id>" >&2; \
		exit 1; }
	@command -v gcloud >/dev/null 2>&1 || { \
		echo "could not ask the registry about $(REMOTE): gcloud is not installed." >&2; \
		exit 2; }
	@err=$$(gcloud artifacts docker images describe "$(REMOTE)" --project=$(PROJECT) \
			--format='value(image_summary.digest)' 2>&1) || { \
		if printf '%s' "$$err" | grep -qiE 'image .*not found|not_found'; then \
			echo "no image $(REMOTE) exists." >&2; \
			echo "Either it was never pushed, or this checkout is not the commit you think:" >&2; \
			echo "TAG comes from git rev-parse --short HEAD ($(TAG)); the registry has:" >&2; \
			tags=$$(gcloud artifacts docker tags list "$(REGISTRY)/$(IMAGE)" --project=$(PROJECT) \
				--format='value(tag)' 2>&1) || { \
					echo "could not list the tags either:" >&2; \
					printf '%s\n' "$$tags" >&2; \
					exit 1; }; \
			if [ -n "$$tags" ]; then printf '%s\n' "$$tags" | sed 's/^/  /' >&2; else echo "  (none)" >&2; fi; \
			exit 1; \
		else \
			echo "could not ask the registry about $(REMOTE):" >&2; \
			printf '%s\n' "$$err" >&2; \
			exit 2; \
		fi; \
	}
	@$(LOCAL_ENV); [ -n "$$PROVIDER_API_KEY" ] || { \
			echo "TF_VAR_provider_api_key would be empty: set PROVIDER_API_KEY in $$HOME/.config/hyperchat/agent-deepseek.token or the environment." >&2; \
			exit 1; }; \
		tracing=$$([ -n "$$LANGSMITH_API_KEY" ] && echo true || echo false); \
		TF_VAR_provider_api_key="$$PROVIDER_API_KEY" TF_VAR_langsmith_api_key="$$LANGSMITH_API_KEY" \
			$(TERRAFORM_APP) init -input=false $(BACKEND); \
		TF_VAR_provider_api_key="$$PROVIDER_API_KEY" TF_VAR_langsmith_api_key="$$LANGSMITH_API_KEY" \
			$(TERRAFORM_APP) apply -input=false $(AUTO_APPROVE) -var="project=$(PROJECT)" -var="image=$(REMOTE)" \
				-var="langsmith_tracing=$$tracing"

pipeline-audit: ### Check the live pipeline against what the README claims (needs gh; owner for protection)
	@REPO=$(FULL_NAME) scripts/pipeline-audit.sh

smoke: ### Assert the deployed probes and both auth directions (needs gcloud for a token)
	@[ -n "$(APP_URL)" ] || { \
		echo "APP_URL is unset: there is no applied state in terraform/app." >&2; \
		echo "run 'make deploy' once, or pass APP_URL=<url>" >&2; \
		exit 1; }
	@$(LOCAL_ENV); scripts/smoke.sh "$(APP_URL)"
