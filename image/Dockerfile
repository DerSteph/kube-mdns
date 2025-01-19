FROM python:3.13-alpine AS base

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

RUN adduser -u 1000 -D nonrootuser

USER nonrootuser

WORKDIR /usr/src/app

