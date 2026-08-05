import 'dart:async';

import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/model/proxy_select_strategy.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Keeps [ProxySelectStrategyController] alive while the app runs.
final proxySelectStrategyControllerProvider = Provider<ProxySelectStrategyController>((ref) {
  final controller = ProxySelectStrategyController(ref);
  ref.onDispose(controller.dispose);
  controller.init();
  return controller;
});

/// Applies country-priority / exclusive selection while connected.
class ProxySelectStrategyController with AppLogger {
  ProxySelectStrategyController(this._ref);

  final Ref _ref;
  String? _lastSelectedTag;
  DateTime? _lastApplyAt;
  bool _applying = false;
  OutboundGroup? _latestGroup;
  final List<ProviderSubscription<dynamic>> _subs = [];
  StreamSubscription<dynamic>? _proxySub;

  void init() {
    _subs.add(
      _ref.listen(serviceRunningProvider, (previous, next) {
        if (next) {
          unawaited(apply(force: true));
        } else {
          _lastSelectedTag = null;
          _latestGroup = null;
        }
      }),
    );
    _subs.add(_ref.listen(Preferences.proxySelectMode, (_, _) => unawaited(apply(force: true))));
    _subs.add(_ref.listen(Preferences.proxySelectCountries, (_, _) => unawaited(apply(force: true))));
    _subs.add(_ref.listen(Preferences.proxySelectFallback, (_, _) => unawaited(apply(force: true))));

    _proxySub = _ref.read(proxyRepositoryProvider).watchProxies().listen((event) {
      event.fold(
        (err) => loggy.debug('proxy select watch error: $err'),
        (group) {
          _latestGroup = group;
          if (group != null) unawaited(_onGroup(group));
        },
      );
    });
  }

  void dispose() {
    for (final sub in _subs) {
      sub.close();
    }
    _subs.clear();
    unawaited(_proxySub?.cancel());
  }

  Future<void> apply({bool force = false}) async {
    if (!_ref.read(serviceRunningProvider)) return;
    final mode = _ref.read(Preferences.proxySelectMode);
    if (mode == ProxySelectMode.manual) return;
    final group = _latestGroup;
    if (group != null) await _onGroup(group, force: force);
  }

  Future<void> _onGroup(OutboundGroup group, {bool force = false}) async {
    final mode = _ref.read(Preferences.proxySelectMode);
    if (mode == ProxySelectMode.manual) return;
    if (_applying) return;

    final now = DateTime.now();
    if (!force && _lastApplyAt != null && now.difference(_lastApplyAt!) < const Duration(milliseconds: 800)) {
      return;
    }

    final countries = _ref.read(Preferences.proxySelectCountries).where((e) => e.isNotEmpty).toList();
    final fallback = _ref.read(Preferences.proxySelectFallback);

    OutboundInfo? selectedItem;
    for (final item in group.items) {
      if (item.tag == group.selected) {
        selectedItem = item;
        break;
      }
    }
    if (selectedItem != null &&
        !ProxySelectAlgorithm.isAllowed(
          item: selectedItem,
          mode: mode,
          priorityCountries: countries,
          fallback: fallback,
        )) {
      loggy.info(
        'selected proxy [${selectedItem.tag}] violates exclusive country rules; reselecting',
      );
      force = true;
    }

    final best = ProxySelectAlgorithm.pick(
      items: group.items,
      mode: mode,
      priorityCountries: countries,
      fallback: fallback,
    );
    if (best == null) {
      loggy.debug('no matching proxy for country priority strategy');
      return;
    }

    if (!force && best.tag == group.selected) {
      _lastSelectedTag = best.tag;
      return;
    }
    if (!force && best.tag == _lastSelectedTag) return;

    _applying = true;
    _lastApplyAt = now;
    try {
      loggy.info(
        'auto-selecting proxy [${best.tag}] '
        '(country=${ProxySelectAlgorithm.resolveCountryCode(best)}, delay=${best.urlTestDelay})',
      );
      await _ref.read(proxyRepositoryProvider).selectProxy(group.tag, best.tag).getOrElse((err) {
        loggy.warning('error auto-selecting proxy', err);
        throw err;
      }).run();
      _lastSelectedTag = best.tag;
    } finally {
      _applying = false;
    }
  }
}
