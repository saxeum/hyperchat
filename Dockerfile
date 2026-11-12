# Pinned by digest, not by tag: `python:3.13-slim` and `uv:latest` are both mutable, so a clone-and-build
# today fetches a different binary than a build last week, as root, with no record of which one. The tag
# stays beside the digest because a digest alone tells a reader nothing about what they are building on.
FROM python:3.15-slim@sha256:65a65fc7b30b06cb6df4930fd4650697cb23f4c2698ab81fc87e4b031bc36928

COPY --from=ghcr.io/astral-sh/uv:0.13.7@sha256:96f40d3904aad8d0bd010539001d36c8e2188b981e1334471a90c4a1d93bb490 /uv /bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    VIRTUAL_ENV=/app/.venv \
    PATH=/app/.venv/bin:$PATH

# A user of its own. Nothing in this image needs to write, so running as root would be a cost paid
# only on the day the process is compromised. 10001 is arbitrary but fixed: a stable uid is what
# makes a volume or a policy refer to the same thing across builds.
RUN useradd --create-home --uid 10001 app

WORKDIR /app

# Dependencies first, without the project: `uv sync` also installs the project, and the project
# needs `src/`, so the split only holds with --no-install-project. Without it this layer is a
# dependency layer that secretly depends on the source, which is to say not a layer at all.
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --frozen --no-dev --no-install-project

COPY src ./src
RUN uv sync --frozen --no-dev

USER app
EXPOSE 8080

# uvicorn directly, not `uv run`: the virtualenv is on PATH, and a process supervisor in a container
# should be the process itself.
CMD ["uvicorn", "hyperchat.main:api", "--host", "0.0.0.0", "--port", "8080"]
