PYTHON := $(shell command -v $(shell brew --prefix python)/bin/python3 2>/dev/null || command -v python3 2>/dev/null || command -v python)

run:
	${PYTHON} -m pip install --user -r requirements.txt
	${PYTHON} server.py

docker:
	docker build -t app-telemetry-collector .
	docker-compose up
