-include .env

build:
	CGO_ENABLED=0 go build -ldflags="-s -w" -o kube-mdns ./cmd/kube-mdns

test:
	go test -v ./...

build-static:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o kube-mdns ./cmd/kube-mdns

image:
	docker buildx bake kube-mdns-local --load

build:
	docker buildx bake kube-mdns --load

kind-load:
	kind load docker-image kube-mdns:latest

deploy:
	kubectl apply -f manifests/

helm-lint:
	helm lint charts/kube-mdns

helm-template:
	helm template kube-mdns charts/kube-mdns

helm-package:
	helm package charts/kube-mdns -d .cr-release-packages

helm-install:
	helm upgrade --install kube-mdns charts/kube-mdns --namespace kube-mdns-system --create-namespace
