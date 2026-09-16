"""Guards for the opt-in whole-route tile cache (feat/cache-whole-route).

The feature is a settings toggle that widens `RouteTileCache`'s fast-start
window to cover the entire route instead of the default 8 km. Three things
can quietly break it, and each gets a guard here:

  1. Adding a field to the persisted blob WITHOUT making it Optional, or
     bumping storeKey unnecessarily — either one wipes every existing
     rider's settings on upgrade.
  2. Wiring the toggle to the sibling zoom layers as well, which would
     multiply the bake cost for tiles only ever shown near the rider.
  3. Letting the default flip to ON, which would make every first ride pay
     a multi-minute bake.
"""

from pathlib import Path

import pytest

from tests.swift_source import decl_body, strip_comments

REPO = Path(__file__).resolve().parents[3]
SETTINGS = REPO / "TripperDashPP/Navigation/Models/DashNavSettings.swift"
PICKER = REPO / "TripperDashPP/UI/MapPickerView.swift"
STREAMING = REPO / "TripperDashPP/UI/StreamingView.swift"
CACHE = REPO / "TripperDashPP/Map/RouteTileCache.swift"


@pytest.fixture(scope="module")
def settings_src():
    return SETTINGS.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def picker_src():
    return PICKER.read_text(encoding="utf-8")


def test_toggle_defaults_off(settings_src):
    """A whole-route bake is minutes of waiting; it must be opt-in."""
    body = strip_comments(settings_src)
    assert "var cacheWholeRouteEnabled: Bool = false" in body, (
        "cacheWholeRouteEnabled must default to false — defaulting it ON "
        "makes every rider pay a full-route bake before their first ride"
    )


def test_persisted_field_is_optional(settings_src):
    """Non-optional new fields fail to decode older blobs, wiping settings."""
    body = strip_comments(settings_src)
    struct = decl_body(body, "private struct Persisted: Codable")
    assert struct is not None, "Persisted struct not found"
    assert "var cacheWholeRouteEnabled: Bool?" in struct, (
        "the persisted field must be Optional so an existing v11 blob "
        "(which lacks the key) still decodes instead of resetting everything"
    )


def test_store_key_not_bumped_for_an_optional_addition(settings_src):
    """Bumping the key for a backwards-compatible addition wipes settings."""
    body = strip_comments(settings_src)
    assert 'storeKey = "dashNavSettings.v11"' in body, (
        "storeKey should stay at v11: the new field is Optional with a "
        "default, so old blobs decode fine. Bumping it would silently "
        "discard every rider's existing preferences for no benefit"
    )


def test_load_defaults_the_new_field_off(settings_src):
    body = strip_comments(settings_src)
    load = decl_body(body, "private func load()")
    assert load is not None, "load() not found"
    assert "p.cacheWholeRouteEnabled ?? false" in load, (
        "load() must default the new field to false for older blobs"
    )


def test_persist_round_trips_the_new_field(settings_src):
    """A field that is loaded but never written back resets on next launch."""
    body = strip_comments(settings_src)
    persist = decl_body(body, "private func persist()")
    assert persist is not None, "persist() not found"
    assert "cacheWholeRouteEnabled: cacheWholeRouteEnabled" in persist, (
        "persist() must write the new field, or the toggle silently "
        "reverts every time the app restarts"
    )


def test_prerender_honours_the_setting(picker_src):
    body = strip_comments(picker_src)
    fn = decl_body(body, "private func prerenderRouteTiles(")
    assert fn is not None, "prerenderRouteTiles not found"
    assert "cacheWholeRouteEnabled" in fn, (
        "the corridor bake must read the setting, or the toggle does nothing"
    )
    assert "bakeAheadMeters" in fn, (
        "the setting must drive bakeAheadMeters — that is the existing "
        "init parameter the whole feature rides on"
    )
    assert "route.distance" in fn, (
        "the widened window must be derived from the route length, not a "
        "guessed constant that silently truncates long routes"
    )


def test_sibling_zoom_layers_keep_their_short_windows():
    """Coarse/fine layers cover the rider's surroundings, not the route."""
    body = strip_comments((REPO / "TripperDashPP/Map/MapViewSource.swift").read_text(encoding="utf-8"))
    fn = decl_body(body, "private func buildQualityLayers(")
    assert fn is not None, "buildQualityLayers not found"
    assert "cacheWholeRouteEnabled" not in fn, (
        "the sibling zoom layers must NOT honour the whole-route toggle: "
        "they exist to cover the rider's immediate surroundings at another "
        "zoom band, so baking them route-wide multiplies cost for tiles "
        "that are only ever drawn near the rider"
    )


def test_bake_ahead_is_still_an_init_parameter():
    """The feature rides on this parameter; losing it breaks the toggle."""
    body = strip_comments(CACHE.read_text(encoding="utf-8"))
    assert "let bakeAheadMeters: CLLocationDistance" in body
    assert "bakeAheadMeters: CLLocationDistance = RouteTileCache.initialBakeAheadMeters" in body, (
        "bakeAheadMeters must stay an init parameter with the 8 km default"
    )


def test_settings_ui_explains_the_cost():
    """An unexplained toggle that can burn minutes and MB is a trap."""
    body = STREAMING.read_text(encoding="utf-8")
    assert "cacheWholeRouteEnabled" in body, "no toggle wired into Settings"
    # Scope to the toggle's OWN caption. Searching the whole file matches
    # "data" / "Wi-Fi" from unrelated sections and passes even when this
    # description has been gutted (caught by mutation).
    caption_start = body.index('Text("', body.index('Text("Cache the whole route")') + 1)
    caption_end = body.index('")', caption_start)
    caption = body[caption_start:caption_end]
    assert len(caption) > 120, (
        "the whole-route toggle needs a real explanation, not a one-liner"
    )
    for warning in ("data", "8 km"):
        assert warning in caption, (
            f"the toggle's caption must mention {warning!r} — a rider "
            f"enabling this needs to know what it costs and what the "
            f"default behaviour already is. Caption was: {caption!r}"
        )
    assert "minutes" in caption or "Wi-Fi" in caption, (
        f"the caption must warn about the time cost. Caption was: {caption!r}"
    )
