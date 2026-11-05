-include .env

build-zig:
	zig build -Doptimize=ReleaseSafe

test-zig:
	zig build test

build-static:
	zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall

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
