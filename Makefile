include .env

image:
	docker buildx bake kube-mdns-local --load

build:
	docker buildx bake kube-mdns --load

kind-load:
	kind load docker-image kube-mdns:latest

deploy:
	kubectl apply -f manifests/