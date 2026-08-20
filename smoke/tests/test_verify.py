from chris_smoke.verify import compare, make_payload, sha256_hex


def test_payload_is_stamped_and_checksummed():
    payload = make_payload("20260719-120000")
    assert b"20260719-120000" in payload.content
    assert payload.sha256 == sha256_hex(payload.content)
    assert payload.name == "input.txt"


def test_different_stamps_different_checksums():
    assert make_payload("a").sha256 != make_payload("b").sha256


def test_compare_match_and_mismatch():
    payload = make_payload("stamp")
    assert compare(payload, payload.content) is None

    error = compare(payload, b"tampered")
    assert error is not None
    assert "checksum mismatch" in error
    assert payload.sha256 in error
