FROM alpine:3.20 AS builder

RUN apk add --no-cache zig

WORKDIR /build
COPY . .

RUN zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall

FROM alpine:3.20 AS deploy

RUN adduser -u 1000 -D app

COPY --from=builder /build/zig-out/bin/kube-mdns /usr/local/bin/kube-mdns

USER app

ENTRYPOINT ["/usr/local/bin/kube-mdns"]
