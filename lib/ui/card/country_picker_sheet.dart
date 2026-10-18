import 'package:flutter/material.dart';

import 'package:vayu/domain/contacts/country_codes.dart';
import 'package:vayu/ui/widgets/vayu_feedback.dart';

/// Bottom sheet to choose a phone country code, with search by name or code.
Future<CountryDial?> showCountryPicker(
  BuildContext context, {
  required CountryDial current,
}) {
  return showVayuSheet<CountryDial>(
    context: context,
    builder: (_) => _CountryPicker(current: current),
  );
}

class _CountryPicker extends StatefulWidget {
  final CountryDial current;

  const _CountryPicker({required this.current});

  @override
  State<_CountryPicker> createState() => _CountryPickerState();
}

class _CountryPickerState extends State<_CountryPicker> {
  String _query = '';

  List<CountryDial> get _matches {
    final q = _query.trim().toLowerCase().replaceFirst('+', '');
    if (q.isEmpty) return countryDials;
    return countryDials
        .where(
          (c) =>
              c.name.toLowerCase().contains(q) ||
              c.code.startsWith(q) ||
              c.iso.toLowerCase() == q,
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = _matches;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: TextField(
              autofocus: false,
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Search country or code',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          Expanded(
            child: matches.isEmpty
                ? Center(
                    child: Text('No match', style: theme.textTheme.bodyMedium),
                  )
                : ListView.builder(
                    itemCount: matches.length,
                    itemBuilder: (context, i) {
                      final c = matches[i];
                      final selected = c.iso == widget.current.iso;
                      return ListTile(
                        leading: Text(
                          c.flag,
                          style: const TextStyle(fontSize: 22),
                        ),
                        title: Text(c.name),
                        trailing: Text(
                          c.plusCode,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: selected
                                ? theme.colorScheme.secondary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        selected: selected,
                        onTap: () => Navigator.of(context).pop(c),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
