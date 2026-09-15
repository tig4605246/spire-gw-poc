SHELL := /bin/bash
MODE ?= standalone
# Modes: standalone (A), istio (B), istio-gateway-api (C).
export MODE

.PHONY: tools generate test build bootstrap e2e dashboard inspect destroy
tools:
	./scripts/tools.sh
generate:
	./scripts/generate-api.sh
	./scripts/render-envoy.sh --zone zone-a --validate --output /dev/null
	./scripts/render-envoy.sh --zone zone-b --validate --output /dev/null
test:
	go test ./...
	go vet ./...
	go test -race ./...
	bash ./test/e2e_harness_test.sh
	bash ./test/verify_svid_chain_test.sh
	python3 ./test/gateway_api_conditions_test.py
	./scripts/check.sh
build:
	source versions.env; docker build --build-arg GO_VERSION=$$GO_VERSION --build-arg BASE_IMAGE=$$DISTROLESS_IMAGE --build-arg COMMAND=zone-trust-controller -t spire-gw-controller:dev .
	source versions.env; docker build --build-arg GO_VERSION=$$GO_VERSION --build-arg BASE_IMAGE=$$DISTROLESS_IMAGE --build-arg COMMAND=echo-app -t spire-gw-app:dev .
bootstrap:
	./scripts/bootstrap.sh
e2e:
	./scripts/e2e.sh
dashboard:
	./scripts/dashboard.sh
inspect:
	./scripts/inspect.sh
destroy:
	./scripts/destroy.sh
