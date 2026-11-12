"""A failing test, kept only long enough to be refused.

#58's last acceptance item is that the required check has been *seen* to fail on a test. The one red
in the first seventy-eight `ci` runs was a registry rate limit, not a failing test, so this exists to
produce a red that `pytest` reports — on a pull request that must not be mergeable.
"""


def test_this_fails_on_purpose():
    expected = 2  # not a constant comparison: PLR0133 is a lint failure, and this must be a test one
    assert 1 == expected, "deliberate: this is the red build the gate must refuse"
