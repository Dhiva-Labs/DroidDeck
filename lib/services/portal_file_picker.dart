import 'dart:async';

import 'package:dbus/dbus.dart';

/// File dialogs via the XDG desktop portal (org.freedesktop.portal.FileChooser)
/// over pure-Dart DBus — no native plugin. Callers must handle the empty
/// result (user cancelled or no portal running) and offer a manual-path
/// fallback.
class PortalFilePicker {
  /// Returns picked absolute paths, or [] on cancel/unavailable.
  static Future<List<String>> openFiles({
    String title = 'Open file',
    bool multiple = false,
    bool directory = false,
    (String, List<String>)? filter,
  }) =>
      _request('OpenFile', title, {
        'multiple': DBusBoolean(multiple),
        'directory': DBusBoolean(directory),
        if (filter != null) 'filters': _filters(filter),
      });

  /// Returns the chosen save path, or null on cancel/unavailable.
  static Future<String?> saveFile({
    String title = 'Save file',
    String? suggestedName,
    (String, List<String>)? filter,
  }) async {
    final r = await _request('SaveFile', title, {
      if (suggestedName != null) 'current_name': DBusString(suggestedName),
      if (filter != null) 'filters': _filters(filter),
    });
    return r.isEmpty ? null : r.first;
  }

  static DBusArray _filters((String, List<String>) filter) {
    final (label, globs) = filter;
    return DBusArray(DBusSignature('(sa(us))'), [
      DBusStruct([
        DBusString(label),
        DBusArray(DBusSignature('(us)'), [
          for (final g in globs)
            DBusStruct([DBusUint32(0), DBusString(g)]),
        ]),
      ]),
    ]);
  }

  static Future<List<String>> _request(
    String method,
    String title,
    Map<String, DBusValue> extraOptions,
  ) async {
    final client = DBusClient.session();
    try {
      final token =
          'droiddeck${DateTime.now().microsecondsSinceEpoch}';
      final sender = client.uniqueName.substring(1).replaceAll('.', '_');
      final expectedHandle = DBusObjectPath(
          '/org/freedesktop/portal/desktop/request/$sender/$token');

      // Subscribe before calling so the response can't be missed.
      final responses = DBusSignalStream(
        client,
        interface: 'org.freedesktop.portal.Request',
        name: 'Response',
        path: expectedHandle,
      );
      final firstResponse = responses.first;

      final portal = DBusRemoteObject(
        client,
        name: 'org.freedesktop.portal.Desktop',
        path: DBusObjectPath('/org/freedesktop/portal/desktop'),
      );
      final reply = await portal.callMethod(
        'org.freedesktop.portal.FileChooser',
        method,
        [
          const DBusString(''), // parent window
          DBusString(title),
          DBusDict.stringVariant({
            'handle_token': DBusString(token),
            ...extraOptions,
          }),
        ],
        replySignature: DBusSignature('o'),
      );

      // Older portals may return a different handle path; listen there too.
      final actualHandle = reply.returnValues.first as DBusObjectPath;
      Future<DBusSignal> winner = firstResponse;
      if (actualHandle != expectedHandle) {
        final alt = DBusSignalStream(
          client,
          interface: 'org.freedesktop.portal.Request',
          name: 'Response',
          path: actualHandle,
        ).first;
        winner = Future.any([firstResponse, alt]);
      }

      final signal =
          await winner.timeout(const Duration(minutes: 5));
      final code = (signal.values[0] as DBusUint32).value;
      if (code != 0) return const [];
      final results = signal.values[1] as DBusDict;
      final uris = results.children[const DBusString('uris')];
      if (uris is! DBusArray) return const [];
      return [
        for (final u in uris.children)
          Uri.parse((u as DBusString).value).toFilePath(),
      ];
    } catch (_) {
      return const [];
    } finally {
      unawaited(client.close());
    }
  }
}
