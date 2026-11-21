# Swift concepts used in EVA

Read this alongside a small production file and its tests. The examples explain repository conventions; the compiler and the actual declaration determine the precise isolation and ownership rules.

## Values, references and protocols

A `struct` is a value: assigning it creates an independent logical value. Arrays use copy-on-write, so assignment need not immediately duplicate all samples. A struct containing a class reference still shares that referenced object when copied. A `class` is a reference: two variables can refer to the same mutable object. `ChannelSet` is a value; `RecordingStore` is shared state for one recording window.

`struct ChannelSet: Identifiable, Codable, Hashable, Sendable` lists capabilities. `Identifiable` supplies an identity for UI lists, `Codable` supports encoding/decoding, `Hashable` permits set/dictionary use, and `Sendable` participates in Swift's checks for transferring values across concurrency boundaries. These names do not make every operation on a type automatic or thread-safe.

`enum` cases represent alternatives. An exhaustive `switch` on `LatestOnlyRunner.Outcome` forces the caller to handle completed, superseded and cancelled runs. Associated values, such as `.completed(result)`, carry data with a case.

## Missing values and early exits

`MFFSignalData?` may contain a signal or `nil`. `guard let signal else { return }` unwraps it and keeps the successful path unindented. `signal.data.first?.count ?? 0` asks for the first channel's sample count, using zero when there is no channel. That fallback is a policy decision worth documenting.

A `throws` function reports failure through an error. `try` propagates it; `do/catch` handles it. `try?` converts failure to `nil`, which can hide the reason. Use it only when the caller intentionally treats failure as absence. `Result?`, zero and an empty array can have different meanings; read each API's contract.

## Closures, collection operations and key paths

A closure is an inline function. In `indices.filter { $0 >= 0 }`, `$0` is the current index. A short expression is readable here; name closure arguments when several values or nested closures make `$0` ambiguous.

`map` transforms each item, `filter` keeps selected items, and `reduce` accumulates a result. A chain can be concise, but intermediate names help when the stages have different scientific meanings. `inout` marks a parameter that may be modified by the callee; callers pass it with `&`.

A capture list such as `[epoching]` captures that value when the closure is created. If it is a class, the captured value is still a reference to the object, not a frozen snapshot of its fields. Explicit immutable run-input structs are used when a worker needs stable inputs.

A key path such as `\.trialIndex` identifies a property for a sort, mapping or binding. It is not a string. `some View` hides a concrete return type chosen by the implementation. `any ComplexCoefficientProvider` stores a value whose concrete conforming type can vary at runtime.

## SwiftUI state and identity

| Declaration | Meaning in this project |
| --- | --- |
| `@State` | Storage owned by a view/scene identity; it survives rebuilding the view value. It can hold an observable reference. |
| `@Binding` | An editable connection to storage owned elsewhere. The child does not own a separate copy. |
| `@Observable` | Tracks reads and changes to a model's properties so dependent views can update. It does not itself define actor isolation. |
| `@Bindable` | Enables bindings to an observable model; the property's `$` projection exposes those bindings. |
| `@Environment` | Reads a dependency supplied by an ancestor or scene. Missing required dependencies can fail at runtime. |
| `@ObservationIgnored` | Excludes a property from observation, often for implementation machinery such as a task or cache. |

A view's `body` describes UI for its current inputs. Rebuilding a view should not accidentally perform a processing commit. A standalone child `View` provides a useful dependency boundary; moving a method to `extension WaveformView` keeps the same owner and dependencies.

## Concurrency and stale results

`async` permits suspension; `await` marks a potential suspension. Neither promises a new thread. `@MainActor` isolates access to the UI actor. Work must cross to an appropriate worker explicitly if it is expensive. `nonisolated` declares that the operation is outside its enclosing/default actor isolation; it does not automatically start background work.

Cancellation is cooperative. A cancelled task may finish a calculation and return a value. A newer request may also complete before an older one. Consequently, cancellation and ownership checks are separate responsibilities.

`LatestOnlyRunner` demonstrates the protocol:

| Event | Owner | Allowed action |
| --- | --- | --- |
| Run A starts | A | Compute its snapshot. |
| Run B starts while A is suspended | B | B now owns publication and shared progress. |
| A finishes | B | A reports superseded and leaves shared UI state alone. |
| B finishes | B | Publish B, or clean up if B was cancelled without a successor. |

`@Sendable` constrains closure captures. `@unchecked Sendable` is a promise made by the implementer; a comment should explain the synchronization or immutability that makes the promise valid. Do not add it merely to silence a diagnostic.

## Numerical Swift

`0..<count` excludes its upper endpoint; `0...count` includes it. Choosing the wrong interval changes array bounds and event timing. `Float` and `Double` differ in precision; conversions and summation order can change numerical results. `&+` and `&*` are wrapping integer operations, intentionally used by the deterministic random generator.

`withUnsafeBytes` and related APIs borrow memory for a closure. Do not let a pointer outlive the borrow. Accelerate and Metal routines also need an explicit element type, shape and memory layout; see [commenting numerical code](commenting.md).
