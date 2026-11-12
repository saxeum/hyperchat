"""A failing test, kept only long enough to be refused.

#58's last acceptance item is that the required check has been *seen* to fail. Seven of the
seventy-eight `ci` runs are red for reasons unrelated to a test — a registry rate limit — so this
exist to produce a red that is a test failing, on a pull request that must not be mergeable.
"""


def test_this_fails_on_purpose():
    assert 1 == 2, "deliberate: this is the red build the gate must refuse"
