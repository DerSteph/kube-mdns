FROM python:3.13-alpine AS base

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

RUN adduser -u 1000 -D app

USER app

WORKDIR /usr/src/app

FROM base AS build

RUN --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-install-project --no-dev

ADD . /usr/src/app

RUN uv sync --frozen --no-dev

FROM python:3.13-alpine AS deploy

RUN adduser -u 1000 -D app

USER app

WORKDIR /usr/src/app

COPY --from=build --chown=app:app /usr/src/app /usr/src/app

ENV PATH="/usr/src/app/.venv/bin:$PATH"

ENTRYPOINT [ ]

CMD ["python", "src/main.py"]