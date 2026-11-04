FROM oven/bun:1

WORKDIR /app

COPY package.json bun.lock* ./
RUN bun install --frozen-lockfile || bun install

COPY index.ts ./

ENV PORT=8787
ENV HOST=0.0.0.0
ENV DB_PATH=/data/quern-sync.db

EXPOSE 8787

VOLUME ["/data"]

CMD ["bun", "run", "index.ts"]
