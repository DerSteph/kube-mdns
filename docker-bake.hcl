variable "REGISTRY" {
  default = ""
}

variable "IMAGE_NAME" {
  default = "kube-mdns"
}

variable "TAG" {
  default = "latest"
}

group "default" {
  targets = ["kube-mdns"]
}

target "kube-mdns" {
  dockerfile = "Dockerfile"
  tags = ["${REGISTRY}${IMAGE_NAME}:${TAG}"]
  platforms = ["linux/amd64", "linux/arm64"]
}

# Single-platform target for local `--load` usage (loads image into local docker)
target "kube-mdns-local" {
  dockerfile = "Dockerfile"
  tags = ["${REGISTRY}${IMAGE_NAME}:${TAG}"]
  platforms = ["linux/amd64"]
}
