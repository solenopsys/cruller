FROM oven/bun:1.3.14-alpine AS build

# Build natively against musl. Alpine edge supplies the LLVM 21 toolchain
# expected by this checkout; the final runtime remains on stable Alpine.
RUN sed -i 's/v3.22/edge/g' /etc/apk/repositories \
    && apk add --no-cache \
        bash \
        cargo \
        clang21 \
        clang21-dev \
        cmake \
        git \
        lld21 \
        llvm21-dev \
           ninja-build \
           perl \
           rust \
           unzip \
           wget \
           xz

RUN mkdir -p /opt \
    && wget -q https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz -O /tmp/zig.tar.xz \
    && tar -xJf /tmp/zig.tar.xz -C /opt \
    && mv /opt/zig-x86_64-linux-0.16.0 /opt/zig \
    && rm /tmp/zig.tar.xz

ENV PATH="/usr/lib/llvm21/bin:/usr/lib/ninja-build/bin:$PATH"
ENV BUN_ZIG_PATH="/opt/zig"
WORKDIR /src

# vendor/zig is a local development symlink in this checkout. Exclude it so
# the build's existing fetch rule downloads the pinned compiler in-container.
COPY --exclude=vendor/zig --exclude=build . /src
RUN bun scripts/build.ts \
      --profile=release \
      --os=linux \
      --arch=x64 \
      --abi=musl \
      --webkit=prebuilt \
      --build-dir=build/release-musl

FROM alpine:3.22 AS runtime
WORKDIR /app

RUN apk add --no-cache ca-certificates libstdc++ libgcc \
    && adduser -D -H -s /sbin/nologin -u 1000 default

COPY --from=build /src/build/release-musl/bun /usr/local/bin/bun
RUN chmod +x /usr/local/bin/bun
USER 1000

ENV PATH="/usr/local/bin:$PATH"

# Cruller executes an already-built entrypoint, for example:
# `bun ./server.js` or `bun run --config=<path> <entrypoint>`.
CMD ["bun"]
