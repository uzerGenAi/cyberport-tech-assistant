SHELL := /bin/bash

.PHONY: ci backend-setup post-deploy post-deploy-force amplify smoke help \
        backends-plan backends seed-stores backends-check backends-env knowledge-bases memory

help:
	@echo "Cyberport Tech Assistant — deployment targets:"
	@echo ""
	@echo "  make backend-setup   Create the S3 bucket that holds the Terraform state  (run FIRST)"
	@echo "  make ci              Run local validation checks (Python compile + Terraform validate/test)"
	@echo ""
	@echo "  Data backends (stores database, promotions API, orders and sessions tables):"
	@echo "  make backends-plan   Show what Terraform would change"
	@echo "  make backends        Plan, confirm, and apply exactly that plan"
	@echo "  make seed-stores     Create the stores table, load the data, create the read-only user"
	@echo "  make backends-check  Live smoke test: reader query, unsigned 403, signed GET /promotions"
	@echo "  make backends-env    Print export lines for the runtime env vars"
	@echo ""
	@echo "  make knowledge-bases Bootstrap the vector store, then create/sync all five KBs"
	@echo "  make memory          Create the AgentCore Memory (then source setup_env.sh and make post-deploy-force)"
	@echo "  make post-deploy     Configure Cognito + AgentCore, then deploy the Amplify frontend"
	@echo "  make post-deploy-force  post-deploy that always redeploys the agent code"
	@echo "  make amplify         Deploy (or re-deploy) the web frontend to AWS Amplify only"
	@echo "  make smoke           Run the smoke test against SMOKE_TEST_URL"
	@echo ""
	@echo "  Typical first-time flow:"
	@echo "    make backend-setup  →  make ci  →  make backends  →  make seed-stores  →  make backends-check"
	@echo "    →  ./deploy_agentcore.sh step3-s3-bucket  →  make knowledge-bases"
	@echo "    →  ./deploy_agentcore.sh step2-iam-role  →  make post-deploy"

# Optional: AgentCore Memory (preferences, facts, session summaries) for the runtime
memory:
	cd 6_deploy/agents && python3 create_memory.py

backend-setup:
	bash 6_deploy/scripts/terraform_backend_setup.sh

ci:
	bash 6_deploy/scripts/ci_checks.sh

post-deploy:
	bash 6_deploy/scripts/post_deploy.sh

# Always ships the current agent code; the plain target skips the launch when a runtime exists
post-deploy-force:
	bash 6_deploy/scripts/post_deploy.sh --force

knowledge-bases:
	bash 3_proof_of_concept/knowledge_bases/bootstrap_vector_store.sh
	bash 3_proof_of_concept/knowledge_bases/setup_knowledge_bases.sh

amplify:
	bash 6_deploy/scripts/amplify-deploy.sh

smoke:
	bash 6_deploy/scripts/smoke_test.sh

backends-plan:
	bash 6_deploy/scripts/agentcore_backends.sh plan

backends:
	bash 6_deploy/scripts/agentcore_backends.sh apply

seed-stores:
	bash 6_deploy/scripts/agentcore_backends.sh seed

backends-check:
	bash 6_deploy/scripts/agentcore_backends.sh check

backends-env:
	@bash 6_deploy/scripts/agentcore_backends.sh env
