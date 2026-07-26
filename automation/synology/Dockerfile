FROM python:3.12-slim-bookworm

ARG CODEX_CLI_VERSION=0.137.0

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        gh \
        git \
        nodejs \
        npm \
    && npm install --global "@openai/codex@${CODEX_CLI_VERSION}" \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/pr-issue-worker
COPY automation/synology/pyproject.toml ./
COPY automation/synology/src ./src
RUN python -m pip install --no-cache-dir .

RUN useradd --create-home --uid 1000 --shell /usr/sbin/nologin worker \
    && mkdir -p /data/workspaces \
    && chown -R worker:worker /data

ENV HOME=/home/worker \
    DATA_PATH=/data \
    STATE_PATH=/data/state.sqlite3 \
    WORKSPACE_PATH=/data/workspaces \
    PYTHONUNBUFFERED=1

USER worker
ENTRYPOINT ["pr-issue-worker"]
CMD ["serve"]
