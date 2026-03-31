PYTHON ?= python3
REPO ?= .

.PHONY: init doctor probe render run stop remove logs netlogs encrypt decrypt test lint format

init:
	$(PYTHON) -m agent_sandbox init

doctor:
	$(PYTHON) -m agent_sandbox doctor

probe:
	$(PYTHON) -m agent_sandbox provider probe

render:
	$(PYTHON) -m agent_sandbox config render

run:
	$(PYTHON) -m agent_sandbox run $(REPO)

stop:
	$(PYTHON) -m agent_sandbox stop

remove:
	$(PYTHON) -m agent_sandbox remove

logs:
	$(PYTHON) -m agent_sandbox logs

netlogs:
	$(PYTHON) -m agent_sandbox netlogs

encrypt:
	$(PYTHON) -m agent_sandbox encrypt

decrypt:
	$(PYTHON) -m agent_sandbox decrypt

test:
	pytest

lint:
	ruff check src tests
	bandit -q -r src

format:
	ruff format src tests
