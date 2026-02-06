import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'jetstream_context.dart';
import 'nats_bindings.g.dart';
import 'nats_bindings_loader.dart';
import 'nats_exceptions.dart';

// ── Dart-friendly KV data classes ───────────────────────────────────────

/// Configuration for creating a KeyValue bucket.
@immutable
final class KvConfig {
  final String bucket;
  final String? description;
  final int? maxValueSize;
  final int history;
  final Duration? ttl;
  final int? maxBytes;
  final jsStorageType storageType;
  final int replicas;

  const KvConfig({
    required this.bucket,
    this.description,
    this.maxValueSize,
    this.history = 1,
    this.ttl,
    this.maxBytes,
    this.storageType = jsStorageType.js_FileStorage,
    this.replicas = 1,
  });
}

/// An eagerly-copied KeyValue entry.
@immutable
final class KvEntry {
  /// The bucket this entry belongs to.
  final String bucket;

  /// The key.
  final String key;

  /// The raw value bytes.
  final Uint8List value;

  /// The revision number.
  final int revision;

  /// Creation timestamp (nanoseconds since epoch).
  final int created;

  /// The operation that produced this entry.
  final kvOperation operation;

  /// Number of deltas from the latest revision.
  final int delta;

  KvEntry._({
    required this.bucket,
    required this.key,
    required this.value,
    required this.revision,
    required this.created,
    required this.operation,
    required this.delta,
  });

  /// Convenience getter that decodes [value] as a UTF-8 string.
  String get valueAsString => String.fromCharCodes(value);

  @override
  String toString() =>
      'KvEntry(key: $key, revision: $revision, '
      'operation: ${operation.name}, value: $valueAsString)';

  /// Eagerly copies fields from a native `kvEntry` pointer without
  /// destroying it. Caller is responsible for native memory cleanup.
  static KvEntry _copyFromNativePtr(Pointer<kvEntry> entryPtr) {
    final b = bindings;
    final bucket = b.kvEntry_Bucket(entryPtr).cast<Utf8>().toDartString();
    final key = b.kvEntry_Key(entryPtr).cast<Utf8>().toDartString();
    final valueLen = b.kvEntry_ValueLen(entryPtr);
    final valuePtr = b.kvEntry_Value(entryPtr);
    final value = valueLen > 0
        ? Uint8List.fromList(valuePtr.cast<Uint8>().asTypedList(valueLen))
        : Uint8List(0);
    final revision = b.kvEntry_Revision(entryPtr);
    final created = b.kvEntry_Created(entryPtr);
    final operation = kvOperation.fromValue(b.kvEntry_Operation(entryPtr).value);
    final delta = b.kvEntry_Delta(entryPtr);

    return KvEntry._(
      bucket: bucket,
      key: key,
      value: value,
      revision: revision,
      created: created,
      operation: operation,
      delta: delta,
    );
  }

  /// Creates a [KvEntry] by eagerly copying fields from a native `kvEntry`
  /// pointer, then destroying the native entry.
  factory KvEntry._fromNativePtr(Pointer<kvEntry> entryPtr) {
    final entry = _copyFromNativePtr(entryPtr);
    bindings.kvEntry_Destroy(entryPtr);
    return entry;
  }
}

// ── KeyValueStore ───────────────────────────────────────────────────────

/// A KeyValue store backed by JetStream.
///
/// Obtain via [JetStreamContext.createKeyValue] or
/// [JetStreamContext.keyValue].
///
/// Must be closed via [close] when no longer needed. A [NativeFinalizer]
/// serves as a safety net if [close] is not called, but relying on GC
/// for timely cleanup is not recommended.
final class KeyValueStore implements Finalizable {
  static final _finalizer = NativeFinalizer(
    natsLib.lookup('kvStore_Destroy'),
  );

  Pointer<kvStore>? _kv;
  bool _closed = false;
  final Set<StreamController<KvEntry>> _activeWatchers = {};

  KeyValueStore._(this._kv) {
    _finalizer.attach(this, _kv!.cast(), detach: this);
  }

  /// Creates a new KeyValue bucket.
  factory KeyValueStore.create(JetStreamContext js, KvConfig config) {
    final b = bindings;
    final kvPtrPtr = calloc<Pointer<kvStore>>();
    final cfgPtr = calloc<kvConfig>();
    final nativeStrings = <Pointer<Utf8>>[];
    try {
      checkStatus(b.kvConfig_Init(cfgPtr), 'kvConfig_Init');

      final bucketNative = config.bucket.toNativeUtf8();
      nativeStrings.add(bucketNative);
      cfgPtr.ref.Bucket = bucketNative.cast();

      if (config.description != null) {
        final descNative = config.description!.toNativeUtf8();
        nativeStrings.add(descNative);
        cfgPtr.ref.Description = descNative.cast();
      }
      if (config.maxValueSize != null) {
        cfgPtr.ref.MaxValueSize = config.maxValueSize!;
      }
      cfgPtr.ref.History = config.history;
      if (config.ttl != null) {
        // Safe for durations up to ~292 years (2^63 nanoseconds).
        cfgPtr.ref.TTL = config.ttl!.inMicroseconds * 1000;
      }
      if (config.maxBytes != null) {
        cfgPtr.ref.MaxBytes = config.maxBytes!;
      }
      cfgPtr.ref.StorageTypeAsInt = config.storageType.value;
      cfgPtr.ref.Replicas = config.replicas;

      checkStatus(
        b.js_CreateKeyValue(kvPtrPtr, js.nativePtr, cfgPtr),
        'js_CreateKeyValue',
      );
      return KeyValueStore._(kvPtrPtr.value);
    } finally {
      for (final ptr in nativeStrings) {
        calloc.free(ptr);
      }
      calloc.free(cfgPtr);
      calloc.free(kvPtrPtr);
    }
  }

  /// Opens an existing KeyValue bucket by name.
  factory KeyValueStore.open(JetStreamContext js, String bucket) {
    final b = bindings;
    final kvPtrPtr = calloc<Pointer<kvStore>>();
    final bucketNative = bucket.toNativeUtf8();
    try {
      checkStatus(
        b.js_KeyValue(kvPtrPtr, js.nativePtr, bucketNative.cast()),
        'js_KeyValue',
      );
      return KeyValueStore._(kvPtrPtr.value);
    } finally {
      calloc.free(bucketNative);
      calloc.free(kvPtrPtr);
    }
  }

  /// Returns the bucket name.
  String get bucket {
    _ensureOpen();
    return bindings.kvStore_Bucket(_kv!).cast<Utf8>().toDartString();
  }

  // ── CRUD operations ─────────────────────────────────────────────────

  /// Puts a value for the given key. Returns the new revision number.
  int put(String key, Uint8List value) {
    _ensureOpen();
    final b = bindings;
    final keyNative = key.toNativeUtf8();
    final dataPtr = malloc<Uint8>(value.length);
    final revPtr = calloc<Uint64>();
    try {
      dataPtr.asTypedList(value.length).setAll(0, value);
      checkStatus(
        b.kvStore_Put(revPtr, _kv!, keyNative.cast(), dataPtr.cast(),
            value.length),
        'kvStore_Put',
      );
      return revPtr.value;
    } finally {
      calloc.free(revPtr);
      malloc.free(dataPtr);
      calloc.free(keyNative);
    }
  }

  /// Puts a string value for the given key. Returns the new revision number.
  int putString(String key, String value) {
    _ensureOpen();
    final b = bindings;
    final keyNative = key.toNativeUtf8();
    final valueNative = value.toNativeUtf8();
    final revPtr = calloc<Uint64>();
    try {
      checkStatus(
        b.kvStore_PutString(
          revPtr,
          _kv!,
          keyNative.cast(),
          valueNative.cast(),
        ),
        'kvStore_PutString',
      );
      return revPtr.value;
    } finally {
      calloc.free(revPtr);
      calloc.free(valueNative);
      calloc.free(keyNative);
    }
  }

  /// Gets the latest entry for the given key, or `null` if not found.
  KvEntry? get(String key) {
    _ensureOpen();
    final b = bindings;
    final keyNative = key.toNativeUtf8();
    final entryPtrPtr = calloc<Pointer<kvEntry>>();
    try {
      final status =
          b.kvStore_Get(entryPtrPtr, _kv!, keyNative.cast());
      if (status == natsStatus.NATS_NOT_FOUND) return null;
      checkStatus(status, 'kvStore_Get');
      return KvEntry._fromNativePtr(entryPtrPtr.value);
    } finally {
      calloc.free(entryPtrPtr);
      calloc.free(keyNative);
    }
  }

  /// Creates a key only if it doesn't exist. Returns the revision number.
  ///
  /// Throws [NatsException] if the key already exists.
  int create(String key, Uint8List value) {
    _ensureOpen();
    final b = bindings;
    final keyNative = key.toNativeUtf8();
    final dataPtr = malloc<Uint8>(value.length);
    final revPtr = calloc<Uint64>();
    try {
      dataPtr.asTypedList(value.length).setAll(0, value);
      checkStatus(
        b.kvStore_Create(
          revPtr,
          _kv!,
          keyNative.cast(),
          dataPtr.cast(),
          value.length,
        ),
        'kvStore_Create',
      );
      return revPtr.value;
    } finally {
      calloc.free(revPtr);
      malloc.free(dataPtr);
      calloc.free(keyNative);
    }
  }

  /// Creates a key with a string value only if it doesn't exist.
  int createString(String key, String value) {
    _ensureOpen();
    final b = bindings;
    final keyNative = key.toNativeUtf8();
    final valueNative = value.toNativeUtf8();
    final revPtr = calloc<Uint64>();
    try {
      checkStatus(
        b.kvStore_CreateString(
          revPtr,
          _kv!,
          keyNative.cast(),
          valueNative.cast(),
        ),
        'kvStore_CreateString',
      );
      return revPtr.value;
    } finally {
      calloc.free(revPtr);
      calloc.free(valueNative);
      calloc.free(keyNative);
    }
  }

  /// Updates a key only if the current revision matches [lastRevision].
  /// Returns the new revision number.
  ///
  /// Throws [NatsException] if the revision has changed (optimistic
  /// concurrency check).
  int update(String key, Uint8List value, int lastRevision) {
    _ensureOpen();
    final b = bindings;
    final keyNative = key.toNativeUtf8();
    final dataPtr = malloc<Uint8>(value.length);
    final revPtr = calloc<Uint64>();
    try {
      dataPtr.asTypedList(value.length).setAll(0, value);
      checkStatus(
        b.kvStore_Update(
          revPtr,
          _kv!,
          keyNative.cast(),
          dataPtr.cast(),
          value.length,
          lastRevision,
        ),
        'kvStore_Update',
      );
      return revPtr.value;
    } finally {
      calloc.free(revPtr);
      malloc.free(dataPtr);
      calloc.free(keyNative);
    }
  }

  /// Updates a key with a string value, with optimistic concurrency.
  int updateString(String key, String value, int lastRevision) {
    _ensureOpen();
    final b = bindings;
    final keyNative = key.toNativeUtf8();
    final valueNative = value.toNativeUtf8();
    final revPtr = calloc<Uint64>();
    try {
      checkStatus(
        b.kvStore_UpdateString(
          revPtr,
          _kv!,
          keyNative.cast(),
          valueNative.cast(),
          lastRevision,
        ),
        'kvStore_UpdateString',
      );
      return revPtr.value;
    } finally {
      calloc.free(revPtr);
      calloc.free(valueNative);
      calloc.free(keyNative);
    }
  }

  /// Soft-deletes the key (adds a delete marker).
  void delete(String key) {
    _ensureOpen();
    final b = bindings;
    final keyNative = key.toNativeUtf8();
    try {
      checkStatus(
        b.kvStore_Delete(_kv!, keyNative.cast()),
        'kvStore_Delete',
      );
    } finally {
      calloc.free(keyNative);
    }
  }

  /// Purges all revisions of a key.
  void purge(String key) {
    _ensureOpen();
    final b = bindings;
    final keyNative = key.toNativeUtf8();
    try {
      checkStatus(
        b.kvStore_Purge(_kv!, keyNative.cast(), nullptr),
        'kvStore_Purge',
      );
    } finally {
      calloc.free(keyNative);
    }
  }

  // ── List operations ─────────────────────────────────────────────────

  /// Returns all keys in this bucket.
  List<String> keys() {
    _ensureOpen();
    final b = bindings;
    final keysList = calloc<kvKeysList>();
    try {
      checkStatus(
        b.kvStore_Keys(keysList, _kv!, nullptr),
        'kvStore_Keys',
      );
      final result = <String>[];
      for (var i = 0; i < keysList.ref.Count; i++) {
        result.add(keysList.ref.Keys[i].cast<Utf8>().toDartString());
      }
      b.kvKeysList_Destroy(keysList);
      return result;
    } finally {
      calloc.free(keysList);
    }
  }

  /// Returns all revisions of a key (most recent first).
  List<KvEntry> history(String key) {
    _ensureOpen();
    final b = bindings;
    final keyNative = key.toNativeUtf8();
    final entryList = calloc<kvEntryList>();
    try {
      checkStatus(
        b.kvStore_History(entryList, _kv!, keyNative.cast(), nullptr),
        'kvStore_History',
      );
      final result = <KvEntry>[];
      for (var i = 0; i < entryList.ref.Count; i++) {
        result.add(KvEntry._copyFromNativePtr(entryList.ref.Entries[i]));
      }
      // Destroys all entries and frees the Entries array. The kvEntryList
      // struct itself is freed in the finally block (calloc'd by us).
      b.kvEntryList_Destroy(entryList);
      return result;
    } finally {
      calloc.free(entryList);
      calloc.free(keyNative);
    }
  }

  // ── Watch ───────────────────────────────────────────────────────────

  /// Watches for changes on keys matching [keyPattern].
  ///
  /// Returns a stream of [KvEntry] updates. The stream is backed by a
  /// polling loop on a separate microtask. Cancel the subscription to
  /// stop watching.
  Stream<KvEntry> watch(String keyPattern) {
    _ensureOpen();
    return _createWatchStream((b, watcherPtrPtr, watchOpts) {
      final keyNative = keyPattern.toNativeUtf8();
      try {
        return b.kvStore_Watch(
          watcherPtrPtr,
          _kv!,
          keyNative.cast(),
          watchOpts,
        );
      } finally {
        calloc.free(keyNative);
      }
    });
  }

  /// Watches for changes on all keys in this bucket.
  Stream<KvEntry> watchAll() {
    _ensureOpen();
    return _createWatchStream((b, watcherPtrPtr, watchOpts) {
      return b.kvStore_WatchAll(watcherPtrPtr, _kv!, watchOpts);
    });
  }

  Stream<KvEntry> _createWatchStream(
    natsStatus Function(
      NatsBindings b,
      Pointer<Pointer<kvWatcher>> watcherPtrPtr,
      Pointer<kvWatchOptions> watchOpts,
    ) createWatcher,
  ) {
    final b = bindings;
    final watcherPtrPtr = calloc<Pointer<kvWatcher>>();
    final watchOpts = calloc<kvWatchOptions>();

    try {
      checkStatus(b.kvWatchOptions_Init(watchOpts), 'kvWatchOptions_Init');
      final status = createWatcher(b, watcherPtrPtr, watchOpts);
      checkStatus(status, 'kvStore_Watch');
    } catch (e) {
      calloc.free(watchOpts);
      calloc.free(watcherPtrPtr);
      rethrow;
    }

    final watcherPtr = watcherPtrPtr.value;
    calloc.free(watchOpts);
    calloc.free(watcherPtrPtr);

    late StreamController<KvEntry> controller;
    Timer? pollTimer;

    controller = StreamController<KvEntry>(
      onListen: () {
        pollTimer = Timer.periodic(
          const Duration(milliseconds: 50),
          (_) => _pollWatcher(b, watcherPtr, controller),
        );
      },
      onCancel: () {
        _activeWatchers.remove(controller);
        pollTimer?.cancel();
        b.kvWatcher_Stop(watcherPtr);
        b.kvWatcher_Destroy(watcherPtr);
      },
    );
    _activeWatchers.add(controller);

    return controller.stream;
  }

  void _pollWatcher(
    NatsBindings b,
    Pointer<kvWatcher> watcher,
    StreamController<KvEntry> controller,
  ) {
    if (controller.isClosed) return;

    // Drain all available entries in a loop with a 1ms timeout per call.
    // In the NATS C library, timeout=0 means "wait forever" (blocking),
    // so we use 1ms for a near-immediate return when no entries are ready.
    while (!controller.isClosed) {
      final entryPtrPtr = calloc<Pointer<kvEntry>>();
      try {
        final status = b.kvWatcher_Next(entryPtrPtr, watcher, 1);
        if (status == natsStatus.NATS_TIMEOUT) return;
        if (status != natsStatus.NATS_OK) {
          controller.addError(NatsException(status, 'kvWatcher_Next'));
          controller.close();
          return;
        }
        if (entryPtrPtr.value != nullptr) {
          controller.add(KvEntry._fromNativePtr(entryPtrPtr.value));
        } else {
          return;
        }
      } finally {
        calloc.free(entryPtrPtr);
      }
    }
  }

  // ── Cleanup ─────────────────────────────────────────────────────────

  /// Destroys this KeyValue store handle.
  ///
  /// Cancels all active watch streams before destroying the native handle.
  void close() {
    if (_closed) return;
    _closed = true;
    // Cancel all active watchers before destroying the KV store.
    // Use .toList() since onCancel removes from the set during iteration.
    for (final watcher in _activeWatchers.toList()) {
      watcher.close();
    }
    _activeWatchers.clear();
    if (_kv != null) {
      _finalizer.detach(this);
      bindings.kvStore_Destroy(_kv!);
      _kv = null;
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('KeyValueStore is already closed');
  }
}

/// Extension on [JetStreamContext] for KeyValue store operations.
extension JetStreamKeyValue on JetStreamContext {
  /// Creates a new KeyValue bucket with the given configuration.
  KeyValueStore createKeyValue(KvConfig config) {
    return KeyValueStore.create(this, config);
  }

  /// Opens an existing KeyValue bucket by name.
  KeyValueStore keyValue(String bucket) {
    return KeyValueStore.open(this, bucket);
  }

  /// Deletes a KeyValue bucket.
  void deleteKeyValue(String bucket) {
    final b = bindings;
    final bucketNative = bucket.toNativeUtf8();
    try {
      checkStatus(
        b.js_DeleteKeyValue(nativePtr, bucketNative.cast()),
        'js_DeleteKeyValue',
      );
    } finally {
      calloc.free(bucketNative);
    }
  }
}
