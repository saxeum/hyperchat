"""The app.

Two values are read at import — the expected audience and the allowlist — and the process refuses to
start without them. That is deliberate: a service that boots with an empty allowlist answers 403 to
everybody without looking broken, so the failure has to be a crash rather than a healthy-looking
process nobody can use.

`/` stays open. It returns a constant and spends nothing. `/livez` and `/readyz` are open too,
because a probe cannot present a token: `/livez` answers for the process and the event loop, and
`/readyz` reads the configuration loaded at import rather than calling the provider. `/healthz` is
deliberately absent: Google Frontend reserves that path and never forwards it, so a probe there
could never pass. Everything under `/api` is behind the trust boundary, and the dependency that
enforces it sits on the router rather than on the routes, so adding a route there is the only step
required to protect it.

`/api/chat` is the only route that spends money, so it is the only one with five ways to fail, and
each one is a different sentence because each one is a different thing for the caller to do:

- 422 when the message is over 4000 characters, before any provider call.
- 429 when this caller is over `RATE_LIMIT_PER_MINUTE`, with `Retry-After`.
- 503 when no provider key is configured — the model is off, not broken.
- 502 when the provider itself fails, including its own timeout.
- 504 when the *run* hits a bound, and the two say which: the step ceiling or the time budget.
"""

from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Request
from langchain_core.messages import HumanMessage
from pydantic import BaseModel, Field

from hyperchat import configuration, tracing
from hyperchat.agent import (
    BudgetExceeded,
    NotConfigured,
    ProviderFailed,
    StepLimitExceeded,
    close_model,
    get_model,
)
from hyperchat.agent import run as run_graph
from hyperchat.auth import AuthError, Caller, NotAllowedError, UpstreamError, verify_token
from hyperchat.config import bounds, load_settings
from hyperchat.limits import RateLimiter

# Read here, not in `config`, so that importing the graph does not require an allowlist: `make chat`
# and `langgraph dev` are tools, and a tool that needs the production trust boundary configured is a
# tool nobody runs. The service still refuses to start without it, because this line runs on import.
settings = load_settings()

# uvicorn's `LOGGING_CONFIG` configures `uvicorn`, `uvicorn.error` and `uvicorn.access`, and has no
# `root` entry. This logger is a child of an unconfigured root, so it inherited a `WARNING` floor and
# no handler: every INFO line the service logs about itself — `service config …` with the hashes and
# the tracing report, the prompt and corpus identities — was dropped in a deployed revision while the
# warnings appeared. `#19` and `#101` were both accepted on greps for those lines, and the count was
# zero.
#
# `logging.basicConfig(level=logging.INFO)` fixes that and is too blunt: a root at INFO also raises
# every other logger, which turned on `httpx2`'s request line — measured, once per provider call:
#     INFO:httpx2:HTTP Request: POST https://api.deepseek.com/v1/chat/completions "HTTP/1.1 200 OK"
# The level that was wrong is this logger's, so this logger gets it. `uvicorn`'s `Config.__init__`
# applies its own configuration before `load_app()` imports this module, so this handler is installed
# after uvicorn's dictConfig and is not cleared by it; with `disable_existing_loggers: False` and no
# `root` key, nothing else in that configuration touches it.
#
# Not `propagate = False`: `caplog` reads the root, and a logger that only writes to its own handler
# is a logger the suite cannot assert on. The duplication that leaves is a record reaching both this
# handler and a root handler that uvicorn does not install.
logger = logging.getLogger("hyperchat")
logger.setLevel(logging.INFO)
_handler = logging.StreamHandler()
_handler.setFormatter(logging.Formatter("%(levelname)s:%(name)s:%(message)s"))
logger.addHandler(_handler)

_limiter: RateLimiter | None = None

# The configuration the startup line reported. Kept so a run's trace carries the hash of the
# configuration the line printed rather than a second reading of the environment — one process, one
# configuration, one hash. `None` until the lifespan runs, which is the case for a test client that
# does not start the app; `run_metadata` then resolves on demand rather than reporting nothing.
_block: configuration.Configuration | None = None


def rate_limiter() -> RateLimiter:
    """The one limiter. Built on first use so importing the app does not need the environment."""
    global _limiter
    if _limiter is None:
        _limiter = RateLimiter(bounds().rate_limit_per_minute)
    return _limiter


@asynccontextmanager
async def lifespan(_app: FastAPI):
    """The provider client lives as long as the process: built here, closed on shutdown.

    Building it at startup rather than on the first request is what moves an *unset* key to boot,
    where it is a log line instead of a 503 somebody finds later. It does not fail the boot: an unset
    key is "the model is off", and `/api/chat` says 503 when it is.

    A key that is present but *wrong* is not visible here at all. Constructing a client makes no
    request, so there is nothing to be rejected yet: that failure waits for the first call, where it
    is the 502 any provider failure is.
    """
    # What this process will answer with, in the same one-line format the eval writes, so `grep
    # config` answers "what is running" and "what did this score measure" the same way. `INFO`, which
    # reaches the log because the handler and the level are installed at import above: uvicorn's
    # configuration leaves this logger alone, and until that was fixed this line was written nowhere.
    # `overrides` is empty here and named anyway: an absent field and an empty one read differently to
    # a parser.
    #
    # The tracing pairs ride on this line rather than a second one: a misconfigured tracer is the one
    # failure that is otherwise silent, and two startup lines saying "what is running" is how the two
    # disagree. They are a report, so they cannot fail this startup.
    global _block
    _block = configuration.resolved()
    logger.info("%s", configuration.line("service", _block, overrides="", **tracing.fields()))

    try:
        get_model()
    except NotConfigured:
        # A warning because it is a state an operator must not miss, not because it is the only level
        # that is visible: `service config` above is INFO and now appears beside it. It is not an
        # error -- a deployment without a key is a deployment with the model turned off.
        logger.warning("provider key is unset: /api/chat will answer 503")
    yield
    await close_model()


api = FastAPI(title="hyperchat", lifespan=lifespan)


@api.get("/")
def hello() -> dict[str, str]:
    return {"hello": "world"}


@api.get("/livez")
async def livez() -> dict[str, int | str]:
    """Liveness: the process and the event loop, with no dependency checked.

    An async handler is the event-loop check: a blocked loop cannot answer it. The provider is not
    part of this answer on purpose, because an outage should not restart an otherwise healthy
    instance.
    """
    return {"status": "ok", "pid": os.getpid()}


# Both the startup and readiness probes call this route. It must read only cached state and never call
# the provider: a provider outage here would drain every instance from traffic rather than restart one,
# which is the opposite of what liveness is for.
@api.get("/readyz")
def readyz() -> dict[str, str]:
    """Readiness: the trust boundary cached at import, never a provider call.

    `load_settings()` already refuses to start without these values, so a failure here means the
    process lost the state it booted with. The model being off is not unreadiness: `/api/chat`
    answers 503 and the rest of the service still works.
    """
    if not settings.expected_audience or not settings.allowed_subs:
        raise HTTPException(
            status_code=503, detail="not ready: the trust boundary is not configured"
        )
    return {"status": "ok"}


def require_caller(request: Request) -> Caller:
    """The trust boundary. Everything protected depends on this and nothing else checks a token."""
    scheme, _, token = request.headers.get("Authorization", "").partition(" ")
    token = token.strip()
    if scheme.lower() != "bearer" or not token:
        raise HTTPException(
            status_code=401,
            detail="expected an Authorization: Bearer token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    try:
        return verify_token(token, settings=settings)
    except AuthError as exc:
        # One answer for every verification failure. Which check failed is for the tests and the
        # operator, not for the caller: the caller learns only that the token is not acceptable.
        raise HTTPException(
            status_code=401,
            detail="token is not acceptable",
            headers={"WWW-Authenticate": 'Bearer error="invalid_token"'},
        ) from exc
    except NotAllowedError as exc:
        # Distinct from 401 on purpose: the token is good, the subject is not on the list.
        raise HTTPException(status_code=403, detail="caller is not on the allowlist") from exc
    except UpstreamError as exc:
        # The keys could not be fetched, so nothing was decided. 503 says "try again", which is the
        # only honest answer; 401 would tell the caller to fix a token that may be perfect.
        raise HTTPException(status_code=503, detail="could not check the token right now") from exc


# The dependency lives on the router, not on each route. A route added here that forgets to name it
# is still behind the boundary; a rule enforced at every call site is a rule that will eventually be
# missing from one, and the failure is a 200 to anyone. `/api/me` names it as well because it needs
# the value, not because the router does not already require it -- FastAPI resolves it once.
protected = APIRouter(prefix="/api", dependencies=[Depends(require_caller)])
api.include_router(protected)


@protected.get("/me")
def me(caller: Annotated[Caller, Depends(require_caller)]) -> dict[str, str | None]:
    return {"sub": caller.sub, "email": caller.email}


class ChatRequest(BaseModel):
    # Capped so one request cannot become an expensive one by accident. The output cap does not
    # bound the input: the provider charges for the prompt too, and a 10 MB body is still valid JSON.
    message: str = Field(min_length=1, max_length=4000)


@protected.post("/chat")
async def chat(
    body: ChatRequest, caller: Annotated[Caller, Depends(require_caller)]
) -> dict[str, str]:
    """One message through the graph. The subject is what makes the spend attributable to a person."""
    retry_after = rate_limiter().check(caller.sub)
    if retry_after is not None:
        # The subject is the key, not the token: a caller minting a second token is the same person
        # spending the same money, and RATE_LIMIT_PER_MINUTE is a budget rather than a token defence.
        raise HTTPException(
            status_code=429,
            detail="too many requests for this subject",
            headers={"Retry-After": str(retry_after)},
        )

    try:
        result = await run_graph(
            [HumanMessage(body.message)],
            {"metadata": configuration.run_metadata(caller.sub, _block)},
        )
    except BudgetExceeded as exc:
        # 504, and it says which bound. A truncated answer returned as 200 is indistinguishable from
        # a finished one, and "did it finish?" is the one thing a caller cannot work around.
        logger.warning("run hit its budget: %s", exc)
        raise HTTPException(status_code=504, detail="the run hit its time budget") from exc
    except StepLimitExceeded as exc:
        logger.warning("run hit its step limit: %s", exc)
        raise HTTPException(status_code=504, detail="the run hit its step limit") from exc
    except NotConfigured as exc:
        # The feature is off, not broken. 503 says "not now", which is true and not the caller's fault.
        raise HTTPException(status_code=503, detail="the model is not configured") from exc
    except ProviderFailed as exc:
        # The reason is logged and the caller gets a sentence with nothing in it. The prompt is not
        # in either: it is the caller's content and it is not ours to keep.
        logger.error("provider call failed: %s", exc)
        raise HTTPException(status_code=502, detail="the model provider failed") from exc

    reply = result["messages"][-1].content
    return {"reply": reply if isinstance(reply, str) else str(reply)}
