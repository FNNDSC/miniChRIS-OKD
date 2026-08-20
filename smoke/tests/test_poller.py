import time

import pytest

from chris_smoke.poller import poll_instances


class ScriptedInstances:
    def __init__(self, scripts: dict[int, list[str]]):
        self.scripts = scripts

    def get_instance(self, instance_id: int) -> dict:
        script = self.scripts[instance_id]
        status = script.pop(0) if len(script) > 1 else script[0]
        return {"id": instance_id, "status": status, "plugin_name": "pl-x"}


def test_success_and_change_notifications():
    client = ScriptedInstances({
        1: ["created", "started", "finishedSuccessfully"],
        2: ["waiting", "finishedSuccessfully"],
    })
    changes: list[tuple[int, str]] = []
    outcome = poll_instances(client, [1, 2], timeout_s=5, interval_s=0,
                             on_change=lambda i, inst: changes.append((i, inst["status"])))
    assert outcome.ok
    assert outcome.statuses == {1: "finishedSuccessfully", 2: "finishedSuccessfully"}
    assert (1, "created") in changes and (1, "finishedSuccessfully") in changes


def test_hard_failure_stops_immediately():
    client = ScriptedInstances({1: ["started"], 2: ["cancelled"]})
    outcome = poll_instances(client, [1, 2], timeout_s=5, interval_s=0)
    assert not outcome.ok
    assert outcome.failures == {2: "cancelled"}
    assert not outcome.timed_out
    assert "cancelled" in outcome.describe()


def test_timeout_reports_last_statuses():
    client = ScriptedInstances({1: ["started"]})
    outcome = poll_instances(client, [1], timeout_s=0, interval_s=0)
    assert not outcome.ok
    assert outcome.timed_out
    assert outcome.statuses == {1: "started"}
    assert "timed out" in outcome.describe()


def test_timeout_is_a_cap_not_a_lower_bound():
    # a stuck instance with a huge poll interval must not overshoot the
    # budget by that interval — the sleep is capped to the remaining time
    client = ScriptedInstances({1: ["started"]})
    start = time.monotonic()
    outcome = poll_instances(client, [1], timeout_s=0.05, interval_s=60)
    assert outcome.timed_out
    assert time.monotonic() - start < 2.0


def test_empty_instance_list_is_a_caller_bug():
    with pytest.raises(ValueError, match="no instances"):
        poll_instances(ScriptedInstances({}), [], timeout_s=1, interval_s=0)
