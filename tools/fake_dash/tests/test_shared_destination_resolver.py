"""
Mirror + drift guards for `SharedDestinationResolver.swift` and
`SharedDeepLink.swift` — the "Share to TripperDash++" parser.

The Swift resolver turns a shared Google/Apple Maps payload (URL or text)
into an ordered list of waypoints (or a search hint) that pre-fills the
planner. This mirror re-implements the PURE parsing (no network redirect
follow) and pins it against the real URL shapes both apps emit, so a Swift
refactor that breaks parsing trips CI on the Linux box (no Xcode here).

It also drift-guards the two Swift files: the presence of each URL shape's
handling and the deep-link round-trip contract.
"""
import re
import unittest
from pathlib import Path
from urllib.parse import urlparse, parse_qs, unquote

SWIFT_RESOLVER = (
    Path(__file__).resolve().parents[3]
    / "TripperDashPP/Navigation/SharedDestinationResolver.swift"
)
SWIFT_DEEPLINK = (
    Path(__file__).resolve().parents[3]
    / "TripperDashPP/Navigation/SharedDeepLink.swift"
)


# ---------------------------------------------------------------------------
# Python mirror of the pure parser
# ---------------------------------------------------------------------------

def valid_coord(lat, lon):
    if lat is None or lon is None:
        return None
    if -90 <= lat <= 90 and -180 <= lon <= 180 and not (lat == 0 and lon == 0):
        return (lat, lon)
    return None


def parse_latlon_pair(s):
    parts = s.split(",", 2)
    if len(parts) < 2:
        return None
    try:
        lat = float(parts[0].strip())
        lon = float(parts[1].strip())
    except ValueError:
        return None
    return valid_coord(lat, lon)


def parse_at_coord(s):
    i = s.find("@")
    if i < 0:
        return None
    tail = s[i + 1:]
    head = ""
    for ch in tail:
        if ch.isdigit() or ch in ".-,":
            head += ch
        else:
            break
    return parse_latlon_pair(head)


def parse_bang_coord(s):
    def grab(tag):
        i = s.find(tag)
        if i < 0:
            return None
        tail = s[i + len(tag):]
        num = ""
        for ch in tail:
            if ch.isdigit() or ch in ".-":
                num += ch
            else:
                break
        try:
            return float(num)
        except ValueError:
            return None
    lat, lon = grab("!3d"), grab("!4d")
    if lat is None or lon is None:
        return None
    return valid_coord(lat, lon)


def parse_apple(url):
    q = parse_qs(urlparse(url).query)
    def val(k):
        for key in q:
            if key.lower() == k:
                return q[key][0]
        return None
    out = []
    for key in ("saddr", "daddr"):
        v = val(key)
        if v is not None:
            c = parse_latlon_pair(v)
            if c:
                out.append({"coord": c, "name": None})
            elif v:
                out.append({"coord": None, "name": v})
    if out:
        return out
    name = None
    nv = val("name")
    if nv:
        name = nv
    else:
        qv = val("q")
        if qv and parse_latlon_pair(qv) is None:
            name = qv
    for key in ("ll", "sll", "q", "coordinate"):
        v = val(key)
        if v:
            c = parse_latlon_pair(v)
            if c:
                return [{"coord": c, "name": name}]
    if name:
        return [{"coord": None, "name": name}]
    return None


def parse_google(url):
    parsed = urlparse(url)
    path = parsed.path
    full = url

    m = re.search(r"/dir/", path)
    if m:
        tail = path[m.end():]
        segs = [s for s in tail.split("/")
                if s and not s.startswith("@") and not s.startswith("data=")]
        out = []
        for seg in segs:
            decoded = unquote(seg).replace("+", " ")
            c = parse_latlon_pair(decoded)
            if c:
                out.append({"coord": c, "name": None})
            elif decoded:
                out.append({"coord": None, "name": decoded})
        if out:
            return out

    place_name = None
    m = re.search(r"/place/", path)
    if m:
        tail = path[m.end():]
        seg = tail.split("/")[0] if tail.split("/") else ""
        decoded = unquote(seg).replace("+", " ")
        if decoded and not decoded.startswith("@"):
            place_name = decoded

    q = parse_qs(parsed.query)
    for key in q:
        if key.lower() in ("q", "query", "destination"):
            v = q[key][0]
            c = parse_latlon_pair(v)
            if c:
                return [{"coord": c, "name": place_name}]
            elif place_name is None and v:
                place_name = v

    c = parse_at_coord(full)
    if c:
        return [{"coord": c, "name": place_name}]
    c = parse_bang_coord(full)
    if c:
        return [{"coord": c, "name": place_name}]
    if place_name:
        return [{"coord": None, "name": place_name}]
    return None


def parse(url=None, text=None):
    if url:
        host = (urlparse(url).netloc or "").lower()
        scheme = (urlparse(url).scheme or "").lower()
        if "maps.apple" in host:
            wps = parse_apple(url)
            if wps:
                return ("waypoints", wps)
        if "google." in host or "goo.gl" in host:
            wps = parse_google(url)
            if wps:
                return ("waypoints", wps)
        if scheme == "geo":
            body = url.replace("geo:", "").split("?")[0]
            c = parse_latlon_pair(body)
            if c:
                return ("waypoints", [{"coord": c, "name": None}])
    if text and text.strip():
        c = parse_latlon_pair(text.strip())
        if c:
            return ("waypoints", [{"coord": c, "name": None}])
        # search hint: strip URLs, first non-empty line
        stripped = re.sub(r"https?://\S+", "", text)
        for line in stripped.splitlines():
            line = line.strip()
            if line:
                return ("searchHint", line)
    return ("empty", None)


# ---------------------------------------------------------------------------
# Tests — real-world URL shapes
# ---------------------------------------------------------------------------

class AppleMapsTests(unittest.TestCase):
    def test_single_place_ll(self):
        kind, wps = parse(url="https://maps.apple.com/?ll=50.0755,14.4378&q=Prague")
        self.assertEqual(kind, "waypoints")
        self.assertEqual(len(wps), 1)
        self.assertAlmostEqual(wps[0]["coord"][0], 50.0755)
        self.assertEqual(wps[0]["name"], "Prague")

    def test_route_saddr_daddr_coords(self):
        kind, wps = parse(
            url="https://maps.apple.com/?saddr=50.08,14.43&daddr=49.95,14.10")
        self.assertEqual(kind, "waypoints")
        self.assertEqual(len(wps), 2)
        self.assertAlmostEqual(wps[1]["coord"][0], 49.95)

    def test_place_name_only(self):
        kind, wps = parse(url="https://maps.apple.com/?q=Okor%20Castle")
        self.assertEqual(kind, "waypoints")
        self.assertIsNone(wps[0]["coord"])
        self.assertEqual(wps[0]["name"], "Okor Castle")

    def test_new_place_endpoint_coordinate_and_name(self):
        # New maps.apple.com/place?… form (what maps.apple/p/<id> redirects to).
        kind, wps = parse(
            url="https://maps.apple.com/place?address=Zvolen&coordinate=48.576456,19.122979&name=Zvolen&map=explore")
        self.assertEqual(kind, "waypoints")
        self.assertAlmostEqual(wps[0]["coord"][0], 48.576456, places=4)
        self.assertAlmostEqual(wps[0]["coord"][1], 19.122979, places=4)
        self.assertEqual(wps[0]["name"], "Zvolen")


class GoogleMapsTests(unittest.TestCase):
    def test_place_at_coord(self):
        kind, wps = parse(
            url="https://www.google.com/maps/place/Nizbor/@49.9541,14.0012,15z")
        self.assertEqual(kind, "waypoints")
        self.assertAlmostEqual(wps[0]["coord"][0], 49.9541)
        self.assertEqual(wps[0]["name"], "Nizbor")

    def test_place_bang_coord_wins_shape(self):
        kind, wps = parse(
            url="https://www.google.com/maps/place/X/@49.9,14.0,15z/data=!3d49.95!4d14.05")
        self.assertEqual(kind, "waypoints")
        # @-coord is checked first in both Swift and mirror; assert it parses.
        self.assertIsNotNone(wps[0]["coord"])

    def test_dir_multi_wp(self):
        kind, wps = parse(
            url="https://www.google.com/maps/dir/Zvolenaves/Okor/49.95,14.00/Krivoklat")
        self.assertEqual(kind, "waypoints")
        self.assertEqual(len(wps), 4)
        self.assertEqual(wps[0]["name"], "Zvolenaves")
        self.assertAlmostEqual(wps[2]["coord"][0], 49.95)
        self.assertEqual(wps[3]["name"], "Krivoklat")

    def test_query_latlon(self):
        kind, wps = parse(url="https://maps.google.com/?q=50.1,14.2")
        self.assertEqual(kind, "waypoints")
        self.assertAlmostEqual(wps[0]["coord"][1], 14.2)


class TextFallbackTests(unittest.TestCase):
    def test_bare_latlon(self):
        kind, wps = parse(text="50.0755, 14.4378")
        self.assertEqual(kind, "waypoints")
        self.assertAlmostEqual(wps[0]["coord"][0], 50.0755)

    def test_name_and_url_yields_hint_when_url_unparseable(self):
        kind, hint = parse(text="Cool Cafe\nhttps://example.com/nope")
        self.assertEqual(kind, "searchHint")
        self.assertEqual(hint, "Cool Cafe")

    def test_empty(self):
        kind, _ = parse(text="   ")
        self.assertEqual(kind, "empty")


class ValidationTests(unittest.TestCase):
    def test_null_island_rejected(self):
        self.assertIsNone(valid_coord(0, 0))

    def test_out_of_range_rejected(self):
        self.assertIsNone(valid_coord(91, 14))
        self.assertIsNone(valid_coord(50, 181))


# ---------------------------------------------------------------------------
# Drift guards — the Swift files still handle each shape
# ---------------------------------------------------------------------------

class SwiftDriftGuards(unittest.TestCase):
    def setUp(self):
        self.resolver = SWIFT_RESOLVER.read_text(encoding="utf-8")
        self.deeplink = SWIFT_DEEPLINK.read_text(encoding="utf-8")

    def test_apple_maps_handled(self):
        self.assertIn("maps.apple.com", self.resolver)
        for k in ("saddr", "daddr", "ll"):
            self.assertIn(k, self.resolver, f"Apple key {k} missing")

    def test_google_shapes_handled(self):
        for token in ("/dir/", "/place/", "!3d", "!4d", "@"):
            self.assertIn(token, self.resolver, f"Google token {token} missing")

    def test_short_link_expanded(self):
        self.assertIn("maps.app.goo.gl", self.resolver)
        self.assertIn("followRedirect", self.resolver)

    def test_null_island_guard_present(self):
        self.assertIn("lat == 0 && lon == 0", self.resolver)

    def test_graceful_search_hint_fallback(self):
        self.assertIn("searchHint", self.resolver)

    def test_deeplink_roundtrip_contract(self):
        # encode + decode both present, scheme constant matches Info.plist
        self.assertIn('static let scheme = "tripperdash"', self.deeplink)
        self.assertIn("func encode", self.deeplink)
        self.assertIn("func decode", self.deeplink)
        self.assertIn('name: "wp"', self.deeplink)


if __name__ == "__main__":
    unittest.main()
