"""The startup lines, in the shape uvicorn actually imposes.

`caplog` cannot see the defect this file is about. It attaches a handler at the root and takes its
level from pytest, so a test written that way measures that the code calls `logger.info` — which was
never in doubt — and not whether the process that runs the app has a handler and a level at all.
Neither did: uvicorn's `LOGGING_CONFIG` configures `uvicorn`, `uvicorn.error` and `uvicorn.access`
and has no `root` entry, so `hyperchat` inherited `WARNING` and no handler, and every INFO line the
service logs about itself went nowhere in a deployed revision while the warnings appeared.

These run in a **subprocess**, and that is not decoration. The logging configuration is process-global;
applying uvicorn's `dictConfig` inside the suite's own process would clear pytest's handlers and change
the behaviour of every test after it. A fresh interpreter is the only place the configuration the
deployed process has can be measured — and it is the configuration that was wrong.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

# The order `uvicorn.main.run` imposes: `Config()` applies its logging configuration, then
# `load_app()` imports the module named on the command line. So the app is configured *after*
# uvicorn's dictConfig, not before, which is what makes an import-time handler the surviving one.
UVICORN_SHAPE = """
import json, logging, logging.config
from uvicorn.config import LOGGING_CONFIG

logging.config.dictConfig(LOGGING_CONFIG)
import hyperchat.main  # noqa: F401

logger = logging.getLogger("hyperchat")
logger.info("service config model=probe")
print(json.dumps({
    "effective": logger.getEffectiveLevel(),
    "root_level": logging.getLogger().level,
    "root_handlers": len(logging.getLogger().handlers),
    "httpx2": logging.getLogger("httpx2").getEffectiveLevel(),
}))
"""

# The same configuration, then the lifespan the deployed revision actually runs. No provider key, so
# this is the shape where the warning and the INFO line have to appear together.
LIFESPAN_SHAPE = """
import asyncio, logging.config
from uvicorn.config import LOGGING_CONFIG

logging.config.dictConfig(LOGGING_CONFIG)
import hyperchat.main as main


async def go():
    async with main.lifespan(main.api):
        pass


asyncio.run(go())
"""


def run(script: str, **environment: str) -> subprocess.CompletedProcess[str]:
    """One fresh interpreter with the app imported the way uvicorn imports it.

    `sys.executable`, not `uv`: the interpreter running the suite has the package installed in both
    the checkout and CI, and a stripped PATH is how a sibling test first failed with "No such file or
    directory: 'uv'".
    """
    return subprocess.run(
        [sys.executable, "-c", script],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, **environment},
    )


def test_the_app_logger_is_at_info_after_a_plain_import():
    """The assertion `caplog` cannot make, and the one that failed before the fix: 30, not 20.

    `basicConfig` would pass this in a fresh process and be a no-op here, because pytest has already
    put handlers on the root. The level this asserts is the logger's own, so it holds wherever the
    module is imported — which is what makes it a statement about the app rather than about uvicorn.
    """
    import hyperchat.main  # noqa: F401

    assert logging.getLogger("hyperchat").getEffectiveLevel() <= logging.INFO


def test_the_log_level_survives_the_configuration_uvicorn_imposes():
    done = run(UVICORN_SHAPE)

    assert done.returncode == 0, done.stderr[-800:]
    observed = json.loads(done.stdout)

    assert observed["effective"] <= logging.INFO


def test_the_config_line_is_emitted_under_uvicorn_s_configuration():
    """Not "the code called logger.info": the record reached the stream the process writes to."""
    done = run(UVICORN_SHAPE)

    assert "INFO:hyperchat:service config model=probe" in done.stderr, done.stderr[-800:]


def test_the_config_log_level_does_not_raise_another_logger():
    """Why this is not `basicConfig(level=INFO)`.

    A root at INFO raises every child, and on this service that turns on `httpx2`'s request line once
    per provider call (`INFO:httpx2:HTTP Request: POST https://api.deepseek.com/...`). The level that
    was wrong is `hyperchat`'s, so only `hyperchat`'s is set; every other logger keeps the level it
    had, which is the scope this ticket drew.
    """
    done = run(UVICORN_SHAPE)
    observed = json.loads(done.stdout)

    assert observed["root_level"] == logging.WARNING
    assert observed["root_handlers"] == 0
    assert observed["httpx2"] == logging.WARNING


def test_the_unset_key_warning_logs_beside_the_config_line():
    """Both lines, because the fix must not be visible only by raising the floor past the warnings.

    `PROVIDER_API_KEY=""` is an unset key: the client reads a blank value as "the model is off", so
    this is the deployed path with no key. The warning stays a warning — it is a state an operator
    must not miss — and the INFO line now appears beside it instead of nowhere.
    """
    done = run(LIFESPAN_SHAPE, PROVIDER_API_KEY="")

    assert done.returncode == 0, done.stderr[-800:]
    assert "INFO:hyperchat:service config model=" in done.stderr, done.stderr[-1200:]
    assert "WARNING:hyperchat:provider key is unset" in done.stderr, done.stderr[-1200:]
    # The config line carries the facts #19 and #101 were accepted on.
    config_line = next(line for line in done.stderr.splitlines() if "service config model=" in line)
    assert "config_sha256=" in config_line
    assert "tracing=" in config_line
