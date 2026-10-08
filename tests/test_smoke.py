import swift_glacier


def test_main_runs(capsys):
    swift_glacier.main()
    assert "swift-glacier" in capsys.readouterr().out
