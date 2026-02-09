# How do NATS FFI callbacks work?

This document explains how the `nats_for_dart` package bridges native C callbacks from the NATS library to Dart's async stream system.

## Table of Contents

- [Overview](#overview)
- [The Challenge](#the-challenge)
- [The Solution](#the-solution)
- [Architecture Components](#architecture-components)
- [The Complete Circle](#the-complete-circle)
- [Code Walkthrough](#code-walkthrough)
- [Memory Management](#memory-management)
- [Common Patterns](#common-patterns)

## Overview

The NATS C library uses callbacks to notify applications about lifecycle events (disconnection, reconnection, closure) and errors. In Dart FFI, bridging these C callbacks to idiomatic Dart async streams requires careful architecture.

## The Challenge

### FFI Callback Constraints

Dart FFI requires callbacks to be **static or top-level functions**. They cannot:
- Be instance methods
- Capture variables from closures
- Access instance state directly

### What We Need

- Multiple `NatsOptions` instances, each with independent event streams
- Users listening to streams: `options.onDisconnected().listen(...)`
- Events routed to the correct instance when C callbacks fire

### The Problem

```dart
// ❌ This doesn't work - FFI callbacks can't be instance methods
class NatsOptions {
  void _onDisconnected(Pointer<natsConnection> nc) {
    // How does this know which instance it belongs to?
  }
}
```

## The Solution

### Three-Layer Architecture

1. **Top-Level Callback Functions**: Static functions that the C library can call
2. **Static Routing Tables**: Maps IDs to stream controllers across all instances
3. **Per-Instance State**: Each instance stores its ID, controller, and callable

### The ID-as-Pointer Trick

```dart
// 1. Generate unique ID
_disconnectedId = _nextId++;  // e.g., 1, 2, 3...

// 2. Pass ID as a pointer to C library
Pointer.fromAddress(_disconnectedId!)  // Convert int to pointer

// 3. C library hands it back in callbacks
void _onDisconnected(Pointer<natsConnection> nc, Pointer<Void> closure) {
  final id = closure.address;  // Pointer address IS the ID!
  final controller = _lifecycleRoutes[id];  // Look up controller
}
```

The integer ID makes a round-trip through the C library as a pointer address, enabling routing without the C library knowing anything about Dart objects.

## Architecture Components

### 1. Static Routing Tables

Located at the class level in `NatsOptions`:

```dart
static final Map<int, StreamController<void>> _lifecycleRoutes = {};
static final Map<int, StreamController<NatsError>> _errorRoutes = {};
static int _nextId = 1;
```

**Purpose**:
- Shared across ALL `NatsOptions` instances
- Allow top-level callbacks to find the right controller
- Keyed by unique integer IDs

### 2. Per-Instance Callback State

Each `NatsOptions` instance stores:

```dart
// For each event type (disconnected, reconnected, closed, error):
int? _disconnectedId;                    // The unique ID
StreamController<void>? _disconnectedController;  // The Dart stream
NativeCallable<...>? _disconnectedCallable;       // FFI function pointer
```

**Purpose**:
- Track which events this instance has registered
- Store the stream controller that users listen to
- Keep the `NativeCallable` alive (prevents premature garbage collection)

### 3. Top-Level Callback Functions

```dart
void _onDisconnected(Pointer<natsConnection> nc, Pointer<Void> closure) {
  final id = closure.address;
  final controller = NatsOptions._lifecycleRoutes[id];
  if (controller != null && !controller.isClosed) {
    controller.add(null);
  }
}
```

**Purpose**:
- Bridge from C callbacks to Dart
- Extract the ID from the closure pointer
- Look up and notify the appropriate controller

## The Complete Circle

Here's the full event flow from C library to user code:

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. User Setup Phase                                             │
│    • options.onDisconnected() creates StreamController          │
│    • Generates unique ID (e.g., 42)                             │
│    • Registers in _lifecycleRoutes[42] = controller             │
│    • Calls natsOptions_SetDisconnectedCB(fn, Pointer(42))       │
│    • User starts listening: stream.listen(...)                  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. Connection Active                                            │
│    • NATS client communicates with server                       │
│    • C library monitors connection health                       │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. Event Occurs: NATS Server Disconnects                        │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4. C Library Detects Disconnection                             │
│    • Looks up stored callback: _onDisconnected function pointer │
│    • Looks up stored closure pointer: Pointer(42)               │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 5. C Library Invokes Dart Callback                             │
│    _onDisconnected(nc, Pointer(42))                             │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 6. Callback Extracts ID                                         │
│    final id = closure.address  // id = 42                       │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 7. Callback Looks Up Controller                                │
│    final controller = _lifecycleRoutes[42]                      │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 8. Controller Emits Event                                       │
│    controller.add(null)                                         │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 9. Stream Delivers to Listeners                                 │
│    User's .listen() callback executes                           │
│    print('Connection lost!')                                    │
└─────────────────────────────────────────────────────────────────┘
```

### Key Observations

1. **The ID makes a round-trip**: Created in Dart, passed to C as a pointer, returned in callbacks as a pointer address
2. **No Dart objects cross the FFI boundary**: Only primitive types and pointers
3. **The routing table is the bridge**: Connects the stateless callback to the stateful instance

## Memory Management

### Why NativeCallable Must Be Stored

```dart
_disconnectedCallable = NativeCallable<...>.listener(_onDisconnected);
```

**Critical**: The `NativeCallable` must be kept alive as long as the C library might invoke the callback. If it gets garbage collected, the function pointer becomes invalid, leading to crashes.

**Solution**: Store it in an instance field, then explicitly close it during cleanup.

### Cleanup Sequence

When `options.close()` is called:

```dart
Future<void> close() {
  // 1. Remove from routing tables FIRST
  //    (Prevents late-arriving callbacks from accessing closing controllers)
  if (_disconnectedId != null) _lifecycleRoutes.remove(_disconnectedId);

  // 2. Close stream controllers
  //    (Sends done event to listeners)
  final futures = [
    if (_disconnectedController != null) _disconnectedController!.close(),
  ];

  // 3. Close NativeCallables
  //    (Releases function pointers)
  _disconnectedCallable?.close();

  // 4. Destroy native options
  if (_opts != null) {
    _finalizer.detach(this);
    natsOptions_Destroy(_opts!);
    _opts = null;
  }

  return Future.wait(futures);
}
```

**Order matters**: Routing table entries are removed first to prevent race conditions where callbacks fire during shutdown.

## Common Patterns

### Pattern 1: Void Streams

For lifecycle events without data:

```dart
StreamController<void> controller = StreamController<void>.broadcast();
controller.add(null);  // ← null is the sentinel value for void streams
```

Dart requires an explicit value even for `void` streams. `null` is idiomatic.

### Pattern 2: Broadcast Streams

```dart
StreamController<void>.broadcast()
```

Allows multiple listeners to subscribe to the same event stream. Without `.broadcast()`, only one listener would be allowed.

### Pattern 3: Idempotent Registration

```dart
Stream<void> onDisconnected() {
  if (_disconnectedController == null) {
    // Setup code...
  }
  return _disconnectedController!.stream;
}
```

Safe to call multiple times—returns the same stream without re-registering callbacks.

### Pattern 4: Safety Checks in Callbacks

```dart
if (controller != null && !controller.isClosed) {
  controller.add(null);
}
```

Handles edge cases:
- `null` check: Routing table entry might have been removed during cleanup
- `!isClosed`: Controller might be in the process of closing

## Event Types

The same architecture is used for all lifecycle events:

| Event Type   | Callback Function | Stream Type         | Use Case                                  |
| ------------ | ----------------- | ------------------- | ----------------------------------------- |
| Disconnected | `_onDisconnected` | `Stream<void>`      | Connection lost                           |
| Reconnected  | `_onReconnected`  | `Stream<void>`      | Connection re-established                 |
| Closed       | `_onClosed`       | `Stream<void>`      | Connection permanently closed             |
| Error        | `_onError`        | `Stream<NatsError>` | Asynchronous errors (e.g., slow consumer) |

All follow the same three-part state pattern (ID + Controller + Callable) and use the same routing table mechanism.

## Design Benefits

### ✅ Multiple Instances

Each `NatsOptions` instance has independent streams while sharing callback functions efficiently.

### ✅ Type Safety

Dart's type system ensures correct callback signatures and stream types.

### ✅ Resource Efficiency

Callbacks are only set up when requested (lazy initialization), and properly cleaned up when closed.

### ✅ FFI Constraints

Works within FFI's requirement for top-level callback functions while providing instance-specific behavior.

### ✅ Idiomatic Dart

Exposes events as async streams, integrating naturally with Dart's async/await ecosystem.

## Summary

The NATS FFI callback system elegantly bridges C callbacks to Dart streams through:

1. **Static routing tables** that map IDs to stream controllers
2. **Unique IDs passed as pointer addresses** through the C library
3. **Top-level callback functions** that use IDs to route events
4. **Per-instance state** that tracks callbacks and keeps resources alive
5. **Careful cleanup** that prevents race conditions and memory leaks

This architecture demonstrates a common pattern for FFI callback integration and can be adapted for other C libraries with similar callback mechanisms.
