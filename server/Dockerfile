FROM node:22.18.0-bookworm

WORKDIR /workspace

RUN corepack enable && corepack prepare pnpm@11.22.0 --activate

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps ./apps
COPY packages ./packages
COPY scripts ./scripts
COPY supabase ./supabase
COPY tests ./tests
COPY tsconfig.json tsconfig.base.json prettier.config.js eslint.config.mjs vitest.config.ts ./

RUN pnpm install --frozen-lockfile \
  && chmod +x /workspace/scripts/*.sh

EXPOSE 8787

ENTRYPOINT ["/workspace/scripts/docker-api-entrypoint.sh"]
