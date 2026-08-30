import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Thin Dart binding for the stable Rust C ABI.
///
/// Native libraries are supplied by release packaging, not downloaded at
/// runtime. This keeps model and personal data inside the host app sandbox.
final class NativeEngine {
  NativeEngine._(this._library, this._handle);

  final DynamicLibrary _library;
  final Pointer<Void> _handle;

  static NativeEngine open(String dataDirectory) {
    final library = Platform.isAndroid
        ? DynamicLibrary.open('liblocal_flow_ffi.so')
        : DynamicLibrary.process();
    final create = library
        .lookupFunction<
          Pointer<Void> Function(Pointer<Utf8>),
          Pointer<Void> Function(Pointer<Utf8>)
        >('lf_engine_new');
    final directory = dataDirectory.toNativeUtf8();
    try {
      final handle = create(directory);
      if (handle == nullptr) {
        throw StateError('Native engine rejected application data directory.');
      }
      return NativeEngine._(library, handle);
    } finally {
      calloc.free(directory);
    }
  }

  String loadModels() => _callEngineString('lf_engine_load_models');

  String downloadWhisper() => _callDownload('lf_engine_download_whisper');

  String downloadQwen() => _callDownload('lf_engine_download_qwen');

  String hubSnapshotJson() => _callEngineString('lf_engine_hub_snapshot_json');

  String personalizationJson() =>
      _callEngineString('lf_engine_personalization_json');

  String savePersonalizationJson(String json) =>
      _callEngineStringWithArg('lf_engine_save_personalization_json', json);

  String deleteScratchNote(String id) =>
      _callEngineStringWithArg('lf_engine_delete_scratch_note', id);

  String addScratchNote(String text) =>
      _callEngineStringWithArg('lf_engine_add_scratch_note', text);

  String learnFromEdit(String pasted, String edited) =>
      _callEngineStringWithTwoArgs('lf_engine_learn_from_edit', pasted, edited);

  String suggestLearnJson(String pasted, String edited) =>
      _callEngineStringWithTwoArgs(
        'lf_engine_suggest_learn_json',
        pasted,
        edited,
      );

  bool undoLearned(String heard) {
    final call = _library
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Utf8>),
          int Function(Pointer<Void>, Pointer<Utf8>)
        >('lf_engine_undo_learned');
    final arg = heard.toNativeUtf8();
    try {
      return call(_handle, arg) != 0;
    } finally {
      calloc.free(arg);
    }
  }

  void setDestinationScratch(bool scratch) {
    final call = _library
        .lookupFunction<
          Void Function(Pointer<Void>, Int32),
          void Function(Pointer<Void>, int)
        >('lf_engine_set_destination_scratch');
    call(_handle, scratch ? 1 : 0);
  }

  /// Parse hub snapshot into a plain map (empty on failure).
  Map<String, dynamic> hubSnapshot() {
    final raw = hubSnapshotJson();
    if (raw.startsWith('error:')) {
      return {};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return {};
  }

  Map<String, dynamic> personalization() {
    final raw = personalizationJson();
    if (raw.startsWith('error:')) {
      return {'dictionary': [], 'snippets': [], 'cleanup_enabled': true};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return {'dictionary': [], 'snippets': [], 'cleanup_enabled': true};
  }

  String _callEngineString(String symbol) {
    final call = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)
        >(symbol);
    return _takeString(call(_handle));
  }

  String _callEngineStringWithArg(String symbol, String arg) {
    final call = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
        >(symbol);
    final native = arg.toNativeUtf8();
    try {
      return _takeString(call(_handle, native));
    } finally {
      calloc.free(native);
    }
  }

  String _callEngineStringWithTwoArgs(String symbol, String a, String b) {
    final call = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
        >(symbol);
    final na = a.toNativeUtf8();
    final nb = b.toNativeUtf8();
    try {
      return _takeString(call(_handle, na, nb));
    } finally {
      calloc.free(na);
      calloc.free(nb);
    }
  }

  String _callDownload(String symbol) {
    final call = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)
        >(symbol);
    return _takeString(call(_handle, nullptr, nullptr));
  }

  String _takeString(Pointer<Utf8> value) {
    if (value == nullptr) {
      return 'Native engine returned no result.';
    }
    try {
      return value.toDartString();
    } finally {
      _library.lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)
      >('lf_string_free')(value);
    }
  }

  void dispose() {
    _library.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)
    >('lf_engine_free')(_handle);
  }
}
