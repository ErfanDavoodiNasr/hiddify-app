import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/model/proxy_countries.dart';
import 'package:hiddify/features/proxy/model/proxy_select_strategy.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

OutboundInfo _proxy({
  required String tag,
  int delay = 100,
  String? country,
  String? tagDisplay,
  bool isGroup = false,
}) {
  return OutboundInfo(
    tag: tag,
    tagDisplay: tagDisplay ?? tag,
    urlTestDelay: delay,
    isGroup: isGroup,
    ipinfo: country == null ? null : IpInfo(countryCode: country),
  );
}

OutboundInfo? _pick({
  required List<OutboundInfo> items,
  List<String> countries = const [],
  CountryFallbackMode fallback = CountryFallbackMode.none,
  ProxySelectMode mode = ProxySelectMode.countryPriority,
}) {
  return ProxySelectAlgorithm.pick(
    items: items,
    mode: mode,
    priorityCountries: countries,
    fallback: fallback,
  );
}

void main() {
  group('ProxyCountries', () {
    test('has complete unique ISO list', () {
      expect(ProxyCountries.all.length, greaterThanOrEqualTo(240));
      expect(ProxyCountries.codes.length, ProxyCountries.all.length);
      expect(ProxyCountries.byCode('us')?.code, 'US');
      expect(ProxyCountries.byCode('DE')?.nameFa, 'آلمان');
      expect(ProxyCountries.byCode('TR')?.nameEn, 'Türkiye');
    });

    test('search finds by code, english and persian', () {
      expect(ProxyCountries.search('us', persian: false).any((c) => c.code == 'US'), isTrue);
      expect(ProxyCountries.search('germany', persian: false).any((c) => c.code == 'DE'), isTrue);
      expect(ProxyCountries.search('آلمان', persian: true).any((c) => c.code == 'DE'), isTrue);
      expect(ProxyCountries.search('ترکیه', persian: true).any((c) => c.code == 'TR'), isTrue);
    });

    test('popular countries appear first in picker order', () {
      final sorted = ProxyCountries.sortedForPicker(persian: false);
      expect(sorted.first.code, 'US');
      expect(sorted[1].code, 'DE');
      expect(sorted[2].code, 'TR');
    });
  });

  group('country parsing', () {
    test('prefers ipinfo over tag', () {
      final item = _proxy(tag: 'DE-1', country: 'US');
      expect(ProxySelectAlgorithm.resolveCountryCode(item), 'US');
    });

    test('maps UK to GB', () {
      expect(ProxySelectAlgorithm.resolveCountryCode(_proxy(tag: 'x', country: 'UK')), 'GB');
      expect(ProxySelectAlgorithm.parseCountryFromText('UK-London'), 'GB');
    });

    test('parses brackets, dashes and flag emoji', () {
      expect(ProxySelectAlgorithm.parseCountryFromText('[US] Node'), 'US');
      expect(ProxySelectAlgorithm.parseCountryFromText('(DE)'), 'DE');
      expect(ProxySelectAlgorithm.parseCountryFromText('TR-Istanbul-1'), 'TR');
      expect(ProxySelectAlgorithm.parseCountryFromText('🇺🇸 Premium'), 'US');
      expect(ProxySelectAlgorithm.parseCountryFromText('🇩🇪-Hetzner'), 'DE');
    });

    test('leftmost country wins when multiple codes exist', () {
      expect(ProxySelectAlgorithm.parseCountryFromText('DE-US-relay'), 'DE');
      expect(ProxySelectAlgorithm.parseCountryFromText('US-DE-relay'), 'US');
    });

    test('returns null for empty / unknown', () {
      expect(ProxySelectAlgorithm.parseCountryFromText(''), isNull);
      expect(ProxySelectAlgorithm.parseCountryFromText('Premium-Node-01'), isNull);
    });
  });

  group('isAlive', () {
    test('rejects groups, zero delay and timeout', () {
      expect(ProxySelectAlgorithm.isAlive(_proxy(tag: 'a', delay: 0)), isFalse);
      expect(ProxySelectAlgorithm.isAlive(_proxy(tag: 'a', delay: 65001)), isFalse);
      expect(ProxySelectAlgorithm.isAlive(_proxy(tag: 'a', delay: 100, isGroup: true)), isFalse);
      expect(ProxySelectAlgorithm.isAlive(_proxy(tag: 'a', delay: 100)), isTrue);
      expect(ProxySelectAlgorithm.isAlive(_proxy(tag: 'a', delay: 65000)), isTrue);
    });
  });

  group('user scenarios', () {
    final usFast = _proxy(tag: 'us-fast', country: 'US', delay: 80);
    final usSlow = _proxy(tag: 'us-slow', country: 'US', delay: 400);
    final trFast = _proxy(tag: 'tr-fast', country: 'TR', delay: 40);
    final deFast = _proxy(tag: 'de-fast', country: 'DE', delay: 50);
    final deSlow = _proxy(tag: 'de-slow', country: 'DE', delay: 300);
    final group = _proxy(tag: 'select', isGroup: true, delay: 1);

    test('1) US → TR → DE: prefers US lowest ping even if TR is faster', () {
      final picked = _pick(
        items: [group, trFast, usSlow, usFast, deFast],
        countries: ['US', 'TR', 'DE'],
        fallback: CountryFallbackMode.none,
      );
      expect(picked?.tag, 'us-fast');
    });

    test('1b) US → TR → DE: falls to TR when US is dead', () {
      final picked = _pick(
        items: [
          _proxy(tag: 'us-dead', country: 'US', delay: 0),
          trFast,
          deFast,
        ],
        countries: ['US', 'TR', 'DE'],
        fallback: CountryFallbackMode.none,
      );
      expect(picked?.tag, 'tr-fast');
    });

    test('2) US only exclusive: never picks DE', () {
      final picked = _pick(
        items: [deFast, usSlow, usFast],
        countries: ['US'],
        fallback: CountryFallbackMode.none,
      );
      expect(picked?.tag, 'us-fast');
      expect(
        ProxySelectAlgorithm.isAllowed(
          item: deFast,
          mode: ProxySelectMode.countryPriority,
          priorityCountries: ['US'],
          fallback: CountryFallbackMode.none,
        ),
        isFalse,
      );
    });

    test('2b) US only exclusive: if US untested, still stays on US not DE', () {
      final picked = _pick(
        items: [
          deFast,
          _proxy(tag: 'us-untested', country: 'US', delay: 0),
        ],
        countries: ['US'],
        fallback: CountryFallbackMode.none,
      );
      expect(picked?.tag, 'us-untested');
    });

    test('3) DE preferred then any: uses DE when alive', () {
      final picked = _pick(
        items: [usFast, deSlow, deFast],
        countries: ['DE'],
        fallback: CountryFallbackMode.any,
      );
      expect(picked?.tag, 'de-fast');
    });

    test('3b) DE preferred then any: falls back to global lowest ping', () {
      final picked = _pick(
        items: [
          usFast,
          trFast,
          _proxy(tag: 'de-dead', country: 'DE', delay: 70000),
        ],
        countries: ['DE'],
        fallback: CountryFallbackMode.any,
      );
      expect(picked?.tag, 'tr-fast');
    });

    test('manual mode never auto-picks', () {
      expect(
        _pick(
          items: [usFast, deFast],
          countries: ['US'],
          mode: ProxySelectMode.manual,
        ),
        isNull,
      );
    });
  });

  group('isAllowed', () {
    test('unknown country is allowed until geo is known', () {
      final unknown = _proxy(tag: 'Premium-01', delay: 100);
      expect(
        ProxySelectAlgorithm.isAllowed(
          item: unknown,
          mode: ProxySelectMode.countryPriority,
          priorityCountries: ['US'],
          fallback: CountryFallbackMode.none,
        ),
        isTrue,
      );
    });

    test('fallback any allows every country', () {
      final de = _proxy(tag: 'de', country: 'DE');
      expect(
        ProxySelectAlgorithm.isAllowed(
          item: de,
          mode: ProxySelectMode.countryPriority,
          priorityCountries: ['US'],
          fallback: CountryFallbackMode.any,
        ),
        isTrue,
      );
    });
  });

  group('edge cases', () {
    test('empty items / empty countries', () {
      expect(_pick(items: [], countries: ['US']), isNull);
      expect(
        _pick(
          items: [_proxy(tag: 'us', country: 'US', delay: 10)],
          countries: [],
          fallback: CountryFallbackMode.none,
        ),
        isNull,
      );
      expect(
        _pick(
          items: [
            _proxy(tag: 'a', country: 'DE', delay: 30),
            _proxy(tag: 'b', country: 'US', delay: 10),
          ],
          countries: [],
          fallback: CountryFallbackMode.any,
        )?.tag,
        'b',
      );
    });

    test('normalizes lowercase country priority', () {
      final picked = _pick(
        items: [_proxy(tag: 'us', country: 'US', delay: 20)],
        countries: ['us'],
      );
      expect(picked?.tag, 'us');
    });

    test('ignores selector groups in candidates', () {
      final picked = _pick(
        items: [
          _proxy(tag: 'select', isGroup: true, delay: 1, country: 'US'),
          _proxy(tag: 'real-us', country: 'US', delay: 90),
        ],
        countries: ['US'],
      );
      expect(picked?.tag, 'real-us');
    });
  });
}
