// Quest multi-window (fork): one Horizon OS 2D panel per remote display.
//
// Main window (the normal mobile app):
//   - When connected to a peer with 2+ displays, on a Meta Quest (or when the local option
//     `quest-multi-window` is 'Y'), the main panel keeps ONE display and every other
//     display is opened in its own Android activity (`QuestDisplayActivity`), launched with
//     FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_MULTIPLE_TASK | FLAG_ACTIVITY_LAUNCH_ADJACENT.
//   - New remote displays (e.g. a RustDesk virtual display) open a new panel; removed
//     displays close theirs.
//   - When a panel is closed, its ui session is released here (`sessionClose`), so the
//     display is no longer captured (the Rust core recomputes the captured set).
//
// Secondary window (`questDisplayMain` entrypoint, own Flutter engine, same process):
//   - Joins the existing peer connection as an extra ui session that only owns its
//     display (`sessionAddExistedSync` + `sessionStartWithDisplays`), so frames and
//     input are mapped to that display only.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../common.dart';
import '../consts.dart';
import '../models/model.dart';
import '../models/platform_model.dart';

/// Arguments of a secondary display panel. Null in the main window.
class QuestWindowArgs {
  final String peerId;
  final int display;
  final String sessionId;
  final String cachedData;
  final String title;
  final bool isQuest;

  QuestWindowArgs({
    required this.peerId,
    required this.display,
    required this.sessionId,
    required this.cachedData,
    required this.title,
    required this.isQuest,
  });

  static QuestWindowArgs? fromArgs(List<String> args) {
    if (args.isEmpty) return null;
    try {
      final m = jsonDecode(args.first) as Map<String, dynamic>;
      final peerId = (m['peer_id'] ?? '') as String;
      final sessionId = (m['session_id'] ?? '') as String;
      if (peerId.isEmpty || sessionId.isEmpty) return null;
      return QuestWindowArgs(
        peerId: peerId,
        display: (m['display'] ?? 0) as int,
        sessionId: sessionId,
        cachedData: (m['cached_data'] ?? '') as String,
        title: (m['title'] ?? '') as String,
        isQuest: (m['is_quest'] ?? true) as bool,
      );
    } catch (e) {
      debugPrint('QuestWindowArgs: bad args $args: $e');
      return null;
    }
  }
}

QuestWindowArgs? questWindowArgs;

/// True in a secondary display panel (not the main app window).
bool get isQuestDisplayWindow => questWindowArgs != null;

/// Multi-window mode: explicit local option wins; otherwise on for Meta Quest.
bool isQuestMultiWindowEnabled() {
  if (!isAndroid || isQuestDisplayWindow) return false;
  final v = bind.mainGetLocalOption(key: kOptionQuestMultiWindow);
  if (v == 'Y') return true;
  if (v == 'N') return false;
  return isQuestDevice;
}

class _QuestWindowsState {
  // display index -> ui session id of its panel
  final Map<int, String> windows = {};
  // displays already handled (shown in the main panel, opened, or closed by the user)
  final Set<int> handled = {};
  int? mainDisplay;
  String peerId = '';

  void reset() {
    windows.clear();
    handled.clear();
    mainDisplay = null;
    peerId = '';
  }
}

final _state = _QuestWindowsState();

/// Number of display panels currently open (main window excluded).
int get questOpenDisplayWindows => _state.windows.length;

/// Main window: make sure every remote display has a panel.
/// Returns true if multi-window mode handled the session (so tiled mode must not run).
bool questSyncDisplayWindows(FFI ffi) {
  if (!isQuestMultiWindowEnabled()) return false;
  if (ffi.closed || ffi.connType != ConnType.defaultConn) return false;
  final pi = ffi.ffiModel.pi;
  if (!pi.isSupportMultiUiSession) return false;
  final count = pi.displays.length;
  if (count == 0) return false;

  if (_state.peerId != ffi.id) {
    // New connection.
    _closeAllWindows(ffi);
    _state.peerId = ffi.id;
  }

  // Removed displays: close their panels.
  for (final d in _state.windows.keys.where((d) => d >= count).toList()) {
    _closeWindow(ffi, d, closeActivity: true);
  }
  _state.handled.removeWhere((d) => d >= count);
  if (count < 2) {
    return true;
  }

  // The main panel shows a single display (never "All" in this mode).
  var cur = pi.currentDisplay;
  if (cur == kAllDisplayValue || cur < 0 || cur >= count) {
    cur = (pi.primaryDisplay >= 0 && pi.primaryDisplay < count)
        ? pi.primaryDisplay
        : 0;
    openMonitorInTheSameTab(cur, ffi, pi,
        updateCursorPos: false, recordSelection: false);
  } else if (_state.mainDisplay != cur) {
    // Register the main ui session's display in the core before other ui sessions
    // join, so the main panel keeps receiving its frames.
    bind.sessionSwitchDisplay(
        isDesktop: false,
        sessionId: ffi.sessionId,
        value: Int32List.fromList([cur]));
  }
  _state.mainDisplay = cur;
  _state.handled.add(cur);
  if (_state.windows.containsKey(cur)) {
    // The main panel switched to a display that had its own panel.
    _closeWindow(ffi, cur, closeActivity: true);
  }

  final cached = ffi.ffiModel.cachedPeerData.toString();
  for (int d = 0; d < count; d++) {
    if (_state.handled.contains(d)) continue;
    _openWindow(ffi, d, cached);
  }
  return true;
}

void _openWindow(FFI ffi, int display, String cached) {
  final sid = Uuid().v4();
  _state.windows[display] = sid;
  _state.handled.add(display);
  debugPrint('QuestMW open display $display, session $sid');
  ffi.invokeMethod('quest_open_display_window', {
    'peer_id': ffi.id,
    'display': display,
    'session_id': sid,
    'cached_data': cached,
    'title': 'RustDesk ${ffi.id} - ${translate('Display')} ${display + 1}',
    'is_quest': isQuestDevice,
  }).then((ok) {
    if (ok != true) {
      debugPrint('QuestMW failed to open display $display');
      _state.windows.remove(display);
    }
  }).catchError((e) {
    debugPrint('QuestMW open display $display error: $e');
    _state.windows.remove(display);
  });
}

void _closeWindow(FFI ffi, int display, {required bool closeActivity}) {
  final sid = _state.windows.remove(display);
  if (sid != null) {
    bind.sessionClose(sessionId: UuidValue(sid));
  }
  if (closeActivity) {
    ffi.invokeMethod('quest_close_display_window', display).catchError((_) => false);
  }
}

void _closeAllWindows(FFI ffi) {
  for (final d in _state.windows.keys.toList()) {
    _closeWindow(ffi, d, closeActivity: false);
  }
  _state.reset();
  if (isAndroid) {
    ffi.invokeMethod('quest_close_display_windows').catchError((_) => false);
  }
}

/// Main window: close every display panel (session closed / mode turned off).
void questCloseAllDisplayWindows(FFI ffi) {
  if (isQuestDisplayWindow) return;
  if (_state.windows.isEmpty && _state.peerId.isEmpty) return;
  _closeAllWindows(ffi);
}

/// Main window: reopen the panels the user closed.
void questReopenDisplayWindows(FFI ffi) {
  if (isQuestDisplayWindow) return;
  _state.handled.removeWhere((d) => !_state.windows.containsKey(d));
  questSyncDisplayWindows(ffi);
}

/// Main window: a display panel was closed (by the user or by us).
/// Called from the android channel handler ("on_quest_window_closed").
void questOnDisplayWindowClosed(FFI ffi, dynamic arguments) {
  try {
    final display = (arguments['display'] as num).toInt();
    final sid = arguments['session_id'] as String? ?? '';
    if (_state.windows[display] == sid) {
      _state.windows.remove(display);
    }
    // Release the ui session of the panel (no-op if already released). The core then
    // stops capturing the display if no other panel uses it.
    if (sid.isNotEmpty) {
      bind.sessionClose(sessionId: UuidValue(sid));
    }
    debugPrint('QuestMW display $display panel closed');
  } catch (e) {
    debugPrint('questOnDisplayWindowClosed: $e');
  }
}
