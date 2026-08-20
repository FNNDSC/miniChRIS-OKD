"""
Bounded polling of plugin-instance statuses.

Facts only: the poller reports what it saw and why it stopped; deciding what
that means for the test is the scenario's job. Fails fast on any hard-failure
status — a cancelled instance will never finish, so waiting out the budget
would only delay the diagnosis. (docs/troubleshooting.md: pfcon rejects
zero-argument instances and CUBE surfaces that as a silent ``cancelled``.)
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Callable, Protocol

SUCCESS = "finishedSuccessfully"
HARD_FAILURES = frozenset({"finishedWithError", "cancelled"})


class InstanceGetter(Protocol):
    def get_instance(self, instance_id: int) -> dict: ...


@dataclass
class PollOutcome:
    ok: bool
    statuses: dict[int, str]
    seconds: float
    timed_out: bool = False
    failures: dict[int, str] = field(default_factory=dict)

    def describe(self) -> str:
        state = ", ".join(f"instance {i}: {s or '?'}"
                          for i, s in sorted(self.statuses.items()))
        if self.failures:
            return f"hard failure — {state}"
        if self.timed_out:
            return f"timed out after {self.seconds:.0f}s — {state}"
        return state


def poll_instances(client: InstanceGetter, instance_ids: list[int], *,
                   timeout_s: float, interval_s: float,
                   on_change: Callable[[int, dict], None] | None = None,
                   ) -> PollOutcome:
    """``timeout_s`` is a cap: the sleep never extends past it, so the worst
    overshoot is the duration of one final poll round, not a full interval."""
    if not instance_ids:
        raise ValueError("no instances to poll")
    start = time.monotonic()
    statuses: dict[int, str] = {iid: "" for iid in instance_ids}

    while True:
        for iid in instance_ids:
            instance = client.get_instance(iid)
            status = instance.get("status") or ""
            if status != statuses[iid]:
                statuses[iid] = status
                if on_change is not None:
                    on_change(iid, instance)

        elapsed = time.monotonic() - start
        failures = {i: s for i, s in statuses.items() if s in HARD_FAILURES}
        if failures:
            return PollOutcome(False, statuses, elapsed, failures=failures)
        if all(s == SUCCESS for s in statuses.values()):
            return PollOutcome(True, statuses, elapsed)
        if elapsed > timeout_s:
            return PollOutcome(False, statuses, elapsed, timed_out=True)
        time.sleep(min(interval_s, max(0.0, timeout_s - elapsed)))
