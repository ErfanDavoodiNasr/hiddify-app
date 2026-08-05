import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/proxy/model/proxy_countries.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

/// How proxies are auto-selected after delay tests.
enum ProxySelectMode {
  /// User picks manually; app never auto-switches.
  manual,

  /// Prefer countries in order; within a tier pick lowest ping.
  countryPriority;

  String present(TranslationsEn t) => switch (this) {
    manual => t.pages.proxies.selectStrategy.modes.manual,
    countryPriority => t.pages.proxies.selectStrategy.modes.countryPriority,
  };
}

/// What to do when no alive proxy matches the priority countries.
enum CountryFallbackMode {
  /// Stay within the priority list only (exclusive). Never pick outside it.
  none,

  /// If none of the priority countries are alive, pick the global lowest ping.
  any;

  String present(TranslationsEn t) => switch (this) {
    none => t.pages.proxies.selectStrategy.fallback.none,
    any => t.pages.proxies.selectStrategy.fallback.any,
  };

  String description(TranslationsEn t) => switch (this) {
    none => t.pages.proxies.selectStrategy.fallback.noneMsg,
    any => t.pages.proxies.selectStrategy.fallback.anyMsg,
  };
}

abstract final class ProxySelectAlgorithm {
  static const int timeoutDelay = 65000;

  static bool isAlive(OutboundInfo item) {
    if (item.isGroup) return false;
    final delay = item.urlTestDelay;
    return delay > 0 && delay <= timeoutDelay;
  }

  /// Resolve ISO country code from core geo info, else from tag / display name.
  static String? resolveCountryCode(OutboundInfo item) {
    final fromIp = item.ipinfo.countryCode.trim().toUpperCase();
    if (fromIp.isNotEmpty) return fromIp == 'UK' ? 'GB' : fromIp;
    final parsed = parseCountryFromText('${item.tag} ${item.tagDisplay}');
    return parsed == 'UK' ? 'GB' : parsed;
  }

  static String? parseCountryFromText(String text) {
    if (text.isEmpty) return null;

    final fromFlag = _flagEmojiToCountry(text);
    if (fromFlag != null) return fromFlag == 'UK' ? 'GB' : fromFlag;

    final upper = text.toUpperCase();

    // [US], (US), {US}
    final bracket = RegExp(r'[\[\(\{]([A-Z]{2})[\]\)\}]').firstMatch(upper);
    if (bracket != null) {
      final code = bracket.group(1)!;
      if (ProxyCountries.codes.contains(code) || code == 'UK') {
        return code == 'UK' ? 'GB' : code;
      }
    }

    // Leftmost ISO match — Set iteration order must not decide between DE-US vs US-DE.
    Match? bestMatch;
    String? bestCode;
    for (final code in [...ProxyCountries.codes, 'UK']) {
      final match = RegExp('(?:^|[^A-Z])($code)(?:[^A-Z]|\$)').firstMatch(upper);
      if (match == null) continue;
      if (bestMatch == null || match.start < bestMatch.start) {
        bestMatch = match;
        bestCode = code;
      }
    }
    if (bestCode != null) return bestCode == 'UK' ? 'GB' : bestCode;

    return null;
  }

  static String? _flagEmojiToCountry(String text) {
    final runes = text.runes.toList();
    for (var i = 0; i < runes.length - 1; i++) {
      final a = runes[i];
      final b = runes[i + 1];
      // Regional Indicator Symbol Letter A..Z
      if (a >= 0x1F1E6 && a <= 0x1F1FF && b >= 0x1F1E6 && b <= 0x1F1FF) {
        final c1 = String.fromCharCode(a - 0x1F1E6 + 0x41);
        final c2 = String.fromCharCode(b - 0x1F1E6 + 0x41);
        return '$c1$c2';
      }
    }
    return null;
  }

  /// Pick best outbound for the configured strategy, or null if nothing matches.
  static OutboundInfo? pick({
    required Iterable<OutboundInfo> items,
    required ProxySelectMode mode,
    required List<String> priorityCountries,
    required CountryFallbackMode fallback,
  }) {
    if (mode == ProxySelectMode.manual) return null;

    final all = items.where((e) => !e.isGroup).toList();
    if (all.isEmpty) return null;

    final alive = all.where(isAlive).toList();
    final countries = priorityCountries.map((e) => e.toUpperCase()).where((e) => e.isNotEmpty).toList();

    if (countries.isEmpty) {
      return fallback == CountryFallbackMode.any ? (alive.isNotEmpty ? _lowestPing(alive) : null) : null;
    }

    // Prefer alive proxies in priority order (lowest ping within each tier).
    for (final country in countries) {
      final tier = alive.where((item) => resolveCountryCode(item) == country).toList();
      if (tier.isNotEmpty) return _lowestPing(tier);
    }

    if (fallback == CountryFallbackMode.any) {
      if (alive.isNotEmpty) return _lowestPing(alive);
      return null;
    }

    // Exclusive: never leave the priority countries — even if ping is unknown/failed,
    // prefer an in-list proxy over a foreign one.
    for (final country in countries) {
      final tier = all.where((item) => resolveCountryCode(item) == country).toList();
      if (tier.isEmpty) continue;
      final withDelay = tier.where((e) => e.urlTestDelay > 0 && e.urlTestDelay <= timeoutDelay).toList();
      if (withDelay.isNotEmpty) return _lowestPing(withDelay);
      return tier.first;
    }

    return null;
  }

  /// Whether [item] is allowed under exclusive (no-fallback) rules.
  ///
  /// Unknown country (no geo / unparsable tag) is treated as allowed so we do not
  /// kick a valid server before ipinfo is populated.
  static bool isAllowed({
    required OutboundInfo item,
    required ProxySelectMode mode,
    required List<String> priorityCountries,
    required CountryFallbackMode fallback,
  }) {
    if (mode == ProxySelectMode.manual) return true;
    if (fallback == CountryFallbackMode.any) return true;
    final countries = priorityCountries.map((e) => e.toUpperCase()).where((e) => e.isNotEmpty).toSet();
    if (countries.isEmpty) return true;
    final code = resolveCountryCode(item);
    if (code == null) return true;
    return countries.contains(code);
  }

  static OutboundInfo _lowestPing(List<OutboundInfo> items) {
    return items.reduce((a, b) => a.urlTestDelay <= b.urlTestDelay ? a : b);
  }
}
