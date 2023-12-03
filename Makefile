include .env

image:
	docker buildx build -t ${DOCKER_REGISTRY_HOST} --progress plain --platform linux/amd64,linux/arm64,linux/arm/v7 --push .