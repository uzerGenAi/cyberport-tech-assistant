# Tidy + CI-fix + Robustness Hardening Notes

This document records the tidy-within-structure cleanup, the `make ci` robustness
fixes, and the scoped robustness hardening applied on branch `tidy-robust`. It is the
reviewer-readable evidence trail; it is not operational documentation.

No AWS mutations, deploys, `terraform apply`, or stage-dir renames were performed. The
numbered stage dirs (`1_…`–`6_deploy`) and all relative paths are unchanged. `.github/`
and `6_deploy/infra/github-oidc/` remain absent (not reintroduced).

---

## 1. File removals (per-file grep evidence)

Every removal was preceded by a repo-wide `git grep -n` and every reference was updated
in the same commit. HTML loads only `script-enhanced.js`, `cognito-enhanced.js`,
`agentcore-client-fixed.js`, and `enhanced-styles.css` (which `@import`s `style.css`).

### `6_deploy/web-app/script.js` — REMOVED
- `git grep -n "script\.js"` hits: `Dockerfile:10` (COPY), `setup_cognito_auth.sh:89`
  (a guarded backup array wrapped in `if [ -f … ]`), `deploy_stack.sh:17`
  (`SCRIPT_JS_PATH=…`, an unused variable — confirmed used nowhere else).
- `grep 'script\.js' *.html` → no `<script src>`; loaded by 0 HTML pages.
- Consumer edits in-commit: dropped from Dockerfile COPY; dropped from the
  `setup_cognito_auth.sh` backup array; `SCRIPT_JS_PATH` line deleted from the legacy
  `deploy_stack.sh`.

### `6_deploy/web-app/cognito.js` — REMOVED
- `git grep -n "cognito\.js"` hits: `Dockerfile:10` (COPY), `setup_cognito_auth.sh:89`
  (guarded backup), `login.html:229` (a stale CODE COMMENT, not a `<script src>`).
- Active auth file is `cognito-enhanced.js` (`index.html:13`, `login.html:189`
  `<script src>`), confirmed via `git grep -n "cognito-enhanced\.js"`.
- Consumer edits in-commit: dropped from Dockerfile COPY and the backup array; the
  misleading `login.html` comment was corrected to name `cognito-enhanced.js`.

### `6_deploy/web-app/serve.py` — REMOVED
- `git grep -n "serve\.py"` → no hits. A ~12-line local dev static server with zero
  consumers (no script, README, or buildspec references it). No consumer edits needed.
- ci_checks.sh `python3 -m compileall` targets the stage dirs; `6_deploy/web-app/` has
  no remaining `.py`, so the removal does not affect CI.

### `.agents/` and `.bob/` — UNTRACKED (git rm) + gitignored
- `git ls-files` showed `.agents/tasks/task-codecommit-ci/**` (workflow task records)
  and `.bob/artifacts/spbc-production-deployment-runbook.html` (a generated runbook HTML
  referenced only from within `.agents/`, i.e. no maintained-deliverable consumer).
- Added `.agents/` and `.bob/` to `.gitignore` and `git rm -r`'d both tracked trees.
  The on-disk workflow plan under `.agents/` remains untracked by design.

### KEPT (grep found a real/legacy consumer — conservative "keep when in doubt")
- `6_deploy/web-app/style.css` — LIVE: `enhanced-styles.css:4` does
  `@import url('style.css')`. Not removed.
- `6_deploy/web-app/webapp.sh` — KEPT. `deploy_stack.sh` (legacy "kept for reference"
  EKS+CloudFront path) actually invokes it (`bash webapp.sh`), so it has a real executor;
  removing it would break that retained script. Noted as a future-pass candidate.
- `6_deploy/scripts/update-cognito-config.sh` — KEPT (conservative). Only reference is a
  best-effort `chmod … || true` in `setup_dev_tools.sh`; nothing executes it. Borderline;
  retained per the "keep when in doubt" rule and flagged as a future-pass candidate. If a
  future pass removes it, also drop the one `setup_dev_tools.sh` chmod line.

### Cruft sweep — VERIFY ONLY (nothing to remove)
- `git ls-files | grep -iE '\.DS_Store|\.pyc$|__pycache__/|\.zip$|backup_|\.swp$|~$'`
  → none. `.gitignore` already covers `.DS_Store`, `__pycache__/`, `*.py[cod]`, `*.zip`,
  `backup_*/`, `*.swp`, `*~`.

### PoC duplication — LEFT AS-IS (intentional)
- `3_proof_of_concept/agents/` and `6_deploy/agents/` are near-duplicates representing
  different lifecycle stages of the numbered structure. Both are intentional; neither is
  removed. Noted only.

---

## 2. `make ci` robustness fixes (`6_deploy/scripts/ci_checks.sh`)

`make ci` was already green on a clean checkout; both fixes harden it against latent
failures without weakening any real validation. All three stacks still get
`fmt` + `init -backend=false` + `validate` (+ `test` for agentcore-backends).

### 2(a) — stale local `terraform.tfvars` immunity
- `terraform_backend_setup.sh` writes an auto-generated, **gitignored**
  `6_deploy/infra/terraform/terraform.tfvars`. `terraform fmt -check -recursive` walked
  it; a malformed one made fmt exit 3 and `make ci` fail (reproduced).
- Fix: replaced the three `terraform fmt -check -recursive` calls with a
  `fmt_check_tracked` helper that enumerates git-**tracked** `*.tf`/`*.tftest.hcl` via
  `git ls-files` (the source of truth for "tracked", and it includes the nested
  `tests/backends.tftest.hcl`) and fmt-checks only those. A developer's local tfvars can
  no longer break CI; tracked formatting errors still fail (verified).

### 2(b) — known Terraform 1.16.x engine-panic guard
- The brief reports a Terraform 1.16.x engine bug, `panic: … value has marks, so it
  cannot be serialized as JSON`, on `terraform test`. **It does NOT reproduce on the
  installed 1.16.6** here — the suite passes 8/8 repeatedly, and there are no `sensitive`
  markers in the stack. So the panic cannot be reproduced or proven fixed by a version
  bump on this machine.
- Fix: run `terraform test` normally and capture its result. **Only** when it exits
  non-zero **and** the output matches the exact panic signature
  (`panic:.*(value has marks|cannot be serialized as JSON)`) do we print a prominent
  multi-line WARNING naming the bug and the installed version, and treat that one case as
  a visible SKIP. Any other non-zero exit is a real failure and still fails CI. On the
  healthy path (today) the full suite runs and must pass — behavior unchanged.
- This is the ONLY permitted skip, and it is loud. `backends.tftest.hcl` was **not**
  altered (it passes; editing a passing test for an unreproducible panic would weaken it
  for no verifiable benefit).
- Version-bump recommendation (UNVERIFIED): run CI on a Terraform build without this bug.
  Documented in `agentcore-backends/versions.tf`; `required_version` was intentionally
  **not** raised (bumping it would break CI on the only installed version, 1.16.6).

Verification performed:
- Clean `make ci` → exit 0, `Success! 8 passed, 0 failed.`, `CI checks passed` (guard did
  NOT skip on the healthy path).
- Stale malformed `terraform.tfvars` present → `make ci` still exit 0.
- Mis-indented **tracked** `outputs.tf` → `make ci` non-zero (fmt still enforced).
- Negative control (a tftest assertion flipped false) → `make ci` exit 2 with
  `ERROR: 'terraform test' failed (not the known engine panic)`. Test restored after.

---

## 3. Robustness hardening (scoped)

### 3a — `deploy_agentcore.sh` ARTIFACT_TYPE default `zip` → `container`
- The canonical runtime path (post_deploy.sh / configure_runtime.py) is container-via
  CodeBuild. AWS forbids changing a runtime's artifact type after creation, so a manual
  `deploy-all` defaulting to `zip` would create a zip runtime conflicting with the
  canonical container one.
- Change (default only): `ARTIFACT_TYPE="${ARTIFACT_TYPE:-container}"` and the usage text
  now reads `container | zip (default: container)`. zip stays available explicitly via
  `ARTIFACT_TYPE=zip` or the `step7-package-zip` subcommand (those functions `export`
  their own value, so they are unaffected). No behavior change when the user sets
  `ARTIFACT_TYPE` explicitly.

### 3b — strict-mode preambles on EXECUTED scripts
Added `set -euo pipefail` (immediately after the shebang) to the executed scripts that
lacked strict mode: `deploy_agentcore.sh`, `check_env.sh`,
`6_deploy/scripts/{agentcore_backends.sh, build_webapp_image.sh, deploy_blue_green.sh,
post_deploy.sh, rollback.sh, setup_cognito_auth.sh, smoke_test.sh,
terraform_backend_setup.sh}`.
- `set -u` surfaced one unbound-var use in `check_env.sh` (indirect `${!var}` over a
  possibly-unset required var). Fixed minimally to `${!var:-}` — no logic change.
- All changed scripts pass `bash -n` and `shellcheck -S error` (no errors), with no new
  SC2154 unbound-variable warnings.
- **`setup_env.sh` is deliberately NOT modified.** It is SOURCED into the caller's shell
  and already resilient (`|| true` on optional lookups); adding `set -e` would kill the
  caller. Confirmed it still has no `set -e`.
- Scripts already strict (`ci_checks.sh`, `end_to_end.sh`, `amplify-deploy.sh`,
  `terraform_backend_config.sh`) and legacy `set -e` scripts (`deploy_stack.sh`,
  `deploy_frontend.sh`, `setup_dev_tools.sh`, `webapp.sh`, `update-cognito-config.sh`)
  were left unchanged to avoid behavior changes in retained-for-reference code.

### 3c — deletion-protection / lifecycle posture (VERIFY + DOCUMENT, no change)
Confirmed the defaults are already production-safe; flipping would be a no-op or would
break the passing tftest assertion, so nothing was changed:
- `agentcore-backends/variables.tf`: `aurora_deletion_protection` default **`true`**.
- `agentcore-backends/database.tf`: `deletion_protection = var.aurora_deletion_protection`,
  `skip_final_snapshot = true` (changed later: no final snapshot is kept; the stores data is seed data).
- `agentcore-backends/orders.tf`: `deletion_protection_enabled = true` (hardcoded).
- `backends.tftest.hcl` asserts the cluster's `deletion_protection` is truthy — i.e. the
  create-run relies on the `true` default (no override to false). Test runs that need
  `false` must set it via tfvars; the default stays `true`.
- EKS (`terraform`) and CodePipeline stacks: no RDS/`deletion_protection` resources; the
  CodePipeline artifacts S3 bucket has only a lifecycle-expiration config (CI artifacts),
  which is the correct posture.

---

## Cleanup pass before redeploy (November 2026)

The "future-pass candidates" from the cruft sweep above were removed, together with other files
that nothing in the current deploy flow (`Makefile`, `6_deploy/codepipeline/*.yml`,
`post_deploy.sh`, `end_to_end.sh`) runs. Tracked files are recoverable from git history.

**Removed (tracked):**
- `6_deploy/scripts/deploy_stack.sh`, `deploy_frontend.sh`: legacy EKS + CloudFront path with
  interactive prompts and leftovers from another project (a `P2P-Agent-Metrics` dashboard, a
  `p2peksautomodenoderole` role). `deploy_stack.sh` was also the only writer of the
  `SPBC-Agent-Metrics` dashboard, whose `SPBC/Agents` namespace nothing emits.
- `6_deploy/web-app/webapp.sh` (only called by `deploy_stack.sh`), `update-cognito-config.sh`
  (nothing ran it), `6_deploy/scripts/setup_dev_tools.sh` (Cloud9-era installer that only
  chmod-ed the scripts above), `6_deploy/scripts/terraform_backend_config.sh` (a placeholder that
  only printed a message), `6_deploy/scripts/frontend-deployment.yaml` (an unreferenced k8s
  manifest; `deploy_blue_green.sh` generates the per-colour Deployments).
- `6_deploy/web-app/observability.html`: unlinked page that claimed metrics were flowing to the
  `SPBC/Agents` namespace.
- `6_deploy/web-app/image.jpg`: the old café photo; the hero is now `hero-devices.svg`.
- `5_security_rai/bedrock-agent-ec2-least-privilege.json`: unreferenced, and despite its name it
  granted `bedrock:*` and `ec2:*` on `*`.

**Removed (local, untracked or gitignored):** `__pycache__/` and `.DS_Store` files; the six
`6_deploy/web-app/backup_*` folders (configs of deleted Cognito pools and pre-rename scripts);
`agentcore-config.json` and `cognito-config.json` (pointed at the deleted runtime and pools;
`make post-deploy` regenerates both); `6_deploy/agents/.bedrock_agentcore.yaml` (starter-toolkit
state for the deleted runtime, now gitignored); `6_deploy/infra/agentcore-backends/.build/` and
that stack's `.terraform/terraform.tfstate` backend pointer to the deleted state bucket (the
pointer made `make ci` fail offline); the unused `6_deploy/web-app/image.png` and the
comments-only root `env.sh`.

**Changed so nothing depends on the removed files:**
- `6_deploy/web-app/observability-config.json` is now a tracked static file (console links only:
  CloudWatch generative AI observability and the `/aws/bedrock-agentcore/runtimes` log groups).
  The EKS image build requires it and only the removed `deploy_stack.sh` used to write it.
- `index.html` reads the logs link from that file; its fallback links pointed at another
  project's dashboard and Lambda log group.
- The web-app `Dockerfile` copies `hero-devices.svg` instead of `image.jpg` and no longer copies
  `observability.html`.

---

## EKS removal (November 2026)

The optional EKS web-hosting tier was removed. The agents never ran on it: they run in the
Bedrock AgentCore runtime, and the web app is served by AWS Amplify and calls AgentCore directly
from the browser with temporary Cognito credentials.

**Removed:** the `6_deploy/infra/terraform` stack (VPC with three NAT gateways, EKS 1.29, node
group, cluster autoscaler, ECR web repository, optional ACM/Route 53), `6_deploy/k8s/`,
`end_to_end.sh`, `build_webapp_image.sh`, `deploy_blue_green.sh`, `rollback.sh`, the web-app
`Dockerfile` and `buildspec.yml`, the `make provision` / `deploy` / `rollback` targets, and the
`TOGGLE_DEPLOY_EKS` pipeline toggle with its `eks:*` IAM permission.

**Moved, not lost:** `spbc-orders-table` and `spbc-sessions-table` now belong to the
`agentcore-backends` stack (`tables.tf`) and are always created. Both have point-in-time recovery,
encryption and deletion protection (`dynamodb_deletion_protection`). The `create_orders_table`
variable no longer exists. Destroying the stack now deletes these tables with their data, and
`agentcore_backends.sh destroy` says so.

**Simplified:** `terraform_backend_setup.sh` only creates the state bucket. The DynamoDB lock
table (`spbc-tfstate-lock`) was used by the removed stack alone; the other two stacks lock with
an S3 lock file. The EKS API allowlist options and the generated `terraform.tfvars` are gone, and
`make ci` validates two Terraform stacks instead of three.
