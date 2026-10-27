# One image for both instances; PRIMARY/SECONDARY differ only in env.
FROM node:24-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json* ./
# Optional deps carry the AWS/GCP KMS clients; each instance only loads the one it uses.
RUN npm ci --omit=dev --include=optional || npm install --omit=dev --include=optional
COPY src ./src
COPY config ./config
USER node
# `run` for a long-lived container; override with `once` for scheduled jobs.
ENTRYPOINT ["node", "src/index.ts"]
CMD ["run"]
