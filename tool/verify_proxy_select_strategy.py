#!/usr/bin/env python3
"""Aggressive offline verification of country-priority connection strategy.

Mirrors ProxySelectAlgorithm + ProxyCountries and runs stress / property checks.
"""

from __future__ import annotations

import random
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COUNTRIES_FILE = ROOT / "lib/features/proxy/model/proxy_countries.dart"
ALGO_FILE = ROOT / "lib/features/proxy/model/proxy_select_strategy.dart"
NOTIFIER_FILE = ROOT / "lib/features/proxy/notifier/proxy_select_strategy_notifier.dart"
PAGE_FILE = ROOT / "lib/features/proxy/overview/proxy_select_strategy_page.dart"
PREF_FILE = ROOT / "lib/core/preferences/general_preferences.dart"
ROUTER_FILE = ROOT / "lib/core/router/go_router/routing_config_notifier.dart"
APP_FILE = ROOT / "lib/features/app/widget/app.dart"
PROXIES_PAGE = ROOT / "lib/features/proxy/overview/proxies_overview_page.dart"

TIMEOUT = 65000
failures: list[str] = []
passed = 0


def ok(name: str) -> None:
    global passed
    passed += 1
    print(f"  PASS  {name}")


def fail(name: str, msg: str) -> None:
    failures.append(f"{name}: {msg}")
    print(f"  FAIL  {name}: {msg}")


def expect_eq(name: str, got, expected) -> None:
    if got == expected:
        ok(name)
    else:
        fail(name, f"expected {expected!r}, got {got!r}")


def expect_true(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        ok(name)
    else:
        fail(name, detail or "expected True")


def load_codes() -> set[str]:
    text = COUNTRIES_FILE.read_text(encoding="utf-8")
    codes = re.findall(r"ProxyCountry\('([A-Z]{2})'", text)
    if len(codes) != len(set(codes)):
        raise SystemExit("duplicate country codes")
    if len(codes) < 240:
        raise SystemExit(f"expected >=240 countries, got {len(codes)}")
    return set(codes)


CODES = load_codes()


@dataclass
class Proxy:
    tag: str
    delay: int = 100
    country: str | None = None
    tag_display: str | None = None
    is_group: bool = False

    @property
    def display(self) -> str:
        return self.tag_display or self.tag


def flag_to_country(text: str) -> str | None:
    runes = [ord(c) for c in text]
    for i in range(len(runes) - 1):
        a, b = runes[i], runes[i + 1]
        if 0x1F1E6 <= a <= 0x1F1FF and 0x1F1E6 <= b <= 0x1F1FF:
            return chr(a - 0x1F1E6 + 0x41) + chr(b - 0x1F1E6 + 0x41)
    return None


def parse_country(text: str) -> str | None:
    if not text:
        return None
    flag = flag_to_country(text)
    if flag:
        return "GB" if flag == "UK" else flag
    upper = text.upper()
    m = re.search(r"[\[\(\{]([A-Z]{2})[\]\)\}]", upper)
    if m and (m.group(1) in CODES or m.group(1) == "UK"):
        return "GB" if m.group(1) == "UK" else m.group(1)
    best = None
    best_code = None
    for code in list(CODES) + ["UK"]:
        mm = re.search(rf"(?:^|[^A-Z])({code})(?:[^A-Z]|$)", upper)
        if not mm:
            continue
        if best is None or mm.start() < best:
            best = mm.start()
            best_code = code
    if best_code:
        return "GB" if best_code == "UK" else best_code
    return None


def resolve(p: Proxy) -> str | None:
    if p.country:
        c = p.country.strip().upper()
        return "GB" if c == "UK" else c
    parsed = parse_country(f"{p.tag} {p.display}")
    return "GB" if parsed == "UK" else parsed


def is_alive(p: Proxy) -> bool:
    return (not p.is_group) and 0 < p.delay < TIMEOUT


def lowest(items: list[Proxy]) -> Proxy:
    return min(items, key=lambda x: x.delay)


def pick(
    items: list[Proxy],
    countries: list[str],
    fallback: str,
    mode: str = "countryPriority",
) -> Proxy | None:
    if mode == "manual":
        return None
    all_items = [i for i in items if not i.is_group]
    if not all_items:
        return None
    alive = [i for i in all_items if is_alive(i)]
    countries = [c.upper() for c in countries if c]
    if not countries:
        return lowest(alive) if fallback == "any" and alive else None
    for country in countries:
        tier = [i for i in alive if resolve(i) == country]
        if tier:
            return lowest(tier)
    if fallback == "any":
        return lowest(alive) if alive else None
    for country in countries:
        tier = [i for i in all_items if resolve(i) == country]
        if not tier:
            continue
        with_delay = [i for i in tier if 0 < i.delay <= TIMEOUT]
        return lowest(with_delay) if with_delay else tier[0]
    return None


def is_allowed(p: Proxy, countries: list[str], fallback: str, mode: str = "countryPriority") -> bool:
    if mode == "manual" or fallback == "any":
        return True
    countries_set = {c.upper() for c in countries if c}
    if not countries_set:
        return True
    code = resolve(p)
    if code is None:
        return True
    return code in countries_set


def simulate_controller(
    items: list[Proxy],
    selected_tag: str,
    countries: list[str],
    fallback: str,
) -> str:
    """What the controller would select next under exclusive enforcement."""
    selected = next((i for i in items if i.tag == selected_tag), None)
    force = selected is not None and not is_allowed(selected, countries, fallback)
    best = pick(items, countries, fallback)
    if best is None:
        return selected_tag
    if not force and best.tag == selected_tag:
        return selected_tag
    return best.tag


def section(title: str) -> None:
    print(f"\n== {title} ==")


def test_repo_wiring() -> None:
    section("Repo wiring integrity")
    checks = {
        "algo file": ALGO_FILE.exists(),
        "countries file": COUNTRIES_FILE.exists(),
        "notifier file": NOTIFIER_FILE.exists(),
        "page file": PAGE_FILE.exists(),
        "prefs mode": "proxySelectMode" in PREF_FILE.read_text(encoding="utf-8"),
        "prefs countries": "proxySelectCountries" in PREF_FILE.read_text(encoding="utf-8"),
        "prefs fallback": "proxySelectFallback" in PREF_FILE.read_text(encoding="utf-8"),
        "router route": "proxySelectStrategy" in ROUTER_FILE.read_text(encoding="utf-8"),
        "app listen": "proxySelectStrategyControllerProvider" in APP_FILE.read_text(encoding="utf-8"),
        "proxies entry": "proxySelectStrategy" in PROXIES_PAGE.read_text(encoding="utf-8"),
        "leftmost parse": "Leftmost ISO match" in ALGO_FILE.read_text(encoding="utf-8"),
        "unknown allowed": "Unknown country" in ALGO_FILE.read_text(encoding="utf-8"),
    }
    for name, cond in checks.items():
        expect_true(name, cond)


def test_countries_dataset() -> None:
    section("Countries dataset")
    text = COUNTRIES_FILE.read_text(encoding="utf-8")
    expect_eq("unique count", len(CODES), len(re.findall(r"ProxyCountry\('([A-Z]{2})'", text)))
    for must in ["US", "DE", "TR", "GB", "IR", "CN", "JP", "NL", "AE", "XK"]:
        expect_true(f"has {must}", must in CODES)
    # popular order
    popular = re.search(r"popularCodes = \[(.*?)\];", text, re.S)
    expect_true("popularCodes present", popular is not None)
    if popular:
        first = re.findall(r"'([A-Z]{2})'", popular.group(1))[:3]
        expect_eq("popular starts US,DE,TR", first, ["US", "DE", "TR"])


def test_parsing() -> None:
    section("Country parsing")
    cases = [
        ("[US] Node", "US"),
        ("(DE)", "DE"),
        ("{TR}", "TR"),
        ("TR-Istanbul-1", "TR"),
        ("UK-London", "GB"),
        ("🇺🇸 Premium", "US"),
        ("🇩🇪-Hetzner", "DE"),
        ("DE-US-relay", "DE"),
        ("US-DE-relay", "US"),
        ("Premium-Node-01", None),
        ("", None),
        ("sg-01", "SG"),
        ("Node [jp]", "JP"),
    ]
    for text, expected in cases:
        expect_eq(f"parse {text!r}", parse_country(text), expected)

    # ipinfo wins over tag
    p = Proxy("DE-1", country="US")
    expect_eq("ipinfo over tag", resolve(p), "US")
    p2 = Proxy("x", country="uk")
    expect_eq("uk normalize", resolve(p2), "GB")


def test_user_scenarios() -> None:
    section("User scenarios")
    us_fast = Proxy("us-fast", delay=80, country="US")
    us_slow = Proxy("us-slow", delay=400, country="US")
    tr_fast = Proxy("tr-fast", delay=40, country="TR")
    de_fast = Proxy("de-fast", delay=50, country="DE")
    de_slow = Proxy("de-slow", delay=300, country="DE")
    group = Proxy("select", delay=1, is_group=True)

    p = pick([group, tr_fast, us_slow, us_fast, de_fast], ["US", "TR", "DE"], "none")
    expect_eq("1 US>TR>DE prefers US lowest", p.tag if p else None, "us-fast")

    p = pick([Proxy("us-dead", 0, "US"), tr_fast, de_fast], ["US", "TR", "DE"], "none")
    expect_eq("1b fall to TR", p.tag if p else None, "tr-fast")

    p = pick([Proxy("us-dead", 0, "US"), Proxy("tr-dead", 70000, "TR"), de_fast], ["US", "TR", "DE"], "none")
    expect_eq("1c fall to DE", p.tag if p else None, "de-fast")

    p = pick([de_fast, us_slow, us_fast], ["US"], "none")
    expect_eq("2 US only", p.tag if p else None, "us-fast")
    expect_true("2 DE disallowed", not is_allowed(de_fast, ["US"], "none"))

    # critical: exclusive must not jump to DE later
    next_tag = simulate_controller([de_fast, us_fast], "us-fast", ["US"], "none")
    expect_eq("2 sticky US stays US", next_tag, "us-fast")
    next_tag = simulate_controller([de_fast, us_fast], "de-fast", ["US"], "none")
    expect_eq("2 if drifted to DE, force back to US", next_tag, "us-fast")

    p = pick([de_fast, Proxy("us-untested", 0, "US")], ["US"], "none")
    expect_eq("2b exclusive keeps US untested", p.tag if p else None, "us-untested")

    p = pick([us_fast, de_slow, de_fast], ["DE"], "any")
    expect_eq("3 DE preferred", p.tag if p else None, "de-fast")

    p = pick([us_fast, tr_fast, Proxy("de-dead", 70000, "DE")], ["DE"], "any")
    expect_eq("3b fallback any -> lowest global", p.tag if p else None, "tr-fast")

    p = pick([us_fast, de_fast], ["US"], "none", mode="manual")
    expect_eq("manual null", p, None)


def test_edge_cases() -> None:
    section("Edge cases")
    expect_true("unknown allowed exclusive", is_allowed(Proxy("Premium-01"), ["US"], "none"))
    expect_true("fallback any allows DE", is_allowed(Proxy("de", country="DE"), ["US"], "any"))
    expect_eq("empty items", pick([], ["US"], "none"), None)
    expect_eq(
        "empty countries exclusive",
        pick([Proxy("us", 10, "US")], [], "none"),
        None,
    )
    p = pick([Proxy("a", 30, "DE"), Proxy("b", 10, "US")], [], "any")
    expect_eq("empty countries + any", p.tag if p else None, "b")
    p = pick([Proxy("us", 20, "US")], ["us"], "none")
    expect_eq("lowercase normalize", p.tag if p else None, "us")

    # timeout boundary
    expect_true("alive at 64999", is_alive(Proxy("a", delay=64999, country="US")))
    expect_true("dead at 65000", not is_alive(Proxy("a", delay=65000, country="US")))
    expect_true("dead at 65001", not is_alive(Proxy("a", delay=65001, country="US")))
    expect_true("dead at 0", not is_alive(Proxy("a", delay=0, country="US")))
    expect_true("group never alive", not is_alive(Proxy("g", delay=1, is_group=True, country="US")))

    # ignore groups as candidates
    p = pick(
        [Proxy("select", 1, "US", is_group=True), Proxy("real-us", 90, "US")],
        ["US"],
        "none",
    )
    expect_eq("ignore group candidate", p.tag if p else None, "real-us")

    # tag-only resolution when no ipinfo
    p = pick(
        [Proxy("🇩🇪-fast", 70), Proxy("🇺🇸-slow", 200), Proxy("TR-node", 40)],
        ["US", "TR"],
        "none",
    )
    expect_eq("flag/tag based US first", p.tag if p else None, "🇺🇸-slow")


def test_stress_random() -> None:
    section("Stress / property checks")
    rng = random.Random(42)
    countries_pool = ["US", "DE", "TR", "GB", "NL", "FR", "JP", "SG", "CA", "AU"]

    # Property: with exclusive fallback, never pick outside priority list when any in-list exists
    for i in range(300):
        priority = rng.sample(countries_pool, k=rng.randint(1, 4))
        items = []
        for j in range(rng.randint(5, 25)):
            c = rng.choice(countries_pool)
            delay = rng.choice([0, 40, 80, 120, 300, 70000, rng.randint(1, 500)])
            items.append(Proxy(f"n{j}-{c}", delay=delay, country=c))
        # ensure at least one in-list proxy exists
        items.append(Proxy("anchor", delay=999, country=priority[0]))
        chosen = pick(items, priority, "none")
        if chosen is None:
            fail(f"stress exclusive #{i}", "picked None despite in-list anchor")
            return
        code = resolve(chosen)
        if code not in priority:
            fail(f"stress exclusive #{i}", f"picked {chosen.tag} country={code} outside {priority}")
            return
    ok("300 exclusive never-outside-list")

    # Property: within first alive tier, always lowest ping
    for i in range(200):
        priority = ["US", "TR", "DE"]
        us_delays = [rng.randint(10, 500) for _ in range(rng.randint(2, 6))]
        items = [Proxy(f"us{j}", d, "US") for j, d in enumerate(us_delays)]
        items += [Proxy("tr", 1, "TR"), Proxy("de", 1, "DE")]
        chosen = pick(items, priority, "none")
        expect_true(
            f"tier-min #{i}",
            chosen is not None and chosen.delay == min(us_delays),
            f"got {chosen}",
        )
        if chosen is None or chosen.delay != min(us_delays):
            return
    ok("200 first-tier lowest-ping")

    # Property: deterministic
    items = [
        Proxy("tr-fast", 40, "TR"),
        Proxy("us-slow", 400, "US"),
        Proxy("us-fast", 80, "US"),
        Proxy("de-fast", 50, "DE"),
    ]
    tags = {pick(items, ["US", "TR", "DE"], "none").tag for _ in range(50)}  # type: ignore
    expect_eq("deterministic", tags, {"us-fast"})

    # Property: preferred-then-any never picks preferred-dead over global best when preferred all dead
    for i in range(100):
        items = [
            Proxy("de-dead", 0, "DE"),
            Proxy("de-to", 70000, "DE"),
            Proxy("us", rng.randint(20, 100), "US"),
            Proxy("tr", rng.randint(20, 100), "TR"),
        ]
        chosen = pick(items, ["DE"], "any")
        alive = [x for x in items if is_alive(x)]
        expect_eq(f"any-fallback #{i}", chosen.tag if chosen else None, lowest(alive).tag)


def test_controller_invariants() -> None:
    section("Controller invariants")
    us = Proxy("us", 100, "US")
    de = Proxy("de", 50, "DE")
    tr = Proxy("tr", 40, "TR")

    # After exclusive US, if urltest flips selection to DE, controller must correct
    expect_eq(
        "correct DE drift",
        simulate_controller([us, de, tr], "de", ["US"], "none"),
        "us",
    )
    # If already correct, stay
    expect_eq(
        "keep correct US",
        simulate_controller([us, de, tr], "us", ["US"], "none"),
        "us",
    )
    # US->TR exclusive: currently TR with US alive -> should move to US
    expect_eq(
        "move TR up to US when US alive",
        simulate_controller([us, de, tr], "tr", ["US", "TR"], "none"),
        "us",
    )
    # US dead, on TR, exclusive US->TR -> stay TR (or pick TR)
    us_dead = Proxy("us", 0, "US")
    expect_eq(
        "stay TR when US dead",
        simulate_controller([us_dead, de, tr], "tr", ["US", "TR"], "none"),
        "tr",
    )
    # Preferred DE then any: on US while DE alive -> should move to DE
    expect_eq(
        "prefer DE over US when DE alive",
        simulate_controller([us, de, tr], "us", ["DE"], "any"),
        "de",
    )


def main() -> int:
    print(f"Loaded {len(CODES)} country codes from {COUNTRIES_FILE.name}")
    test_repo_wiring()
    test_countries_dataset()
    test_parsing()
    test_user_scenarios()
    test_edge_cases()
    test_stress_random()
    test_controller_invariants()

    print("\n== Result ==")
    print(f"passed={passed} failed={len(failures)}")
    if failures:
        for f in failures:
            print(" -", f)
        return 1
    print("ALL PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
