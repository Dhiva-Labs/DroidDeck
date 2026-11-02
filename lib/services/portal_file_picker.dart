import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';

/// File dialogs via the XDG desktop portal (org.freedesktop.portal.FileChooser)
/// over pure-Dart DBus, falling back to GTK's own dialog (linux/runner's
/// `droiddeck/file_chooser` channel) when no portal answers — common on
/// XFCE and other desktops that ship without a FileChooser backend.
/// Callers must still handle the empty result (user cancelled, or neither
/// dialog could open).
class PortalFilePicker {
  static const _native = MethodChannel('droiddeck/file_chooser');

  /// Returns picked absolute paths, or [] on cancel/unavailable.
  static Future<List<String>> openFiles({
    String title = 'Open file',
    bool multiple = false,
    bool directory = false,
    (String, List<String>)? filter,
  }) async {
    final viaPortal = await _request('OpenFile', title, {
      'multiple': DBusBoolean(multiple),
      'directory': DBusBoolean(directory),
      if (filter != null) 'filters': _filters(filter),
    });
    if (viaPortal != null) return viaPortal;
    try {
      final paths = await _native.invokeListMethod<String>('openFiles', {
        'title': title,
        'multiple': multiple,
        'directory': directory,
        ..._nativeFilter(filter),
      });
      return paths ?? const [];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Returns the chosen save path, or null on cancel/unavailable.
  static Future<String?> saveFile({
    String title = 'Save file',
    String? suggestedName,
    (String, List<String>)? filter,
  }) async {
    final viaPortal = await _request('SaveFile', title, {
      if (suggestedName != null) 'current_name': DBusString(suggestedName),
      if (filter != null) 'filters': _filters(filter),
    });
    if (viaPortal != null) return viaPortal.isEmpty ? null : viaPortal.first;
    try {
      return await _native.invokeMethod<String>('saveFile', {
        'title': title,
        'suggestedName': ?suggestedName,
        ..._nativeFilter(filter),
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
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

  static Map<String, Object> _nativeFilter((String, List<String>)? filter) {
    if (filter == null) return const {};
    final (label, globs) = filter;
    return {'filterName': label, 'filterPatterns': globs};
  }

  /// The portal's handle for our window (`x11:XID`), so its dialog is
  /// stacked above DroidDeck instead of opening as a stray toplevel that
  /// focus-stealing prevention may push behind it. '' when unknown.
  static Future<String> _parentWindow() async {
    try {
      return await _native.invokeMethod<String>('parentWindow') ?? '';
    } on MissingPluginException {
      return '';
    } on PlatformException {
      return '';
    }
  }

  /// One FileChooser request: picked paths, [] when the user cancelled, or
  /// null when no portal answered so the caller should fall back.
  static Future<List<String>?> _request(
    String method,
    String title,
    Map<String, DBusValue> extraOptions,
  ) async {
    final client = DBusClient.session();
    try {
      // The client connects lazily and its unique name stays '' until then,
      // so the request handle below can't be derived before a round trip.
      await client.ping();
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
          DBusString(await _parentWindow()),
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
      // 1 is a user cancel; anything else means the backend itself failed.
      if (code == 1) return const [];
      if (code != 0) return null;
      // a{sv}: each result is wrapped in a variant, which this unwraps.
      final uris = signal.values[1].asStringVariantDict()['uris'];
      if (uris is! DBusArray) return const [];
      return [
        for (final u in uris.asStringArray()) Uri.parse(u).toFilePath(),
      ];
    } on TimeoutException {
      return const [];
    } catch (_) {
      // No session bus, no portal, or a portal without a FileChooser
      // backend (UnknownInterface/UnknownMethod).
      return null;
    } finally {
      unawaited(client.close());
    }
  }
}
