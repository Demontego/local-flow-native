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

  String _callEngineString(String symbol) {
    final call = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)
        >(symbol);
    return _takeString(call(_handle));
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
