# Cross-FEAT Integration Verification — Iteration 1 (fixer)

All-AWS-native CI/CD migration (CodeCommit + CodePipeline + CodeBuild).
FEAT-001 (new codepipeline stack + buildspecs + operator README), FEAT-002 (ci_checks.sh
extension), FEAT-003 (GitHub retirement) were each already implemented and committed on branch
`codecommit-ci`. This note records the end-to-end integration checks the fixer ran so the reviewer
does not need to re-run them.

Environment: `export PATH="$HOME/.spbc-deploy/bin:/opt/homebrew/bin:$PATH"`, `AWS_REGION=eu-central-1`,
`AWS_PAGER=""`. Terraform v1.16.6 (`/opt/homebrew/bin/terraform`). Static/offline only — NO AWS calls,
no `terraform apply`, no `create-repository`.

## 1. Full build + tests — `make ci` (validates all three Terraform stacks)

Command: `make ci` from the worktree root. Result: **PASS** (exit 0). Output:

```
bash 6_deploy/scripts/ci_checks.sh
Running CI validations
Validating Terraform files (EKS stack)
Validating and testing Terraform files (AgentCore backends; mocked providers)
Validating Terraform files (CodePipeline stack)
CI checks passed
```

This confirms FEAT-002's extension is wired in: `ci_checks.sh` runs `python3 -m compileall` over the
Python trees, then `terraform fmt -check -recursive` + `init -backend=false` + `validate` on the EKS
stack (`6_deploy/infra/terraform`), the AgentCore backends stack (`6_deploy/infra/agentcore-backends`,
incl. `terraform test`), and the **new** CodePipeline stack (`6_deploy/infra/codepipeline`). All three
validate clean.

## 2. Buildspecs parse as YAML (pyyaml in ephemeral env)

pyyaml is not preinstalled, so it was installed into an ephemeral venv
(`python3 -m venv /tmp/ci-yaml-venv && .../pip install pyyaml`), used to parse both buildspecs, then
the venv was removed. Result: **PASS**.

```
OK  6_deploy/codepipeline/buildspec-ci.yml      version=0.2  phases=['install', 'build']
OK  6_deploy/codepipeline/buildspec-deploy.yml  version=0.2  phases=['install', 'build']
Both buildspecs parse as valid YAML.
```

Each parses to a mapping with top-level `version` (0.2) and `phases` keys.

## 3. Seams between the three FEATs — all consistent, no fixes needed

- **Buildspec paths.** `6_deploy/infra/codepipeline/codebuild.tf` references
  `6_deploy/codepipeline/buildspec-ci.yml` and `6_deploy/codepipeline/buildspec-deploy.yml`; both files
  exist at those paths (confirmed). `buildspec-ci.yml` runs `make ci`, so the pipeline Validate stage
  exercises all three stacks (ties FEAT-001 to FEAT-002).
- **ci_checks.sh → new stack path.** `ci_checks.sh` block "Validating Terraform files (CodePipeline
  stack)" `cd`s into `6_deploy/infra/codepipeline` — the exact dir FEAT-001 created. Verified by the
  `make ci` run above.
- **Doc cross-references.** `README.md` ("Running it from CI") links to
  `6_deploy/codepipeline/buildspec-deploy.yml` and `6_deploy/infra/codepipeline/README.md`;
  `6_deploy/scripts/README.md` links to `../codepipeline/buildspec-deploy.yml`. All targets exist and
  describe the Source → Validate → Approve → Deploy pipeline with the five `TOGGLE_*` variables.
- **GitHub retirement (FEAT-003) leaves no dangling CI references.**
  - `.github/` directory: gone (`ls .github` → No such file or directory).
  - `6_deploy/infra/github-oidc/` stack: gone (`ls` → No such dir).
  - Tree-wide grep for `github|AWS_DEPLOY_ROLE_ARN|workflow_dispatch|github-oidc|actions/|GITHUB_SHA|gh workflow|deploy.yml|ci.yml`
    over source files (excluding `.git/`, `.agents/`, and vendored `.terraform/` modules) returns only
    legitimate, non-CI matches:
    - `6_deploy/scripts/setup_dev_tools.sh` — `api.github.com` / `github.com` download URLs for
      docker-compose and eksctl (whitelisted tool downloads).
    - `6_deploy/infra/terraform/main.tf` — `kubernetes.github.io/autoscaler` Helm repo URL.
    - `6_deploy/web-app/buildspec.yml` and `6_deploy/codepipeline/buildspec-*.yml` — comments that
      describe what the AWS pipeline *replaced* (historical "GitHub Actions runner" / "retired
      .github/workflows/*.yml"); these are accurate descriptive comments, not live references.
    - `6_deploy/infra/codepipeline/{versions.tf,iam.tf,README.md}` — intentional references noting the
      SPBC-Deploy-Permissions policy was ported verbatim from the retired `github-oidc` stack.
    - `.agents/tasks/*` planning/design docs — expected to mention GitHub (untracked, not code).

## 4. Git / state hygiene

- No `.terraform/` or `.terraform.lock.hcl` is tracked under `6_deploy/infra/codepipeline/`
  (`.gitignore` excludes them). The two pre-existing lockfiles under `6_deploy/infra/terraform` and
  `6_deploy/infra/agentcore-backends` were already tracked on `origin/main` and are untouched by this
  work.
- Worktree tree was clean before this note (the three FEAT commits `b650e17`, `984c6cc`, `a793a45`
  were already in place); the only untracked items were the `.agents/tasks/` planning artifacts.

## Conclusion

The three features integrate cleanly. `make ci` is green across all three stacks, both buildspecs are
valid YAML, every cross-feature path/reference resolves, and GitHub is fully retired with no dangling
CI references. No seam fixes were required in this iteration.
