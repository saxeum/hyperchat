# hyperchat

A containerised FastAPI service on Cloud Run, provisioned by Terraform, that makes one model call
honestly: a Google ID token is verified, an allowlist of subjects decides who may spend, and the
provider key is never in the image, the state file or the plan.

Two things make it worth reading. The platform is small enough to check by hand, and the
contributor is an untrusted principal — an account a coding agent operates, joined by fork
instead of write access, and reviewed on every pull request.

Three words are used precisely here, because two of them are easy to confuse: **agent** is
`src/hyperchat/agent.py`, the graph the service serves; **contributor** is `kirivanzin`, the GitHub
principal that opens pull requests; **coding agent** is the LLM operating that checkout, inside its
container.

**Status: parked, 2026-11-13.** Nothing is being added. Three commands are what this repository asks
of a reader, and they work from a fresh clone:

```sh
git clone https://github.com/saxeum/hyperchat && cd hyperchat && uv sync --frozen
make test      # 194 tests, no credentials, ~8 s
make eval      # every case in evals/ through the model, ~55 s
make report    # the same run, written to docs/eval-report.md and to the line below
```

`make eval` needs one thing and says so when it is missing: the provider key, at
`~/.config/hyperchat/agent-deepseek.token` or in `PROVIDER_API_KEY`. `make help` shows the commands a
reader needs; `make help-all` shows the platform targets, which are kept working and not extended.

Parked means: CI stays required on `main`; a merge that changes something deployable still deploys;
the deployed revision is the one named below and scales to zero, so it costs cents a month; and the
open issues are decisions rather than work in progress — what this agent is for (`#24`), what
production would differ by (`#78`), and one key file to rename on the host that holds it (`#65`).

**Latest eval:** 20/20 decided · injection 5/5 (floor 4) · p95 3.7 s · ~63 k tokens per run — at `3a1c1ce`, [the report](docs/eval-report.md).

## Read this in 60 seconds, 10 minutes, or an hour

- **5 minutes:** the three commands above, then `docs/eval-report.md` — the score, the cost, the three
  hashes that say which code produced it.
- **60 seconds:** the bullets below, and the layout table.
- **10 minutes:** `docs/authentication.md` — the security model — then the decisions.
- **An hour:** the pull requests. The arguments in this repository live there, against the SHA each
  one was made on.

`make help-all` lists every target; the order is `github → registry → login → build → push → deploy`.
`make lint` and `make test` need no credentials; `make eval` needs the provider key, because it
asks the model. The merge path is `.github/workflows/deploy.yml`,
whose header and `terraform/registry/identity.tf` are its documentation.

## The public tax

Twelve PRs here exist only because the repository is public:

| | |
|---|---|
| `#3`, `#5`, `#6`, `#8` | contributor identity, ignored local material, fork-based contribution |
| `#10`, `#11` | the pinned build chain, and the redteam findings |
| `#33` | the provider key outside the checkout |
| `#48`, `#51`, `#54`, `#55` | project APIs, deployer identity, workflow/event binding, and the environment the deploy job runs in |
| `#49` | Dependabot's interpreter ignore |

A private build would commit `terraform.tfvars` and state, give CI a service-account key, grant
`roles/editor`, let the bot push, and force-push the history once. This repository pays roughly a
third of its pull requests instead — twelve of thirty-four — and buys properties a reviewer can
check: no identifier in the tree, a Workload Identity condition a stranger can read and test, a fork
that proves the negative direction, and a history that does not need rewriting.

## Layout

| Path | What it is |
|---|---|
| `src/hyperchat/main.py` | The routes. `/`, `/livez` and `/readyz` are open; everything under `/api` is behind the router's dependency. |
| `src/hyperchat/auth.py` | The trust boundary: token verification, the allowlist, and a rate-limited key cache. |
| `src/hyperchat/agent.py` | The model call as a one-node graph — the same object `/api/chat` awaits and `make chat` runs. |
| `src/hyperchat/configuration.py` | The nine values a score was produced under, and one hash over them; the metadata that makes a trace attributable. |
| `src/hyperchat/tracing.py` | Whether runs are traced and where they go, asked of langsmith and written on the configuration line. |
| `src/hyperchat/corpus.py` | The six documents the agent may read, and the manifest that is the whole of what it can reach. |
| `src/hyperchat/config.py` | What the process refuses to start without, and what it reads on demand. |
| `Dockerfile` | Installs from `uv.lock`, runs as uid 10001, base images pinned by digest. |
| `Makefile` | Every operation, in the order it happens. |
| `terraform/github` | The repository, its settings and its branch protection. Applied once, in two steps. |
| `terraform/registry` | Artifact Registry, the three project APIs, and the deployer identity. Applied once, by hand. |
| `terraform/app` | Cloud Run, the runtime identity, the provider secret and, when a key is supplied, the LangSmith one. Applied by a merge that can change what runs. |
| `evals/` | The case set `make eval` scores, with two non-model baselines beside it. |
| `.github/workflows/ci.yml` | Lint, tests, `terraform validate`, and a build that is discarded. |
| `.github/workflows/deploy.yml` | Deploy a successful `main` build that changed something deployable; prove a non-main ref cannot authenticate. |
| `docs/` | `authentication.md`, `repository-as-code.md`, `contributor.md`. The contributor's setup steps are `contributor-runbook.md`. |

## The decisions worth knowing

**The tag is the commit, and tags are immutable.** A tag that can be overwritten is not provenance:
two images answer to the same name and the only record of which one was pushed is a shell history.
Re-pushing a commit fails on purpose; a rebuild is `make push TAG=<sha>-2`.

**Docker authenticates as you, via `gcloud auth configure-docker`.** No service-account key, no
static credential in a file, nothing to rotate. The token is minted by the credential helper.

**No IAM bindings on the registry.** It is reachable by the project's own identities and nobody else.
`make registry-status` prints the policy, so the absence is observed rather than assumed.

**The runtime identity has one grant.** The Cloud Run service account is not the default compute
account, which holds `roles/editor` on this project. It has `secretmanager.secretAccessor` on the
provider secret and nothing else — attached to the secret, so `gcloud secrets get-iam-policy` is
where it shows up.

**The provider key is a Secret Manager reference, not a revision env value.** A revision's
environment is readable by a viewer, so the runtime identity reads the secret instead. The value
arrives as the write-only `TF_VAR_provider_api_key`: never in state, never in the plan file, and the
revision pins the version rather than `latest`.

**`allUsers` may invoke the service.** The allowlist is the gate, not IAM, which is the consequence
of the audience choice in `docs/authentication.md`. The per-subject bound is the only thing between a
public endpoint and spend, so concurrency is pinned at four per instance and scale-out at one
instance: four simultaneous provider calls, not four hundred.

**The deployer is an identity the workflow can only *be*.** `terraform/registry/identity.tf` conditions
the Workload Identity provider on this repository, `refs/heads/main`, this workflow file and the two
events that run it — so a new workflow on `main` cannot inherit it. Five scoped grants, no project
admin. Nothing in CI can widen it.

**There is one environment and it is called `dev`, which is not a claim that it is safe.** It is
public, holds the provider key, and the allowlist is the only thing bounding who can spend; it has no
reviewer because the only reviewer was also the only merger. `#78` brings the gate back with an
environment it can protect, and `docs/repository-as-code.md` argues the whole of it.

**Only the root a merge applies keeps its state in a bucket.** `terraform/app` is remote and
prefix-scoped, so a runner reaches it and two deploys take turns. `terraform/registry` and
`terraform/github` are applied once by a human and keep local state. The project id is not in the
repository: it lives in a git-ignored `terraform.tfvars` and the Makefile passes the bucket to
`terraform init`. `docs/repository-as-code.md` records both, and what they cost.

**The build is pinned by digest, and that costs something.** A mutable tag means a clone-and-build
today runs a different binary than last week's, as root, with nothing recording which. The trade is
that "silently new" becomes "silently old": the base stops taking Debian and CPython rebuilds until a
digest moves. Dependabot is what moves it — weekly, grouped, and ignoring interpreter minor versions
because those move four pins at once.

**CI is a required check on `main`.** A required check that has never been seen to fail can block
every merge without saying why, so it reported on real pull requests first and `terraform/github`
named it afterwards. The context is the job name the API reports, not the workflow's. Every action is
pinned by commit SHA and the job runs with `contents: read`.

**The contributor is an untrusted principal.** A real account, but not a collaborator: it joins by
fork, its push URL for this repository fails locally, and it has never merged anything.
`docs/contributor.md` argues the shape; `docs/contributor-runbook.md` is the setup.

**The graph runtime is the largest dependency here, and it is deliberate.** `langgraph`,
`langchain-core` and `langchain-deepseek` take the lock from 30 packages to 62. It is worth paying
because everything after this — streaming, the run bounds, tools, eval — is work *on* the graph
rather than work to introduce one.

**Nothing secret is in the image.** The provider key is a runtime reference, not a build input, and
`.dockerignore` and `.gitignore` both name `*.env`, `*.pem` and `*.key`.

## Asking the model something

`/api/chat` sends one message through the graph and returns the reply. The input is capped at 4000
characters before any provider call, and the output cap goes on the wire by name:

```sh
MESSAGE='Reply with exactly: ok' make chat
PROVIDER_MAX_TOKENS=5 MESSAGE='Count from one to fifty.' make chat
```

`make chat` runs the same `graph` object the endpoint awaits — no HTTP, no token — so a debugging
tool cannot drift from the service. The endpoint answers **503** when no key is configured (the model
is off, not broken) and **502** when the provider fails, with the reason logged and not returned. An
empty reply is a 502 as well, and the log carries `finish_reason`.

## Watching a run

`LANGSMITH_TRACING=true` turns tracing on, and it says where the runs go on the configuration line the
service already prints: `tracing=off`, or `tracing=on` with the project, the agent address and whether
inputs and outputs are kept. That report is asked of langsmith rather than restated from its rules, and
a misconfiguration is a line in the log rather than a failed request — the service answering 200 with
an empty project view is otherwise silent. The deployed revision hides the caller's text
(`LANGSMITH_HIDE_INPUTS`, `LANGSMITH_HIDE_OUTPUTS`), so a trace carries the run tree, the tool calls,
the token counts and the model; a full trace is a local opt-in, with the key outside the checkout:

```sh
MESSAGE='Reply with exactly: ok' LANGSMITH_TRACING=true make chat
```

## Not here yet

Streaming — the answer as it is produced, rather than after it is finished. The run bounds are here: a
step ceiling, a time budget, a provider timeout and a per-caller rate, each with its own answer
(`src/hyperchat/README.md`, and `make limits` for the last one). The agent itself — tools, a second
model, and the security testing that goes with them — is where this would go next, and parking is the
decision to stop before that rather than during it. `make eval` is the first attempt at the other
question — not what happened, but whether it was right — and its case set is a line per case in
`evals/cases.jsonl` with a `why` on each.

## Where to go deeper

- `docs/authentication.md` — who can call a protected route, and what each check is for.
- `docs/repository-as-code.md` — provisioning the repository with Terraform, and the token it costs.
- `docs/contributor.md` — the coding agent as a contributor, and why it joins by fork.
