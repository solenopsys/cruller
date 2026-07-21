FROM debian:trixie-slim AS runtime
WORKDIR /app

# TLS roots for outbound fetch()/HTTPS (webcore is kept, see README "What's kept").
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# build/release/bun is glibc-linked and requires GLIBC_2.38+ (portable ReleaseFast
# build, see problem.md); unlike upstream oven/bun there is no Alpine/musl variant
# yet, hence a newer glibc base instead of alpine (bookworm's 2.36 is too old).
COPY ./build/release/bun /usr/local/bin/bun
RUN chmod +x /usr/local/bin/bun \
    && useradd -u 1000 -M -r -s /usr/sbin/nologin default
USER 1000

ENV PATH="/usr/local/bin:$PATH"

# Cruller has no CLI dispatch: it only executes an already-built entrypoint,
# e.g. `bun ./server.js` or `bun run --config=<path> <entrypoint>`.
CMD ["bun"]
