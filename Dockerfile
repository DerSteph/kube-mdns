FROM --platform=$BUILDPLATFORM golang:1.23-alpine AS builder

WORKDIR /build

COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64} go build -ldflags="-s -w" -o kube-mdns ./cmd/kube-mdns

FROM alpine:3.20 AS deploy

RUN adduser -u 1000 -D app

COPY --from=builder /build/kube-mdns /usr/local/bin/kube-mdns

USER app

ENTRYPOINT ["/usr/local/bin/kube-mdns"]
