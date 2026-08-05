import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/locale_preferences.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/proxy/active/ip_widget.dart';
import 'package:hiddify/features/proxy/model/proxy_countries.dart';
import 'package:hiddify/features/proxy/model/proxy_select_strategy.dart';
import 'package:hiddify/features/proxy/notifier/proxy_select_strategy_notifier.dart';
import 'package:hiddify/features/settings/widget/preference_tile.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProxySelectStrategyPage extends HookConsumerWidget {
  const ProxySelectStrategyPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final mode = ref.watch(Preferences.proxySelectMode);
    final countries = ref.watch(Preferences.proxySelectCountries).where((e) => e.isNotEmpty).toList();
    final fallback = ref.watch(Preferences.proxySelectFallback);
    final countryPriority = mode == ProxySelectMode.countryPriority;
    final persian = ref.watch(localePreferencesProvider) == AppLocale.fa;

    return Scaffold(
      appBar: AppBar(title: Text(t.pages.proxies.selectStrategy.title)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              t.pages.proxies.selectStrategy.description,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          ChoicePreferenceWidget(
            title: t.pages.proxies.selectStrategy.mode,
            icon: FluentIcons.arrow_routing_24_regular,
            selected: mode,
            preferences: ref.watch(Preferences.proxySelectMode.notifier),
            choices: ProxySelectMode.values,
            presentChoice: (value) => value.present(t),
          ),
          if (countryPriority) ...[
            ChoicePreferenceWidget(
              title: t.pages.proxies.selectStrategy.fallback.title,
              icon: Icons.alt_route_rounded,
              selected: fallback,
              preferences: ref.watch(Preferences.proxySelectFallback.notifier),
              choices: CountryFallbackMode.values,
              presentChoice: (value) => value.present(t),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                fallback.description(t),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            const Gap(8),
            ListTile(
              title: Text(t.pages.proxies.selectStrategy.priorityList),
              subtitle: Text(t.pages.proxies.selectStrategy.priorityListMsg),
              leading: const Icon(Icons.public_rounded),
              trailing: IconButton(
                tooltip: t.pages.proxies.selectStrategy.addCountry,
                icon: const Icon(Icons.add_rounded),
                onPressed: () => _addCountry(context, ref, t, countries, persian),
              ),
            ),
            if (countries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Text(
                  t.pages.proxies.selectStrategy.emptyCountries,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                ),
              )
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: countries.length,
                onReorder: (oldIndex, newIndex) async {
                  final updated = [...countries];
                  if (newIndex > oldIndex) newIndex -= 1;
                  final item = updated.removeAt(oldIndex);
                  updated.insert(newIndex, item);
                  await ref.read(Preferences.proxySelectCountries.notifier).update(updated);
                  await ref.read(proxySelectStrategyControllerProvider).apply(force: true);
                },
                itemBuilder: (context, index) {
                  final code = countries[index];
                  return ListTile(
                    key: ValueKey(code),
                    leading: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ReorderableDragStartListener(
                          index: index,
                          child: const Icon(Icons.drag_handle_rounded),
                        ),
                        const Gap(8),
                        Text('${index + 1}.', style: theme.textTheme.titleMedium),
                        const Gap(8),
                        IPCountryFlag(countryCode: code, size: 28),
                      ],
                    ),
                    title: Text(ProxyCountries.present(code, persian: persian)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: () async {
                        final updated = [...countries]..removeAt(index);
                        await ref.read(Preferences.proxySelectCountries.notifier).update(updated);
                        await ref.read(proxySelectStrategyControllerProvider).apply(force: true);
                      },
                    ),
                  );
                },
              ),
            const Gap(8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(t.pages.proxies.selectStrategy.examples, style: theme.textTheme.bodySmall),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _addCountry(
    BuildContext context,
    WidgetRef ref,
    TranslationsEn t,
    List<String> selected,
    bool persian,
  ) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _CountryPickerSheet(
        title: t.pages.proxies.selectStrategy.addCountry,
        searchHint: t.pages.proxies.selectStrategy.searchCountry,
        selected: selected,
        persian: persian,
      ),
    );

    if (picked == null) return;
    await ref.read(Preferences.proxySelectCountries.notifier).update([...selected, picked]);
    await ref.read(proxySelectStrategyControllerProvider).apply(force: true);
  }
}

class _CountryPickerSheet extends HookWidget {
  const _CountryPickerSheet({
    required this.title,
    required this.searchHint,
    required this.selected,
    required this.persian,
  });

  final String title;
  final String searchHint;
  final List<String> selected;
  final bool persian;

  @override
  Widget build(BuildContext context) {
    final query = useState('');
    final results = useMemoized(
      () => ProxyCountries.search(query.value, persian: persian).where((c) => !selected.contains(c.code)).toList(),
      [query.value, selected, persian],
    );

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: true,
                decoration: InputDecoration(
                  hintText: searchHint,
                  prefixIcon: const Icon(Icons.search_rounded),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (value) => query.value = value,
              ),
            ),
            const Gap(8),
            Expanded(
              child: results.isEmpty
                  ? Center(child: Text(searchHint))
                  : ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final country = results[index];
                        return ListTile(
                          leading: IPCountryFlag(countryCode: country.code, size: 32),
                          title: Text(country.present(persian: persian)),
                          onTap: () => Navigator.of(context).pop(country.code),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
