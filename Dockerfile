FROM python:3.13-alpine AS base

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

RUN adduser -u 1000 -D app

FROM base AS build

ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy
ENV UV_NO_DEV=1
ENV UV_PYTHON_DOWNLOADS=0

WORKDIR /usr/src/app

RUN chown -R app:app /usr/src/app

USER app

RUN --mount=type=cache,target=/home/app/.cache/uv,uid=1000,gid=1000 \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project

COPY --chown=app:app . .

RUN uv sync --locked

FROM python:3.13-alpine AS deploy

RUN adduser -u 1000 -D app

WORKDIR /usr/src/app

COPY --from=build --chown=app:app /usr/src/app /usr/src/app

USER app

ENV PATH="/usr/src/app/.venv/bin:$PATH"

CMD ["python", "-m", "src.main"]