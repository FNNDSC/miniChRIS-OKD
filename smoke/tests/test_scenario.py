from chris_smoke import scenario


def run(steps, fake_cube, cfg, state, reporter):
    return scenario.run_steps(steps, fake_cube, cfg, state, reporter,
                              reporter.step)


def test_full_journey_passes(fake_cube, cfg, reporter):
    state = scenario.new_state(cfg.username)

    ok, results = run(scenario.PREFLIGHT, fake_cube, cfg, state, reporter)
    assert ok, [r.detail for r in results]
    assert fake_cube.connected
    assert set(state.plugins) == {scenario.FS_PLUGIN, scenario.DS_PLUGIN}

    ok, results = run(scenario.JOURNEY, fake_cube, cfg, state, reporter)
    assert ok, [r.detail for r in results]
    assert state.feed_id == 7
    assert state.upload_path in fake_cube.uploaded
    assert state.downloaded == state.payload.content

    ok, results = run(scenario.CLEANUP, fake_cube, cfg, state, reporter)
    assert ok
    assert fake_cube.deleted_feeds == [7]
    assert fake_cube.deleted_files == [100]
    assert fake_cube.deleted_folders == [state.upload_dir]


def test_upload_path_is_under_user_home(cfg):
    state = scenario.new_state("smoke")
    assert state.upload_path.startswith("home/smoke/uploads/smoke-")
    assert state.upload_path.endswith("/" + state.payload.name)


def test_missing_plugin_fails_preflight(fake_cube, cfg, reporter):
    del fake_cube.plugins[scenario.DS_PLUGIN]
    state = scenario.new_state(cfg.username)

    ok, results = run(scenario.PREFLIGHT, fake_cube, cfg, state, reporter)
    assert not ok
    assert results[-1].name == "smoke plugins registered"
    assert "chris-seed" in results[-1].detail


def test_cancelled_instance_fails_wait_step(fake_cube, cfg, reporter):
    # ds instance (created second → id 2) is cancelled, e.g. the pfcon
    # zero-argument quirk; fs succeeds
    fake_cube.status_script[2] = ["started", "cancelled"]
    state = scenario.new_state(cfg.username)

    run(scenario.PREFLIGHT, fake_cube, cfg, state, reporter)
    ok, results = run(scenario.JOURNEY, fake_cube, cfg, state, reporter)
    assert not ok
    assert results[-1].name == "wait for completion"
    assert "cancelled" in results[-1].detail
    assert fake_cube.deleted_feeds == []  # evidence kept


def test_corrupt_output_fails_verify_step(fake_cube, cfg, reporter):
    fake_cube.corrupt_output = True
    state = scenario.new_state(cfg.username)

    run(scenario.PREFLIGHT, fake_cube, cfg, state, reporter)
    ok, results = run(scenario.JOURNEY, fake_cube, cfg, state, reporter)
    assert not ok
    assert results[-1].name == "verify output checksum"
    assert "checksum mismatch" in results[-1].detail
