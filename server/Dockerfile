FROM ghcr.io/astral-sh/uv:0.8 AS uv
FROM python:3.13-slim-bookworm AS build
COPY --from=uv /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
WORKDIR /app
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --locked --no-dev --no-install-project
COPY src src
RUN uv sync --locked --no-dev --no-editable

FROM python:3.13-slim-bookworm
ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1 TRACKWATCH_DATA_DIR=/data
WORKDIR /app
COPY --from=build /app/.venv /app/.venv
RUN groupadd --gid 10001 app && useradd --uid 10001 --gid app --no-create-home app \
    && mkdir /data && chown app:app /data
USER 10001:10001
VOLUME /data
EXPOSE 8080
CMD ["trackwatch-push", "serve"]
