/// Owns a native byte buffer copied from a [Uint8List].
///
/// Empty input yields `nullptr` with `length == 0`; non-empty input allocates
/// via `malloc` and copies the bytes. [free] is a no-op for the empty case,
/// so callers always pair construction with [free] without conditional
/// logic — collapsing the alloc/copy/free trio's empty-data invariant to a
/// single decision site.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

@internal
class NativeBytes {
  final Pointer<Uint8> ptr;
  final int length;
  NativeBytes._(this.ptr, this.length);

  static final _empty = NativeBytes._(nullptr, 0);

  factory NativeBytes.from(Uint8List data) {
    if (data.isEmpty) return _empty;
    final ptr = malloc<Uint8>(data.length);
    ptr.asTypedList(data.length).setAll(0, data);
    return NativeBytes._(ptr, data.length);
  }

  void free() {
    if (length > 0) malloc.free(ptr);
  }
}
