FROM alpine:3.20 AS builder

RUN apk add --no-cache zig

WORKDIR /build
COPY . .

ARG TARGETARCH

RUN case "${TARGETARCH}" in \
      "amd64") TARGET="x86_64-linux-musl" ;; \
      "arm64") TARGET="aarch64-linux-musl" ;; \
      *) TARGET="native" ;; \
    esac && \
    echo "Building for target ${TARGET} (TARGETARCH=${TARGETARCH})..." && \
    if [ "$TARGET" = "native" ]; then \
      zig build -Doptimize=ReleaseSmall ; \
    else \
      zig build -Dtarget="${TARGET}" -Doptimize=ReleaseSmall ; \
    fi

FROM alpine:3.20 AS deploy

RUN adduser -u 1000 -D app

COPY --from=builder /build/zig-out/bin/kube-mdns /usr/local/bin/kube-mdns

USER app

ENTRYPOINT ["/usr/local/bin/kube-mdns"]
