include .env

image:
	docker buildx build -t kube-mdns:latest --progress plain --platform linux/amd64,linux/arm64,linux/arm/v7 --push .

build:
	docker buildx build -t kube-mdns:latest --target deploy --load .

kind-load:
	kind load docker-image kube-mdns:latest

deploy:
	kubectl apply -f manifests/