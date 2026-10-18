/// A country's international dialling code, for phone numbers on cards.
class CountryDial {
  /// ISO 3166-1 alpha-2 code, e.g. "IN".
  final String iso;
  final String name;

  /// Dialling code without the plus, e.g. "91".
  final String code;

  const CountryDial(this.iso, this.name, this.code);

  String get plusCode => '+$code';

  /// Flag emoji built from the ISO code (regional indicator letters).
  String get flag => String.fromCharCodes(
    iso.toUpperCase().codeUnits.map((c) => 0x1F1E6 + c - 0x41),
  );
}

/// Common countries. Ordered by name; the user's own region is offered
/// first by the picker.
const List<CountryDial> countryDials = [
  CountryDial('AF', 'Afghanistan', '93'),
  CountryDial('AR', 'Argentina', '54'),
  CountryDial('AU', 'Australia', '61'),
  CountryDial('AT', 'Austria', '43'),
  CountryDial('BH', 'Bahrain', '973'),
  CountryDial('BD', 'Bangladesh', '880'),
  CountryDial('BE', 'Belgium', '32'),
  CountryDial('BT', 'Bhutan', '975'),
  CountryDial('BR', 'Brazil', '55'),
  CountryDial('CA', 'Canada', '1'),
  CountryDial('CL', 'Chile', '56'),
  CountryDial('CN', 'China', '86'),
  CountryDial('CO', 'Colombia', '57'),
  CountryDial('CZ', 'Czechia', '420'),
  CountryDial('DK', 'Denmark', '45'),
  CountryDial('EG', 'Egypt', '20'),
  CountryDial('FI', 'Finland', '358'),
  CountryDial('FR', 'France', '33'),
  CountryDial('DE', 'Germany', '49'),
  CountryDial('GH', 'Ghana', '233'),
  CountryDial('GR', 'Greece', '30'),
  CountryDial('HK', 'Hong Kong', '852'),
  CountryDial('HU', 'Hungary', '36'),
  CountryDial('IN', 'India', '91'),
  CountryDial('ID', 'Indonesia', '62'),
  CountryDial('IR', 'Iran', '98'),
  CountryDial('IQ', 'Iraq', '964'),
  CountryDial('IE', 'Ireland', '353'),
  CountryDial('IL', 'Israel', '972'),
  CountryDial('IT', 'Italy', '39'),
  CountryDial('JP', 'Japan', '81'),
  CountryDial('JO', 'Jordan', '962'),
  CountryDial('KE', 'Kenya', '254'),
  CountryDial('KW', 'Kuwait', '965'),
  CountryDial('MY', 'Malaysia', '60'),
  CountryDial('MV', 'Maldives', '960'),
  CountryDial('MX', 'Mexico', '52'),
  CountryDial('MA', 'Morocco', '212'),
  CountryDial('MM', 'Myanmar', '95'),
  CountryDial('NP', 'Nepal', '977'),
  CountryDial('NL', 'Netherlands', '31'),
  CountryDial('NZ', 'New Zealand', '64'),
  CountryDial('NG', 'Nigeria', '234'),
  CountryDial('NO', 'Norway', '47'),
  CountryDial('OM', 'Oman', '968'),
  CountryDial('PK', 'Pakistan', '92'),
  CountryDial('PE', 'Peru', '51'),
  CountryDial('PH', 'Philippines', '63'),
  CountryDial('PL', 'Poland', '48'),
  CountryDial('PT', 'Portugal', '351'),
  CountryDial('QA', 'Qatar', '974'),
  CountryDial('RO', 'Romania', '40'),
  CountryDial('RU', 'Russia', '7'),
  CountryDial('SA', 'Saudi Arabia', '966'),
  CountryDial('SG', 'Singapore', '65'),
  CountryDial('ZA', 'South Africa', '27'),
  CountryDial('KR', 'South Korea', '82'),
  CountryDial('ES', 'Spain', '34'),
  CountryDial('LK', 'Sri Lanka', '94'),
  CountryDial('SE', 'Sweden', '46'),
  CountryDial('CH', 'Switzerland', '41'),
  CountryDial('TW', 'Taiwan', '886'),
  CountryDial('TZ', 'Tanzania', '255'),
  CountryDial('TH', 'Thailand', '66'),
  CountryDial('TR', 'Türkiye', '90'),
  CountryDial('UG', 'Uganda', '256'),
  CountryDial('UA', 'Ukraine', '380'),
  CountryDial('AE', 'United Arab Emirates', '971'),
  CountryDial('GB', 'United Kingdom', '44'),
  CountryDial('US', 'United States', '1'),
  CountryDial('VN', 'Vietnam', '84'),
];

/// The country for [iso], or null.
CountryDial? countryForIso(String? iso) {
  if (iso == null) return null;
  final upper = iso.toUpperCase();
  for (final c in countryDials) {
    if (c.iso == upper) return c;
  }
  return null;
}

/// Splits a stored phone ("+91 98765 43210") into its country and the
/// rest. Uses the longest matching code; [preferredIso] breaks ties between
/// countries sharing a code (+1: US / Canada). Numbers without a "+" return
/// no country and the number unchanged.
(CountryDial?, String) splitPhone(String phone, {String? preferredIso}) {
  final trimmed = phone.trim();
  if (!trimmed.startsWith('+')) return (null, trimmed);
  final digits = trimmed.substring(1).replaceAll(RegExp(r'[^0-9]'), '');
  CountryDial? best;
  for (final c in countryDials) {
    if (!digits.startsWith(c.code)) continue;
    final better =
        best == null ||
        c.code.length > best.code.length ||
        (c.code.length == best.code.length &&
            c.iso == preferredIso?.toUpperCase());
    if (better) best = c;
  }
  if (best == null) return (null, trimmed);
  // Keep the user's own spacing in the rest of the number.
  var rest = trimmed.substring(1);
  var consumed = 0;
  var cut = 0;
  while (cut < rest.length && consumed < best.code.length) {
    if (RegExp(r'[0-9]').hasMatch(rest[cut])) consumed++;
    cut++;
  }
  rest = rest.substring(cut).trim();
  return (best, rest);
}

/// "+91" and "98765 43210" -> "+91 98765 43210".
String joinPhone(CountryDial country, String national) {
  final rest = national.trim().replaceFirst(RegExp(r'^0+'), '');
  return rest.isEmpty ? '' : '${country.plusCode} $rest';
}
