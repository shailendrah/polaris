#  Licensed to the Apache Software Foundation (ASF) under one
#  or more contributor license agreements.  See the NOTICE file
#  distributed with this work for additional information
#  regarding copyright ownership.  The ASF licenses this file
#  to you under the Apache License, Version 2.0 (the
#  "License"); you may not use this file except in compliance
#  with the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing,
#  software distributed under the License is distributed on an
#  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
#  KIND, either express or implied.  See the License for the
#  specific language governing permissions and limitations
#  under the License.

# Configures the shell for recipes to use bash, enabling bash commands and ensuring
# that recipes exit on any command failure (including within pipes).
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

## Variables
PYTHON ?= python3
BUILD_IMAGE ?= true
DOCKER ?= docker
MINIKUBE_PROFILE ?= minikube
DEPENDENCIES ?= ct helm helm-docs java git yamllint
OPTIONAL_DEPENDENCIES := jq kubectl minikube
PYTHON_CLIENT_DIR := client/python

## Version information
BUILD_VERSION := $(shell cat version.txt)
GIT_COMMIT := $(shell git rev-parse HEAD)

##@ General

.PHONY: help
help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9\.-]+:.*?##/ { printf "  \033[36m%-40s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: version
version: ## Display version information
	@echo "Build version: ${BUILD_VERSION}"
	@echo "Git commit: ${GIT_COMMIT}"

##@ Polaris Build

.PHONY: build
build: build-server build-admin ## Build Polaris server, admin, and container images

build-admin: DEPENDENCIES := $(DOCKER)
.PHONY: build-admin
build-admin: check-dependencies ## Build Polaris admin and container image
	@echo "--- Building Polaris admin ---"
	@BUILDKIT_PULL_POLICY=if-not-present ./gradlew \
		:polaris-admin:assemble \
		:polaris-admin:quarkusAppPartsBuild --rerun \
		-Dquarkus.container-image.build=$(BUILD_IMAGE) \
		-Dquarkus.docker.executable-name=$(DOCKER)
	@echo "--- Polaris admin build complete ---"

.PHONY: build-cleanup
build-cleanup: ## Clean build artifacts
	@echo "--- Cleaning up build artifacts ---"
	@./gradlew clean
	@echo "--- Build artifacts cleaned ---"

build-server: DEPENDENCIES := $(DOCKER)
.PHONY: build-server
build-server: check-dependencies ## Build Polaris server and container image
	@echo "--- Building Polaris server ---"
	@BUILDKIT_PULL_POLICY=if-not-present ./gradlew \
		:polaris-server:assemble \
		:polaris-server:quarkusAppPartsBuild --rerun \
		-Dquarkus.container-image.build=$(BUILD_IMAGE) \
		-Dquarkus.docker.executable-name=$(DOCKER)
	@echo "--- Polaris server build complete ---"

.PHONY: build-spark-plugin-3.5-2.12
build-spark-plugin-3.5-2.12: ## Build Spark plugin v3.5 with Scala v2.12
	@echo "--- Building Spark plugin v3.5 with Scala v2.12 ---"
	@./gradlew \
		:polaris-spark-3.5_2.12:assemble
	@echo "--- Spark plugin v3.5 with Scala v2.12 build complete ---"

.PHONY: build-spark-plugin-3.5-2.13
build-spark-plugin-3.5-2.13: ## Build Spark plugin v3.5 with Scala v2.13
	@echo "--- Building Spark plugin v3.5 with Scala v2.13 ---"
	@./gradlew \
		:polaris-spark-3.5_2.13:assemble
	@echo "--- Spark plugin v3.5 with Scala v2.13 build complete ---"

.PHONY: spotless-apply
spotless-apply: ## Apply code formatting using Spotless Gradle plugin.
	@echo "--- Applying Spotless formatting ---"
	@./gradlew spotlessApply
	@echo "--- Spotless formatting applied ---"

##@ Oracle Tests

# Oracle connection settings. Override on the command line, e.g.
#   make test ORACLE_USER=app ORACLE_PASSWORD=secret ORACLE_HOST=db.example.com
ORACLE_HOST ?= localhost
ORACLE_PORT ?= 1521
ORACLE_SERVICE ?= FREEPDB1
ORACLE_USER ?= skmishra
ORACLE_PASSWORD ?= skmishra
ORACLE_JDBC_URL ?= jdbc:oracle:thin:@//$(ORACLE_HOST):$(ORACLE_PORT)/$(ORACLE_SERVICE)

# Resolve ojdbc11 from the Gradle cache (after at least one Gradle build has run).
OJDBC_JAR = $(shell find $(HOME)/.gradle/caches/modules-2/files-2.1/com.oracle.database.jdbc/ojdbc11 -name 'ojdbc11-*.jar' -not -name '*-sources*' -not -name '*-javadoc*' 2>/dev/null | head -1)

# Env vars injected into Gradle test invocations and the Polaris run target.
ORACLE_TEST_ENV = \
	QUARKUS_DATASOURCE_JDBC_URL='$(ORACLE_JDBC_URL)' \
	QUARKUS_DATASOURCE_USERNAME='$(ORACLE_USER)' \
	QUARKUS_DATASOURCE_PASSWORD='$(ORACLE_PASSWORD)'

.PHONY: oracle-check
oracle-check: ## Check Oracle reachability and ojdbc11 availability
	@echo "--- Checking Oracle reachability at $(ORACLE_HOST):$(ORACLE_PORT) ---"
	@nc -z -w 3 $(ORACLE_HOST) $(ORACLE_PORT) || (echo "ERROR: Cannot reach $(ORACLE_HOST):$(ORACLE_PORT)" && exit 1)
	@echo "Port reachable."
	@if [ -z "$(OJDBC_JAR)" ]; then \
		echo "WARN: ojdbc11 jar not found in Gradle cache. Run any Gradle task once (e.g. 'make build-server') so the dependency is downloaded."; \
	else \
		echo "ojdbc11 jar: $(OJDBC_JAR)"; \
	fi

.PHONY: adw-reset
adw-reset: ## Drop and recreate POLARIS_SCHEMA on ADW (uses TNS_ADMIN wallet + ADW_ADMIN_PWD)
	@./tools/scripts/setup_polaris_on_adw.sh

.PHONY: test-unit
test-unit: ## Run pure unit tests (no Oracle connection needed)
	@echo "--- Running :polaris-relational-jdbc:test (unit tests) ---"
	@./gradlew :polaris-relational-jdbc:test

.PHONY: test-admin
test-admin: ## Run admin tool tests against Oracle (14 tests)
	@echo "--- Running :polaris-admin:test against $(ORACLE_JDBC_URL) ---"
	@$(ORACLE_TEST_ENV) ./gradlew :polaris-admin:test

.PHONY: test-integration
test-integration: ## Run service integration tests against Oracle (309 tests)
	@echo "--- Running :polaris-runtime-service:intTest against $(ORACLE_JDBC_URL) ---"
	@$(ORACLE_TEST_ENV) ./gradlew :polaris-runtime-service:intTest

.PHONY: test
test: test-unit test-admin test-integration ## Run all three test layers

.PHONY: test-rerun
test-rerun: ## Force-rerun all tests even if Gradle thinks they are up to date
	@echo "--- Force re-running all test layers against $(ORACLE_JDBC_URL) ---"
	@$(ORACLE_TEST_ENV) ./gradlew :polaris-relational-jdbc:test :polaris-admin:test :polaris-runtime-service:intTest --rerun-tasks

##@ Run Polaris

# Persistent token-broker RSA key pair (avoids per-restart key regeneration warnings).
DEV_DIR := .dev
DEV_KEYS_DIR := $(DEV_DIR)/keys
DEV_PUBLIC_KEY := $(DEV_KEYS_DIR)/rsa.pub
DEV_PRIVATE_KEY := $(DEV_KEYS_DIR)/rsa.key

# Log filters that quiet third-party noise we cannot fix in our codebase. Anything ERROR or above
# from these categories still surfaces; only WARN/INFO get dropped.
RUN_POLARIS_LOG_ENV = \
	QUARKUS_LOG_CATEGORY__ORG_HIBERNATE_VALIDATOR__LEVEL=ERROR \
	QUARKUS_LOG_CATEGORY__IO_MICROMETER_CORE_INSTRUMENT__LEVEL=ERROR

# Token-broker key paths (Polaris config keys) exposed as env vars.
RUN_POLARIS_KEY_ENV = \
	POLARIS_AUTHENTICATION_TOKEN_BROKER_RSA_KEY_PAIR_PUBLIC_KEY_FILE=$(CURDIR)/$(DEV_PUBLIC_KEY) \
	POLARIS_AUTHENTICATION_TOKEN_BROKER_RSA_KEY_PAIR_PRIVATE_KEY_FILE=$(CURDIR)/$(DEV_PRIVATE_KEY)

.PHONY: dev-keys
dev-keys: $(DEV_PUBLIC_KEY) $(DEV_PRIVATE_KEY) ## Generate persistent RSA key pair for the token broker (one-time)

$(DEV_PRIVATE_KEY):
	@mkdir -p $(DEV_KEYS_DIR)
	@echo "--- Generating dev RSA key pair into $(DEV_KEYS_DIR)/ ---"
	@openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out $(DEV_PRIVATE_KEY) 2>/dev/null
	@chmod 600 $(DEV_PRIVATE_KEY)

$(DEV_PUBLIC_KEY): $(DEV_PRIVATE_KEY)
	@openssl rsa -in $(DEV_PRIVATE_KEY) -pubout -out $(DEV_PUBLIC_KEY) 2>/dev/null

.PHONY: run-polaris-gradle
run-polaris-gradle: dev-keys ## Start the Polaris server natively via Gradle (no Docker; Ctrl+C to stop)
	@echo "--- Starting Polaris server against $(ORACLE_JDBC_URL) ---"
	@echo "Bootstrap credentials: POLARIS,root,s3cr3t"
	@echo "HTTP API on :8181, management on :8182"
	@echo "Token-broker keys: $(DEV_KEYS_DIR)/ (regenerate with: rm -rf $(DEV_DIR))"
	@$(ORACLE_TEST_ENV) $(RUN_POLARIS_KEY_ENV) $(RUN_POLARIS_LOG_ENV) ./gradlew :polaris-server:run

##@ Polaris (Docker)

DOCKER_COMPOSE ?= $(DOCKER) compose

.PHONY: build-polaris-cli
build-polaris-cli: ## Build the Polaris CLI Docker image (apache/polaris-cli:latest)
	@echo "--- Building apache/polaris-cli:latest ---"
	@BUILDKIT_PULL_POLICY=if-not-present $(DOCKER) build -f runtime/cli/Dockerfile -t apache/polaris-cli:latest .
	@echo "--- CLI image built ---"

.PHONY: build-polaris-images
build-polaris-images: build build-polaris-cli ## Build server, admin-tool, and CLI Docker images

.PHONY: polaris-up
polaris-up: dev-keys ## Start the Polaris server in Docker (against ADW by default)
	@echo "--- Starting polaris-server (Oracle JDBC URL: $${QUARKUS_DATASOURCE_JDBC_URL:-jdbc:oracle:thin:@$${ADW_CONNECT_ALIAS}?TNS_ADMIN=/wallet}) ---"
	@if [ -z "$${ADW_CONNECT_ALIAS:-}" ] && [ -z "$${QUARKUS_DATASOURCE_JDBC_URL:-}" ]; then \
		echo "ERROR: ADW_CONNECT_ALIAS not set. Export it from your shell or pass QUARKUS_DATASOURCE_JDBC_URL."; \
		exit 1; \
	fi
	@$(DOCKER_COMPOSE) up -d polaris-server
	@$(DOCKER_COMPOSE) ps

.PHONY: polaris-down
polaris-down: ## Stop the Polaris Docker stack
	@$(DOCKER_COMPOSE) down

.PHONY: polaris-logs
polaris-logs: ## Tail the Polaris server logs
	@$(DOCKER_COMPOSE) logs -f polaris-server

.PHONY: polaris-cli
polaris-cli: ## Run the CLI in a one-shot container. Pass args via ARGS, e.g. make polaris-cli ARGS="catalogs list"
	@$(DOCKER_COMPOSE) --profile cli run --rm polaris-cli --host polaris-server --port 8181 $(ARGS)

##@ Polaris Client

# All client-* targets require an externally managed Python venv with `uv` and the
# apache-polaris dev deps already installed. Activate it before running these targets:
#   source <your-venv>/bin/activate

.PHONY: client-build
client-build: ## Build client distribution. Pass FORMAT=sdist or FORMAT=wheel to build a specific format.
	@echo "--- Building client distribution ---"
	@if [ -n "$(FORMAT)" ]; then \
		if [ "$(FORMAT)" != "sdist" ] && [ "$(FORMAT)" != "wheel" ]; then \
			echo "Error: Invalid format '$(FORMAT)'. Supported formats are 'sdist' and 'wheel'." >&2; \
			exit 1; \
		fi; \
		echo "Building with format: $(FORMAT)"; \
		cd $(PYTHON_CLIENT_DIR) && uv build --format $(FORMAT); \
	else \
		echo "Building default distribution (sdist and wheel)"; \
		cd $(PYTHON_CLIENT_DIR) && uv build; \
	fi
	@echo "--- Client distribution build complete ---"

.PHONY: client-integration-test
client-integration-test: build-server ## Run client integration tests
	@echo "--- Starting client integration tests ---"
	@echo "Ensuring Docker Compose services are stopped and removed..."
	@$(DOCKER) compose -f $(PYTHON_CLIENT_DIR)/docker-compose.yml kill || true # `|| true` prevents make from failing if containers don't exist
	@$(DOCKER) compose -f $(PYTHON_CLIENT_DIR)/docker-compose.yml rm -f || true # `|| true` prevents make from failing if containers don't exist
	@echo "Bringing up Docker Compose services in detached mode..."
	@$(DOCKER) compose -f $(PYTHON_CLIENT_DIR)/docker-compose.yml up -d
	@echo "Waiting for Polaris HTTP health check to pass..."
	@until curl -s -f http://localhost:8182/q/health > /dev/null; do \
		echo "Still waiting for HTTP 200 from /q/health (sleeping 2s)..."; \
		sleep 2; \
	done
	@echo "Polaris is healthy. Starting integration tests..."
	@cd $(PYTHON_CLIENT_DIR) && uv run --active pytest integration_tests/
	@echo "--- Client integration tests complete ---"
	@echo "Tearing down Docker Compose services..."
	@$(DOCKER) compose -f $(PYTHON_CLIENT_DIR)/docker-compose.yml down || true # Ensure teardown even if tests fail

.PHONY: client-license-check
client-license-check: ## Run license compliance check
	@echo "--- Starting license compliance check ---"
	@cd $(PYTHON_CLIENT_DIR) && pip-licenses
	@echo "--- License compliance check complete ---"

.PHONY: client-lint
client-lint: ## Run linting checks for Polaris client
	@echo "--- Running client linting checks ---"
	@cd $(PYTHON_CLIENT_DIR) && uv run --active pre-commit run --files integration_tests/* generate_clients.py apache_polaris/cli/* apache_polaris/cli/command/* apache_polaris/cli/options/* test/*
	@echo "--- Client linting checks complete ---"

.PHONY: client-nightly-publish
client-nightly-publish: ## Build and publish nightly version to Test PyPI
	@echo "--- Starting nightly publish ---"
	@cd $(PYTHON_CLIENT_DIR) && \
	CURRENT_VERSION=$$(uv version --short) && \
	DATE_SUFFIX=$$(date -u +%Y%m%d%H%M%S) && \
	NIGHTLY_VERSION="$${CURRENT_VERSION}.dev$${DATE_SUFFIX}" && \
	echo "Publishing nightly version: $${NIGHTLY_VERSION}" && \
	uv version "$${NIGHTLY_VERSION}" && \
	uv build --clear && \
	uv publish --index testpypi
	@echo "--- Nightly publish complete ---"

.PHONY: client-regenerate
client-regenerate: ## Regenerate the client code
	@echo "--- Regenerating client code ---"
	@cd $(PYTHON_CLIENT_DIR) && $(PYTHON) -B generate_clients.py
	@echo "--- Client code regeneration complete ---"

.PHONY: client-unit-test
client-unit-test: ## Run client unit tests
	@echo "--- Running client unit tests ---"
	@cd $(PYTHON_CLIENT_DIR) && uv run --active pytest tests/
	@echo "--- Client unit tests complete ---"

##@ Helm

.PHONY: helm
helm: helm-schema-generate helm-doc-generate helm-lint helm-unittest ## Run all Helm targets (schema, docs, unittest, lint)

helm-doc-generate: DEPENDENCIES := helm-docs
.PHONY: helm-doc-generate
helm-doc-generate: check-dependencies ## Generate Helm chart documentation
	@echo "--- Generating Helm documentation ---"
	@helm-docs --chart-search-root=helm \
       --template-files site/content/in-dev/unreleased/helm-chart/reference.md.gotmpl \
       --output-file ../../site/content/in-dev/unreleased/helm-chart/reference.md \
       --sort-values-order=file
	@echo "--- Helm documentation generated and copied ---"

helm-doc-verify: DEPENDENCIES := helm-docs git
.PHONY: helm-doc-verify
helm-doc-verify: helm-doc-generate ## Verify Helm chart documentation is up to date
	@echo "--- Verifying Helm documentation is up to date ---"
	@if ! git diff --exit-code site/content/in-dev/unreleased/helm-chart/reference.md; then \
		echo "ERROR: Helm documentation is out of date. Please run 'make helm-doc-generate' and commit the changes."; \
		exit 1; \
	fi
	@echo "--- Helm documentation is up to date ---"

helm-install-plugins: DEPENDENCIES := helm
.PHONY: helm-install-plugins
helm-install-plugins: check-dependencies ## Install required Helm plugins (unittest, schema)
	@echo "--- Installing Helm plugins ---"
	@HELM_MAJOR_VERSION=$$(helm version --short | sed 's/^v//' | cut -d. -f1); \
	if [ "$$HELM_MAJOR_VERSION" -ge 4 ] 2>/dev/null; then \
		HELM_PLUGIN_FLAGS="--verify=false"; \
	else \
		HELM_PLUGIN_FLAGS=""; \
	fi; \
	if helm plugin list | grep -q "^unittest"; then \
		echo "Plugin 'unittest' is already installed."; \
	else \
		echo "Installing 'unittest' plugin..."; \
		helm plugin install $$HELM_PLUGIN_FLAGS https://github.com/helm-unittest/helm-unittest.git; \
	fi; \
	if helm plugin list | grep -q "^schema"; then \
		echo "Plugin 'schema' is already installed."; \
	else \
		echo "Installing 'schema' plugin..."; \
		helm plugin install $$HELM_PLUGIN_FLAGS https://github.com/losisin/helm-values-schema-json.git; \
	fi
	@echo "--- Helm plugins installed ---"

helm-lint: DEPENDENCIES := ct yamllint
.PHONY: helm-lint
helm-lint: check-dependencies ## Run Helm chart lint check
	@echo "--- Running Helm chart linting ---"
	@ct lint --charts helm/polaris --validate-maintainers=false
	@echo "--- Helm chart linting complete ---"

helm-schema-generate: DEPENDENCIES := helm
.PHONY: helm-schema-generate
helm-schema-generate: helm-install-plugins ## Generate Helm chart JSON schema from values.yaml
	@echo "--- Generating Helm values schema ---"
	@helm schema -f helm/polaris/values.yaml -o helm/polaris/values.schema.json --use-helm-docs --draft 7
	@echo "--- Helm values schema generated ---"

helm-schema-verify: DEPENDENCIES := helm git
.PHONY: helm-schema-verify
helm-schema-verify: helm-schema-generate ## Verify Helm chart JSON schema is up to date
	@echo "--- Verifying Helm values schema is up to date ---"
	@if ! git diff --exit-code helm/polaris/values.schema.json; then \
		echo "ERROR: Helm schema is out of date. Please run 'make helm-schema-generate' and commit the changes."; \
		exit 1; \
	fi
	@echo "--- Helm values schema is up to date ---"

helm-unittest: DEPENDENCIES := helm
.PHONY: helm-unittest
helm-unittest: helm-install-plugins ## Run Helm chart unittest
	@echo "--- Running Helm chart unittest ---"
	@helm unittest helm/polaris
	@echo "--- Helm chart unittest complete ---"

helm-fixtures: DEPENDENCIES := kubectl
.PHONY: helm-fixtures
helm-fixtures: check-dependencies ## Create namespace and deploy fixtures for Helm chart testing
	@echo "--- Creating namespace and deploying fixtures ---"
	@kubectl create namespace polaris --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply --namespace polaris -f helm/polaris/ci/fixtures/
	@echo "--- Fixtures deployed and ready ---"

helm-fixtures-cleanup: DEPENDENCIES := kubectl
.PHONY: helm-fixtures-cleanup
helm-fixtures-cleanup: check-dependencies ## Remove fixtures and namespace for Helm chart testing
	@echo "--- Removing fixtures and namespace ---"
	@kubectl delete namespace polaris --wait=true --ignore-not-found
	@echo "--- Fixtures and namespace removed ---"

helm-integration-test: DEPENDENCIES := ct
.PHONY: helm-integration-test
helm-integration-test: build minikube-load-images helm-fixtures check-dependencies ## Run Helm chart integration tests
	@echo "--- Running Helm chart integration tests ---"
	@ct install --namespace polaris --charts ./helm/polaris
	@echo "--- Helm chart integration tests complete ---"

.PHONY: helm
helm: helm-schema-generate helm-doc-generate helm-lint helm-unittest ## Run most Helm targets (schema, docs, unittest, lint) excluding integration tests

##@ Minikube

minikube-cleanup: DEPENDENCIES := minikube $(DOCKER)
.PHONY: minikube-cleanup
minikube-cleanup: check-dependencies ## Cleanup the Minikube cluster
	@echo "--- Checking Minikube cluster status ---"
	@if minikube status -p $(MINIKUBE_PROFILE) >/dev/null 2>&1; then \
		echo "--- Cleanup Minikube cluster ---"; \
		minikube delete -p $(MINIKUBE_PROFILE); \
		echo "--- Minikube cluster removed ---"; \
	else \
		echo "--- Minikube cluster does not exist. Skipping cleanup ---"; \
	fi

minikube-load-images: DEPENDENCIES := minikube $(DOCKER)
.PHONY: minikube-load-images
minikube-load-images: minikube-start-cluster check-dependencies ## Load local Docker images into the Minikube cluster
	@echo "--- Loading images into Minikube cluster ---"
	@minikube image load -p $(MINIKUBE_PROFILE) docker.io/apache/polaris:latest
	@minikube image tag -p $(MINIKUBE_PROFILE) docker.io/apache/polaris:latest docker.io/apache/polaris:$(BUILD_VERSION)
	@minikube image load -p $(MINIKUBE_PROFILE) docker.io/apache/polaris-admin-tool:latest
	@minikube image tag -p $(MINIKUBE_PROFILE) docker.io/apache/polaris-admin-tool:latest docker.io/apache/polaris-admin-tool:$(BUILD_VERSION)
	@echo "--- Images loaded into Minikube cluster ---"

minikube-start-cluster: DEPENDENCIES := minikube $(DOCKER)
.PHONY: minikube-start-cluster
minikube-start-cluster: check-dependencies ## Start the Minikube cluster
	@echo "--- Checking Minikube cluster status ---"
	@if minikube status -p $(MINIKUBE_PROFILE) --format "{{.Host}}" | grep -q "Running"; then \
		echo "--- Minikube cluster is already running. Skipping start ---"; \
	else \
		echo "--- Starting Minikube cluster ---"; \
		if [ "$(DOCKER)" = "podman" ]; then \
			minikube start -p $(MINIKUBE_PROFILE) --driver=$(DOCKER) --container-runtime=cri-o; \
		else \
			minikube start -p $(MINIKUBE_PROFILE) --driver=$(DOCKER); \
		fi; \
		echo "--- Minikube cluster started ---"; \
	fi

minikube-stop-cluster: DEPENDENCIES := minikube $(DOCKER)
.PHONY: minikube-stop-cluster
minikube-stop-cluster: check-dependencies ## Stop the Minikube cluster
	@echo "--- Checking Minikube cluster status ---"
	@if minikube status -p $(MINIKUBE_PROFILE) --format "{{.Host}}" | grep -q "Running"; then \
		echo "--- Stopping Minikube cluster ---"; \
		minikube stop -p $(MINIKUBE_PROFILE); \
		echo "--- Minikube cluster stopped ---"; \
	else \
		echo "--- Minikube cluster is already stopped or does not exist. Skipping stop ---"; \
	fi


##@ Pre-commit

.PHONY: pre-commit
pre-commit: spotless-apply helm-doc-generate client-lint ## Run tasks for pre-commit

##@ Dependencies

.PHONY: check-dependencies
check-dependencies: ## Check if all requested dependencies are present
	@echo "--- Checking for requested dependencies ---"
	@for dependency in $(DEPENDENCIES); do \
		echo "Checking for $$dependency..."; \
		if [ "$$dependency" = "java" ]; then \
			if [ -n "$$JAVA_HOME" ] && [ -x "$$JAVA_HOME/bin/java" ] && "$$JAVA_HOME/bin/java" --version >/dev/null 2>&1; then \
				echo "Java found via JAVA_HOME=$$JAVA_HOME ($$($$JAVA_HOME/bin/java --version 2>&1 | head -n1))."; \
			elif java --version >/dev/null 2>&1; then \
				echo "Java found on PATH ($$(java --version 2>&1 | head -n1)). Tip: set JAVA_HOME to pin a specific JDK."; \
			else \
				echo "--- ERROR: No working Java found. Set JAVA_HOME to a JDK install (Gradle's toolchain validates the actual version). Exiting. ---"; \
				exit 1; \
			fi ; \
		elif command -v $$dependency >/dev/null 2>&1; then \
			echo "$$dependency is installed."; \
		else \
			echo "$$dependency is NOT installed."; \
			echo "--- ERROR: Dependency '$$dependency' is missing. Please install it to proceed. Exiting. ---"; \
			exit 1; \
		fi; \
	done
	@echo "--- All checks complete. ---"

.PHONY: check-brew
check-brew:
	@echo "--- Checking Homebrew installation ---"
	@if command -v brew >/dev/null 2>&1; then \
		echo "--- Homebrew is installed ---"; \
	else \
		echo "--- Homebrew is not installed. Aborting ---"; \
		exit 1; \
	fi

.PHONY: install-dependencies-brew
install-dependencies-brew: check-brew ## Install dependencies if not present via Brew
	@echo "--- Checking and installing dependencies for this target ---"
	@for dependency in $(DEPENDENCIES); do \
		case $$dependency in \
			java) \
				if [ -n "$$JAVA_HOME" ] && [ -x "$$JAVA_HOME/bin/java" ]; then \
					:; \
				elif command -v java >/dev/null 2>&1; then \
					:; \
				else \
					echo "Java is not installed. Installing openjdk and jenv..."; \
					brew install openjdk jenv; \
					$(shell brew --prefix jenv)/bin/jenv add $(shell brew --prefix openjdk); \
					echo "Java installed via Homebrew. Set JAVA_HOME or rely on Gradle's toolchain."; \
				fi ;; \
			docker|podman) \
				if command -v $$dependency >/dev/null 2>&1; then \
					:; \
				else \
					echo "$$dependency is not installed. Manual installation required"; \
				fi ;; \
			ct) \
				if command -v ct >/dev/null 2>&1; then \
					:; \
				else \
					echo "ct is not installed. Installing with Homebrew..."; \
					brew install chart-testing; \
					echo "ct installed."; \
				fi ;; \
			*) \
				if command -v $$dependency >/dev/null 2>&1; then \
					:; \
				else \
					echo "$$dependency is not installed. Installing with Homebrew..."; \
					brew install $$dependency; \
					echo "$$dependency installed."; \
				fi ;; \
		esac; \
	done
	@echo "--- All requested dependencies checked/installed ---"

install-optional-dependencies-brew: DEPENDENCIES := $(OPTIONAL_DEPENDENCIES)
.PHONY: install-optional-dependencies-brew
install-optional-dependencies-brew: install-dependencies-brew ## Install optional dependencies if not present via Brew
