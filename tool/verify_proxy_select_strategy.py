#!/usr/bin/env python3
"""Mirror of ProxySelectAlgorithm for offline verification without Flutter SDK."""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COUNTRIES_FILE = ROOT / "lib/features/proxy/model/proxy_countries.dart"

TIMEOUT = 65000
failures: list[str] = []


def ok(name: str) -> None:
    print(f"  PASS  {name}")


def fail(name: str, msg: str) -> None:
    failures.append(f"{name}: {msg}")
    print(f"  FAIL  {name}: {msg}")


def load_codes() -> set[str]:
    text = COUNTRIES_FILE.read_text(encoding="utf-8")
    codes = set(re.findall(r"ProxyCountry\('([A-Z]{2})'", text))
    if len(codes) < 240:
        raise SystemExit(f"expected >=240 countries, got {len(codes)}")
    if len(codes) != len(re.findall(r"ProxyCountry\('([A-Z]{2})'", text)):
        raise SystemExit("duplicate country codes in proxy_countries.dart")
    return codes


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
    return (not p.is_group) and 0 < p.delay <= TIMEOUT


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


def expect_eq(name: str, got, expected) -> None:
    if got == expected:
        ok(name)
    else:
        fail(name, f"expected {expected!r}, got {got!r}")


def expect_true(name: str, cond: bool) -> None:
    if cond:
        ok(name)
    else:
        fail(name, "expected True")


def main() -> int:
    print(f"Loaded {len(CODES)} country codes")
    print("\n== Country parsing ==")
    expect_eq("bracket US", parse_country("[US] Node"), "US")
    expect_eq("dash TR", parse_country("TR-Istanbul-1"), "TR")
    expect_eq("UK->GB", parse_country("UK-London"), "GB")
    expect_eq("flag US", parse_country("🇺🇸 Premium"), "US")
    expect_eq("leftmost DE-US", parse_country("DE-US-relay"), "DE")
    expect_eq("leftmost US-DE", parse_country("US-DE-relay"), "US")
    expect_eq("unknown", parse_country("Premium-Node-01"), None)

    print("\n== User scenarios ==")
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

    p = pick([de_fast, us_slow, us_fast], ["US"], "none")
    expect_eq("2 US only", p.tag if p else None, "us-fast")
    expect_true("2 DE disallowed", not is_allowed(de_fast, ["US"], "none"))

    p = pick([de_fast, Proxy("us-untested", 0, "US")], ["US"], "none")
    expect_eq("2b exclusive keeps US untested", p.tag if p else None, "us-untested")

    p = pick([us_fast, de_slow, de_fast], ["DE"], "any")
    expect_eq("3 DE preferred", p.tag if p else None, "de-fast")

    p = pick([us_fast, tr_fast, Proxy("de-dead", 70000, "DE")], ["DE"], "any")
    expect_eq("3b fallback any -> lowest global", p.tag if p else None, "tr-fast")

    p = pick([us_fast, de_fast], ["US"], "none", mode="manual")
    expect_eq("manual null", p, None)

    print("\n== Edge cases ==")
    expect_true("unknown allowed exclusive", is_allowed(Proxy("Premium-01"), ["US"], "none"))
    expect_true("fallback any allows DE", is_allowed(de_fast, ["US"], "any"))
    p = pick([Proxy("a", 30, "DE"), Proxy("b", 10, "US")], [], "any")
    expect_eq("empty countries + any", p.tag if p else None, "b")
    p = pick([Proxy("us", 20, "US")], ["us"], "none")
    expect_eq("lowercase normalize", p.tag if p else None, "us")

    # Stability: repeated picks same result
    items = [tr_fast, us_slow, us_fast, de_fast]
    tags = {pick(items, ["US", "TR", "DE"], "none").tag for _ in range(20)}  # type: ignore
    expect_eq("deterministic pick", tags, {"us-fast"})

    print("\n== Result ==")
    if failures:
        print(f"{len(failures)} FAILED")
        for f in failures:
            print(" -", f)
        return 1
    print("ALL PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
