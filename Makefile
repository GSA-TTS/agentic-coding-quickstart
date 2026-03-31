SHELL := /bin/bash

PYTHON ?= python3
PACKAGE := agent_sandbox
REPO ?= .
RUFF := ruff
PYTEST := pytest
BANDIT := bandit

.DEFAULT_GOAL := help

.PHONY: help install install-dev init doctor probe config render run dry-run stop remove logs netlogs encrypt decrypt lint format test clean distclean

help:
	@echo "agent-sandbox developer commands"
	@echo
	@echo "Setup:"
	@echo "  make install       Install package"
	@echo "  make install-dev   Install package with dev dependencies"
	@echo
	@echo "Core workflow:"
	@echo "  make init          Initialize local agent-sandbox state"
	@echo "  make doctor        Validate required tools and environment"
	@echo "  make probe         Probe provider and write provider lock"
	@echo "  make config        Render opencode.json"
	@echo "  make run           Run sandbox"
	@echo "  make dry-run       Show sandbox commands without executing"
	@echo
	@echo "Operations:"
	@echo "  make stop          Stop sandbox"
	@echo "  make remove        Remove sandbox"
	@echo "  make logs          Show recent audit logs"
	@echo "  make netlogs       Show sandbox network logs"
	@echo
	@echo "Secrets:"
	@echo "  make encrypt       Encrypt .env -> .env.enc"
	@echo "  make decrypt       Decrypt .env.enc -> .env"
	@echo
	@echo "Quality:"
	@echo "  make lint          Run ruff and bandit"
	@echo "  make format        Format code"
	@echo "  make test          Run tests"
	@echo
	@echo "Cleanup:"
	@echo "  make clean         Remove caches and local build output"
	@echo "  make distclean     Clean plus local runtime state"

install:
	$(PYTHON) -m pip install .

install-dev:
	$(PYTHON) -m pip install -e ".[dev]"

init:
	$(PYTHON) -m $(PACKAGE) init $(REPO)

doctor:
	$(PYTHON) -m $(PACKAGE) doctor $(REPO)

probe:
	$(PYTHON) -m $(PACKAGE) provider probe $(REPO)

config render:
	$(PYTHON) -m $(PACKAGE) config render $(REPO)

config: render

run:
	$(PYTHON) -m $(PACKAGE) run $(REPO)

dry-run:
	$(PYTHON) -m $(PACKAGE) run $(REPO) --dry-run

stop:
	$(PYTHON) -m $(PACKAGE) stop $(REPO)

remove:
	$(PYTHON) -m $(PACKAGE) remove $(REPO)

logs:
	$(PYTHON) -m $(PACKAGE) logs $(REPO)

netlogs:
	$(PYTHON) -m $(PACKAGE) netlogs $(REPO)

encrypt:
	$(PYTHON) -m $(PACKAGE) encrypt $(REPO)

decrypt:
	$(PYTHON) -m $(PACKAGE) decrypt $(REPO)

lint:
	$(RUFF) check src tests
	$(RUFF) format --check src tests
	$(BANDIT) -q -r src -c pyproject.toml

format:
	$(RUFF) check src tests --fix
	$(RUFF) format src tests

test:
	$(PYTEST)

clean:
	rm -rf .pytest_cache .ruff_cache .mypy_cache htmlcov build dist
	find . -type d -name '__pycache__' -prune -exec rm -rf {} +
	find . -type d -name '*.egg-info' -prune -exec rm -rf {} +
	find . -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete

distclean: clean
	rm -rf .agent-sandbox
	rm -f opencode.json opencode.jsonc