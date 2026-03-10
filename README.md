# The `CustomAsyncPublisher` API

## Full Code

```swift
import SwiftUI
import Combine

struct CustomAsyncPublisher<P: Publisher>: AsyncSequence {
    
    typealias AsyncIterator = Iterator
    typealias Element = P.Output
    private let publisher: P
    
    struct Iterator: AsyncIteratorProtocol {
        
        typealias Element = CustomAsyncPublisher.Element
        typealias Failure = Never
        private let publisher: P
        
        actor CustomAsyncStream {
            
            var buffer: Buffer = Buffer()
            var cancellable: AnyCancellable?
            var continuation: CheckedContinuation<Element?, Never>?
            var isEmissionCompleted = false
            
            func addSubscriber(publisher: P) {
                self.cancellable = publisher.sink { _ in
                    // end the sequence
                    self.finish()
                } receiveValue: { emittedValue in
                    // push value onto buffer
                    self.push(emittedValue)
                }
            }
            
            func push(_ value: Element) {
                if let continuation = self.continuation {
                    
                    /**
                     If a continuation exists, it means the async sequence is awaiting
                     on the next value
                     In such a case, we want to directly resume the continuation returning the
                     emitted value from the publisher
                    
                     We nullify the continuation, which signals we have no longer a continuation
                     to await on being resumed.
                     */
                     
                    self.continuation = nil
                    
                    // We resume the continuation we were awaiting on
                    continuation.resume(returning: value)
                } else {
                    
                    /**
                     If a continuation does not exist, it means that the sequence is not waiting on
                     the next value, but pulling from the buffer, and doing some work on the buffered value.
                     In such a case, we want to push values onto the buffer queue in order to avoid data loss.
                     */
                    
                    self.buffer.enqueue(value)
                }
            }
            
            func finish() {
                
                self.isEmissionCompleted = true
                
                if let continuation = self.continuation {
                    
                    /**
                     If the async sequence is awaiting for the next value but the publisher
                     emits signal of completion, we want to end the sequence, which
                     is done by returning nil from the continuation
                     */
                     
                    
                    // We nullify the continuation, which signals we no longer have a continuation to await on.
                    self.continuation = nil
                    
                    // Signals the async sequence is done awaiting on the next value
                    continuation.resume(returning: nil)
                }
            }
            
            func pull() async -> Element? {
                
                if !buffer.isEmpty {
                    // Pull from the buffer if it's not empty
                    let value = buffer.dequeue()
                    return value
                } else if isEmissionCompleted {
                    // If the buffer is empty and emission completed, we want to end the async sequence
                    return nil
                }
                
                /**
                 In case the buffer is empty and the publisher is not done yet, we need to await on new
                 published values to come (either a publisher completion
                 or received value).
                 */
                 
                let value = await withCheckedContinuation { (cont: CheckedContinuation<Element?, Never>) in
                    
                    /**
                     We store the continuation to resume it later when the we finally
                     get a value emitted from the publisher
                     */
                     
                    self.continuation = cont
                }
                
                return value
            }
        }
        
        private let customAsyncStream = CustomAsyncStream()
        
        init(publisher: P) {
            self.publisher = publisher
            Task(operation: subscribeToPublisher)
        }
        
        func subscribeToPublisher() async throws {
            await self.customAsyncStream.addSubscriber(publisher: publisher)
        }
        
        func next() async -> Element? {
            // Pull values from the stream when available
            return await self.customAsyncStream.pull()
        }
    }
    
    init(publisher: P) {
        self.publisher = publisher
    }
    
    func makeAsyncIterator() -> Iterator {
        return Iterator(publisher: self.publisher)
    }
}

extension CustomAsyncPublisher.Iterator.CustomAsyncStream {
    
    typealias BufferNodeValue = CustomAsyncPublisher.Iterator.Element
    
    class BufferNode {
        
        var value: BufferNodeValue
        var next: BufferNode?
        
        init(_ value: BufferNodeValue) {
            self.value = value
        }
    }
    
    class Buffer {
        
        var head: BufferNode?
        var tail: BufferNode?
        
        var isEmpty: Bool {
            return self.head == nil
        }
        
        @discardableResult
        func enqueue(_ value: BufferNodeValue) -> BufferNode {
            
            let newNode = BufferNode(value)
            
            if self.isEmpty {
                head = newNode
                return newNode
            }
            
            self.tail?.next = newNode
            self.tail = newNode
            
            return newNode
        }
        
        @discardableResult
        func dequeue() -> BufferNodeValue? {
            
            if self.isEmpty {
                return nil
            }
            
            let dequeuedNode = self.head
            
            self.head = self.head?.next
            dequeuedNode?.next = nil
            
            return dequeuedNode?.value
        }
    }
}

extension Publisher {
    var customAsyncPublisher: CustomAsyncPublisher<Self> {
        return CustomAsyncPublisher(publisher: self)
    }
}
```

## Introduction

The `CustomAsyncPublisher` API is inspired by my love for the `Combine` framework and how Apple
conveniently provided us with an asynchronous interface to our classic Combine's `Publisher`'s in order
to perfectly integrate what is a synchronous, reactive Combine codebase into asynchronous code that
allows us to write modern Swift Concurrency code with async/await in order to await for any Publisher's
emitted data over time.

In other words, Apple provides us with the native `AsyncPublisher`, which is a wrapper type to our published data's
associated publisher (`Published<Data>.Publisher`), and providing us publisher's emitted values over time
asynchronously as an asynchronous sequence, making it possible to await for such published values every time
our published data gets updated.

This way, not only do we steer clear of writing long Combine pipelines when subscribing to any of our
published data's publishers, but it also allows us to integrate Combine code into codebase written
using modern Swift Concurrency.

I created this `CustomAsyncPublisher` in order to mimic the Apple's `AsyncPublisher` API. I use reverse engineering
to deduce how Apple engineers were able to construct it and make it work the way it does.

This does not ascertain anything regarding `AsyncPublisher` in terms of how exactly functions under the hood, but it
provides a good approximation about its inner workings.

## Briefly on Building an Asynchronous Stream using the `AsyncSequence` Protocol

Since the `AsyncPublisher` is an `AsyncSequence`, I had my `CustomAsyncPublisher` conform to the `AsyncSequence` protocol.

Remember that, when we have a type conform to `AsyncSequence`, the protocol requires
that the conforming type implement two types — the associated types of that `AsyncSequence` protocol; namely,
the `AsyncIterator` type, which is the _meat_ of our asynchronous sequence, `CustomAsyncPublisher`, and
the so cared values to be awaiting on, `Element`.

In such a scenario, since we are building an asynchronous wrapper around a Combine's `Publisher`, we want
to make sure that the type of `Element`'s being yielded from the asynchronous stream are the ones
emitted from our wrapped publisher; namely, the values of type `Publisher.Output`.

Look at the `Iterator`, or better yet, any type conforming to the `AsyncIteratorProtocol` as the actual engine that produces elements over time, and asynchronously dispatch them to the asynchronous stream when they are ready.

In our specific case, we can tap into the functionality that provides the `next` element to be produces in the
sequence when it's ready. Well, in our case, the `next` element to be produced is the very last publish to
the published data being emitted by the published data's associated publisher — `Published<Data>.Publisher`.

That gives us the possibility to use an async for loop, `for await Element in AsyncSequence`, to await elements
from the async iterator; specifically, every time the async for loop runs, it calls our implemented async `next()`
method, which will suspend/await until the next value is ready — in our case, until the publisher for that
published data emits the next published value.

That `next()` method is the one required by the `AsyncIteratorProtocol`, which is `async` and returns
the `Element` type required by the `AsyncIteratorProtocol`, which we defined to be of type `CustomAsyncPublisher.Element`,
which, in turn, refers to the type of output we get from the publisher via generics `P.Output`, where P conforms
to the `Publisher` protocol.

## The Nested Struct `Iterator` Concrete Type Implementation as an `AsyncIteratorProtocol`-Conforming Type

The following is the implementation for our iterator defined inside `CustomAsyncPublisher`:

```swift
struct Iterator: AsyncIteratorProtocol {
    
    typealias Element = CustomAsyncPublisher.Element
    typealias Failure = Never
    private let publisher: P
    
    actor CustomAsyncStream {
        
        var buffer: Buffer = Buffer()
        var cancellable: AnyCancellable?
        var continuation: CheckedContinuation<Element?, Never>?
        var isEmissionCompleted = false
        
        func addSubscriber(publisher: P) {
            self.cancellable = publisher.sink { _ in
                // end the sequence
                self.finish()
            } receiveValue: { emittedValue in
                // push value onto buffer
                self.push(emittedValue)
            }
        }
        
        func push(_ value: Element) {
            if let continuation = self.continuation {
                
                /**
                 If a continuation exists, it means the async sequence is awaiting
                 on the next value
                 In such a case, we want to directly resume the continuation returning the
                 emitted value from the publisher
                
                 We nullify the continuation, which signals we have no longer a continuation
                 to await on being resumed.
                 */
                 
                self.continuation = nil
                
                // We resume the continuation we were awaiting on
                continuation.resume(returning: value)
            } else {
                
                /**
                 If a continuation does not exist, it means that the sequence is not waiting on
                 the next value, but pulling from the buffer, and doing some work on the buffered value.
                 In such a case, we want to push values onto the buffer queue in order to avoid data loss.
                 */
                
                self.buffer.enqueue(value)
            }
        }
        
        func finish() {
            
            self.isEmissionCompleted = true
            
            if let continuation = self.continuation {
                
                /**
                 If the async sequence is awaiting for the next value but the publisher
                 emits signal of completion, we want to end the sequence, which
                 is done by returning nil from the continuation
                 */
                 
                
                // We nullify the continuation, which signals we no longer have a continuation to await on.
                self.continuation = nil
                
                // Signals the async sequence is done awaiting on the next value
                continuation.resume(returning: nil)
            }
        }
        
        func pull() async -> Element? {
            
            if !buffer.isEmpty {
                // Pull from the buffer if it's not empty
                let value = buffer.dequeue()
                return value
            } else if isEmissionCompleted {
                // If the buffer is empty and emission completed, we want to end the async sequence
                return nil
            }
            
            /**
             In case the buffer is empty and the publisher is not done yet, we need to await on new
             published values to come (either a publisher completion
             or received value).
             */
             
            let value = await withCheckedContinuation { (cont: CheckedContinuation<Element?, Never>) in
                
                /**
                 We store the continuation to resume it later when the we finally
                 get a value emitted from the publisher
                 */
                 
                self.continuation = cont
            }
            
            return value
        }
    }
    
    private let customAsyncStream = CustomAsyncStream()
    
    init(publisher: P) {
        self.publisher = publisher
        Task(operation: subscribeToPublisher)
    }
    
    func subscribeToPublisher() async throws {
        await self.customAsyncStream.addSubscriber(publisher: publisher)
    }
    
    func next() async -> Element? {
        // Pull values from the stream when available
        return await self.customAsyncStream.pull()
    }
}
```

I know that's a mouthful, but it's simpler than it seems.

Let's briefly go over it and explain what I did:

### Type Aliases Definition and the Copy of a Publisher Dependency-Injected

```swift
// Inside the `Iterator` struct
typealias Element = CustomAsyncPublisher.Element
typealias Failure = Never
```

- Now, the first two `typealias` definitions, we have already explained them; that is, it's a matter of
satistying the associated type requirement enforce by the `AsyncIteratorProtocol`. It's like saying, "hey, you,
you want to be an iterator? Okay, then, just know that the two types you absolutely need to work with are
the element you are going to be producing out of the stream, `Element`, as well as any occuring error, `Failure`.

```swift
private let publisher: P
```

Notice how I also let the `Iterator` type be injected a copy of the publisher instance because I need to be able
to have the stream shared state, `CustomAsyncStream`, listen to publishes from such a publisher via a one-time
subscription, and that's a type I defined nested inside the `Iterator` struct — more about it coming next.

### The "Core" of the `CustomAsyncPublisher` API: `CustomAsyncStream`

Folks, this `CustomAsyncStream` is the core type that acts as a bridge between the data source's "Push" model,
and the stream "Pull" model, and stores the state of the stream, namely, a `buffer` data structure to avoid
data loss when the async sequence is not already awaiting on the next value from the data source, but still
working on previously buffered data — in which case, we want to load data from the buffer — and a 
`isEmissionCompleted` property, which flags the end of the async sequence.

Now, I wanted to give you a heads-up that this type is actually an API in and of itself, and tries to mimic
Apple's `AsyncStream` API, with the only difference that the continuation is kept within the private interface
of the struct, and I made this design decision because the user, in this case, doesn't need to care how
the async publisher manages its wrapped publisher under the hood.

However, Apple designed its `AsyncStream` in such a way that the user could actually tap onto the so chased-after
continuation, and have them manage the bridging between the "Pushing" interface — any data source they are
trying to feed the stream from, and the "Pull" interface, the stream itself. Also, Apple encapsulates 
the "Pulling" interface, and both the `Iterator` and the `Continuation` _should_ — I'm deducing here, 
because we can't tap into Apple's actual copyright-protected Concurrency Library — share the same async
stream state via a nested type, through which performing this bridging and communication.

If you are curious about _I_ managed to design such an API that _tries_ to mimic Apple's `AsyncStream`,
check my `CustomAsyncStream` API project.

With that out of the way, here's the code for the `CustomAsyncStream`, specifically for the `CustomAsyncPublisher` API,
where the continuation system is abstracted away from the user.

```swift
actor CustomAsyncStream {
    
    var buffer: Buffer = Buffer()
    var cancellable: AnyCancellable?
    var continuation: CheckedContinuation<Element?, Never>?
    var isEmissionCompleted = false
    
    func addSubscriber(publisher: P) {
        self.cancellable = publisher.sink { _ in
            // end the sequence
            self.finish()
        } receiveValue: { emittedValue in
            // push value onto buffer
            self.push(emittedValue)
        }
    }
    
    func push(_ value: Element) {
        if let continuation = self.continuation {
            
            /**
             If a continuation exists, it means the async sequence is awaiting
             on the next value
             In such a case, we want to directly resume the continuation returning the
             emitted value from the publisher
            
             We nullify the continuation, which signals we have no longer a continuation
             to await on being resumed.
             */
             
            self.continuation = nil
            
            // We resume the continuation we were awaiting on
            continuation.resume(returning: value)
        } else {
            
            /**
             If a continuation does not exist, it means that the sequence is not waiting on
             the next value, but pulling from the buffer, and doing some work on the buffered value.
             In such a case, we want to push values onto the buffer queue in order to avoid data loss.
             */
            
            self.buffer.enqueue(value)
        }
    }
    
    func finish() {
        
        self.isEmissionCompleted = true
        
        if let continuation = self.continuation {
            
            /**
             If the async sequence is awaiting for the next value but the publisher
             emits signal of completion, we want to end the sequence, which
             is done by returning nil from the continuation
             */
             
            
            // We nullify the continuation, which signals we no longer have a continuation to await on.
            self.continuation = nil
            
            // Signals the async sequence is done awaiting on the next value
            continuation.resume(returning: nil)
        }
    }
    
    func pull() async -> Element? {
        
        if !buffer.isEmpty {
            // Pull from the buffer if it's not empty
            let value = buffer.dequeue()
            return value
        } else if isEmissionCompleted {
            // If the buffer is empty and emission completed, we want to end the async sequence
            return nil
        }
        
        /**
         In case the buffer is empty and the publisher is not done yet, we need to await on new
         published values to come (either a publisher completion
         or received value).
         */
         
        let value = await withCheckedContinuation { (cont: CheckedContinuation<Element?, Never>) in
            
            /**
             We store the continuation to resume it later when the we finally
             get a value emitted from the publisher
             */
             
            self.continuation = cont
        }
        
        return value
    }
}
```

The one type above is the core of the `CustomAsyncPublisher` API; namely, the `CustomAsyncStream`.
The `CustomAsyncStream` type acts as an isolated (`actor`) shared state — and therefore thread-safe — that
tries to solve three specific problems.

1. **Bridging-the-gap** problem:

Bridging the gap between a "Push" model (usually the data source of the stream), and a "Pull" model, which
are the "pull" or "await" requests being performed by our `AsyncSequence`'s `next()` method, every time it
gets called on each `for await` loop run — `next()` must suspend until a value is ready.
In our specific case, since we are bulding an asynchronous wrapper for our publisher, the data source of
the stream, which pushes values over time, is the published data's Publisher, `Published<Data>.Publisher`.
This bridging is specifically attained via the use of a continuation, `CheckedContinuation<Element?, Never>?`,
which allows for a smooth interface between the synchronous, reactive Combine's Publisher code, and the
asynchronous codebase of our `AsyncSequence`. More specifically, the continuation allows the async sequence
to await on values from the publisher, and then break the awaiting by resuming the continuation itself,
when a value is eventually emitted to the async sequence downstream.

**Note**: I left comments in all three methods, `push` (yield), `finish`, and `pull`, to further give you a better idea
of what's happening behind the scenes.

2. **Data-loss** problem:

The `CustomAsyncStream` type solves the problem of loosing data from the data source — our publisher, in our case — when
the async sequence is not awaiting on a continuation to resume. The async sequence might be performing some
other time consuming task on data that already pulled. You might understand that, over this time period, if our
publisher were to publish data down the stream, the `next()` method wouldn't be able to intercept such data.
In such a scenario, we resort to defining a queue data structure on which we can `buffer` the emitted value from
the data source as they come down the stream, when the async sequence isn't waiting for the data source
to publish, but performing some other tasks.

Therefore, if a continuation exists and it hasn't yet been resumed, it means the stream is waiting for
values to be published downstream by the publisher; in such a situation, we want to hand the stream
with the emitted value right off the bat, and we do this by resuming the continuation with a returned value,
which is the value we are passing to our `push` method inside the subscriber's closure:

```swift
func push(_ value: Element) {
    
    // If a continuation exists, it means the stream is waiting for Combine to publish.
    // In this case, we hand the data to the stream right off the bat.
    if let continuation = continuation {
    
        self.continuation = nil // <- we no longer need a continuation to be awaiting on
        
        continuation.resume(returning: value)
    
    } else {
        // Otherwise, the stream is performing other work. 
        // In this case, we buffer the published value.
        self.buffer.enqueue(value)
    }
}
```

**Note**: I create a `Buffer` data structure as an extension on `CustomAsyncStream` outside of the `CustomAsyncPublisher`
struct in order to tidy up the code.

The `Buffer` is a simple queue data structure. Remember, we enqueue from the tail and we dequeue from the
head, in order to keep an Big O(1) time complexity. If we did dequeue from the tail, we would have to
perform a linear search until the second-to-last node to nullify it and set it as the new tail node; as a result,
that would resolve to having a `dequeue` method with a Big(n) time complexity.

I won't go over the explanation of how I implemented the `Buffer` queue data structure, but that's really a
singly linked list at the end of the day, where we preprend from the head and append on the tail.

```swift
extension CustomAsyncPublisher.Iterator.CustomAsyncStream {
    
    typealias BufferNodeValue = CustomAsyncPublisher.Iterator.Element
    
    class BufferNode {
        
        var value: BufferNodeValue
        var next: BufferNode?
        
        init(_ value: BufferNodeValue) {
            self.value = value
        }
    }
    
    class Buffer {
        
        var head: BufferNode?
        var tail: BufferNode?
        
        var isEmpty: Bool {
            return self.head == nil
        }
        
        @discardableResult
        func enqueue(_ value: BufferNodeValue) -> BufferNode {
            
            let newNode = BufferNode(value)
            
            if self.isEmpty {
                head = newNode
                return newNode
            }
            
            self.tail?.next = newNode
            self.tail = newNode
            
            return newNode
        }
        
        @discardableResult
        func dequeue() -> BufferNodeValue? {
            
            if self.isEmpty {
                return nil
            }
            
            let dequeuedNode = self.head
            
            self.head = self.head?.next
            dequeuedNode?.next = nil
            
            return dequeuedNode?.value
        }
    }
}
```

3. **Thread-safety** problem:

As you might have noticed, I defined `CustomAsyncStream` 
as an actor. That's mainly because I wanted to enforce serial access to the async stream's state, especially because
of the `buffer` queue. That's essentially because our wrapped publisher might be pushing on one thread, while
the async sequence's `for await` loop pulls on another thread. We want to avoid this behavior and
make our codebase reliable. An actor ensures access mutual exclusion in a more efficient way that Mutex's locks
used to. However, that would take an entire chapter to explain the reason behind its efficiency pitfalls mainly related
to CPU's cores having to change context by emptying their cache and loading up a new thread, since in Mutex,
threads are left in the Stack Memory asleep, instead of being freed-up, and used only when needed (Swift Concurrency).

Just know that an actor is a reference type that enforces a one-thread access per time to its data, and provides
an isolated context in which only `Sendable` data can be sent to. This ensures synchronization of operation, per-thread,
once at a time. This is an ideal solution for when dealing with a buffer to load data in and serializing access to it.

```swift
private let customAsyncStream = CustomAsyncStream()
```

Next up, I defined a stored property on the `Iterator` to keep a reference to the instance of our `CustomAsyncStream`
actor on the Heap Memory, where we will be able to tap into its `buffer`, `isEmissionCompleted` flag, as well as
the bridging `continuation`.

```swift
init(publisher: P) {
    self.publisher = publisher
    Task(operation: subscribeToPublisher)
}

func subscribeToPublisher() async throws {
    await self.customAsyncStream.addSubscriber(publisher: publisher)
}
```

As far as the `Iterator`'s initializer, I have it take in a publisher of generic type `P`, and with which
I set the value of its `publisher` stored property. Then, I subscribe to such an initializer using a `Task`
asynchronous unit of work because `subscribeToPublisher`, a helper method, is async and needs to be awaited on in an
asynchronous context. In turn, `subscribeToPublisher` itself calls the key method that actually subscribes
to the publisher, `addSubscriber(publisher:)`, and since it tries to access an actor-isolated context
(`customAsyncStream` is an instance of an actor) from a non-isolated context, we need to await on any
other thread currently accessing that actor, if any, in a Suspension Queue, before the actor can handle
that function's state — wrapped in a continuation — to its serial executor, which takes care of
running our tasks synchronously on any available threads in the application's cooperative pool.

```swift
func next() async -> Element? {
    // Pull values from the stream when available
    return await self.customAsyncStream.pull()
}
```

We already had a discussion on the `next()` async method. This method essentially awaits on the next element
to be streamed into the asynchronous sequence. In our case, this element is of type `P.Output`, where `P`
is a type parameter that conforms to `Publisher`. As we mentioned above, we refer to it via the
`Element` typealias of the parent struct; namely, `CustomAsyncPublisher<P>.Element`.
The value to be asynchronously yielded is then returned from the `next()` method.

## Briefly on the `CustomAsyncPublisher` Struct

As you might have noticed, the `CustomAsyncPublisher` is a wrapper to any `Publisher` type, which we specified using
generics via the type parameter `P` and providing the constraint enforcing the conformance of this generic type `P`
to the `Publisher` protocol.


```swift
struct CustomAsyncPublisher<P: Publisher>: AsyncSequence {

   typealias AsyncIterator = Iterator
   typealias Element = P.Output
   private let publisher: P
```

Much like the `AsyncIteratorProtocol`, the `AsyncSequence` protocol has two associated types, `AsyncIterator`,
as well as the `Element` types. Any concrete type conforming to this protocol needs to specify these types
either implicitly by having the compiler infer them, or explicitly by using typealiases.

We know that the type for our async iterator is the one defined by our nested struct, `Iterator`, and
the type for each element in this asynchronous sequence is based on the type of the values of our published
data, `P.Output`.

Ultimately, since the `CustomAsyncPublisher` struct is a wrapper for our Combine's `Publisher` type, it's going to
be initialized with a `Publisher` object to be stored inside `publisher`, which is the publisher we are then
going to subscribe to and asynchronously stream its emitted values over time.

Finally, the `AsyncSequence` protocol requires any conforming type to implement a `makeAsyncIterator` method
from which we return our `Iterator` instance, whose type, once again, was defined as a nested struct 
inside `CustomAsyncPublisher`.

Also, upon construction of the `Iterator` struct, I injected into its initializer a _copy_ of the publisher, which we
use to subscribe to it, and receive published values from.
Now, you might wonder why we are passing a _copy_ of our wrapped publisher, and not a reference to it.
Well, even though the `Published<Data>.Publisher` type is a struct (value type), and we are passing a copy
to the `Iterator`'s constructor, that copy is actually referencing a specific part of memory where the
SwitUI Engine performs data persistance; namely, the Attribute Graph. That's where SwiftUI actually manages
the state of each view, and associate to each view a View Node stored on the Heap Memory and where
properties wrapped with `@State` persist throughout the application's life cycle. 
Now, that applies to the `@Published` attribute as well, and even though we are passing a copy of our publisher,
all copies that we ever create are referencing the same block of memory pertaining to that state data that is 
getting published and is wrapped with `@Published`.

I hope it makes sense. If it further helps you, see that copied publisher, much like you would look at a SwiftUI
view: those structs are just objects holding information, which are continuously getting destroyed and recreated,
but all attain to updating what gets drawn on the screen of your Apple's devices.

```swift
init(publisher: P) {
    self.publisher = publisher
}

func makeAsyncIterator() -> Iterator {
    return Iterator(publisher: self.publisher)
}
```

Ultimately, because the `CustomAsyncPublisher` is an `AsyncSequence` type, it's required to implement the
`makeAsyncIterator()` method, in order to conform to the `AsyncSequence` protocol and be an asynchronous
sequence that can be iterated over its elements. We then return an instance of the `Iterator` nested
type conforming to `AsyncIteratorProtocol`, and inject our wrapped publisher into its initializer.

```swift
extension Publisher {
    var customAsyncPublisher: CustomAsyncPublisher<Self> {
        return CustomAsyncPublisher(publisher: self)
    }
}
```

Finally, I created an extension on the `Publisher` protocol; that way, I can tap into our `CustomAsyncPublisher<Self>`
instance on any type of publisher, where `Self` refers to the type of our current instance conforming to the
`Publisher` protocol.
Obviously, since the objective of our `CustomAsyncPublisher` is to
create an asynchronous interface for its wrapped publisher, upon its initialization, I pass over the current
instance of the publisher I'm working with by referring to the `self` keyword.

That's it for this API, folks! Let's now see this `CustomAsyncPublisher` in action by creating a very simple
mock application in which we use `@Published` data on a View Model's Manager, and use the published data's
publisher from within the View Model to update its property upon data updates.

## `CustomAsyncPublisher` Use Case Example

Let's now go through a simple use case example showing how we would use this `CustomAsyncPublisher` in
a Mock iOS App — it's going to be quite similar to how you would use Apple's native `AsyncPublisher` within
your applications.

Open your Xcode and create an iOS App project in SwiftUI, and let's create a basic View which will
be displaying the content of a View Model's data collection — an `[User]` — using a `ForEach` loop, and
printing their full name, and email.

Then, before we look at how I defined the `UsersViewModel`, let's define our Model, `User`, and build our
way from the ground up. In other words, I'm going to be defining two protocols:

 - `NetworkingService`: Define the service dependency
 
 - `DataSource`: Define the data source dependency
 
Next up, I'm going to define two concrete types:
 
 - `UserNetworkingService` (conforms to `NetworkingService`): Defines a networking service which fetches user data, given a specific URL. In this example, the `MockUserManager` is using this service as a dependency to fetch
 mock user data from a fake API. For this example, I used the <a href="https://jsonplaceholder.typicode.com/">jsonplaceholder API</a> to fetch an array of users using the following URL: "https://jsonplaceholder.typicode.com/users".
 
 - `MockUserManager` (conforms to `DataSource`): Defines a mock data source to manage the users, which I will
 then use as a dependency to inject in my `UsersViewModel`'s initializer. 
 The `UsersViewModel` will use the manager as a dependency, and to tap into its user data's publisher
to listen for emissions downstream.
 
Only then will I define a `UsersViewModel` that uses my manager to create an async stream from its
published data's publisher.

### UsersView

Let's start simple by defining our `UsersView`, though. 

```swift
struct UsersView: View {
    
    @State private var usersViewModel = UsersViewModel(
        manager: MockUserManager(service: MockUserNetworkingService())
    )
    
    var body: some View {
        ScrollView {
            VStack {
                ForEach(usersViewModel.data) { user in
                    VStack {
                        Text(user.name)
                            .font(.title)
                        Text(user.email)
                            .font(.headline)
                    }
                }
            }
        }
        .task {
            await usersViewModel.loadData()
        }
    }
}
```

On our view appearing, we are loading data from the view model, which should update its `@Published` users
array, and trigger updates on the UI.

Notice that we dependency injected an instance of the concrete mock service type, `MockUserNetworkingService`, into
our manager, and then the manager, `MockUserManager` into our `UsersViewModel` view model.

### Model

Let's now create our `User` model. This will be `Identifiable` and `Codable`:


```swift
struct User: Identifiable, Codable {
    let id: Int
    let name: String
    let email: String
}
```

This struct will represent data concerning with each of our fake users.

### Networking Service and Data Source

Next up, let's define our abstract super types, namely, the `NetworkingService` and `DataSource` protocols:

```swift
protocol NetworkingService<Data> {
    associatedtype Data: Codable
    func fetchData(from url: URL) async throws -> [Data]
}

protocol DataSource<Data>: Actor {
    associatedtype Data
    var data: [Data] { get set }
    var dataPublisher: Published<[Data]>.Publisher { get }
    func loadData() async -> Void
}
```

The `NetworkingService` protocol requires a type `Data` as an associated type to this interface, and
is also bestowing a constraint on it, saying that any `Data` type should be `Codable`.
Then, since it's a networking service, any type that is a `NetworkingService` should also be able to fetch
data from a certain `URL` and the result of this fetching should be an array of such `Data` types.
We are still using generics and declaring a type parameter `Data`, but when it comes to
declaring such a type parameter on a protocol, we declare it as an associated type as the type itself is abstract;
in that, it's just a declaration, not a definition.

The `DataSource` protocol also requires a `Data` type to work with, but notice how this `DataSource` protocol, in
turn conforms to another protocol; namely, the `Actor` protocol.
That's because I knew that any concrete data source I would be defining (e.g., the `MockUserManager`) would
be an actor, and I enforced this restriction on any `DataSource` type because I specifically wanted any
property on my data source to be actor-isolated and thread-safe in order to not incur in data race issues.
You can also create a global actor for your manager and isolate one or more specific properties to that
global actor's context if you don't prefer enforcing that `Actor` conformance.

Also, notice that the declaration for the `data` property is not marked as `@Published`. How come?

Well, whenever you wrap a property with a property wrapper in SwiftUI you are actually _defining_ how such
a property is going to be stored in memory and managed. A protocol, by design, is an interface, which means
it just provides _declarations_, and not definitions/implementations.

So, in order to let that `data` property have an associated `Publisher`, we should declare once for that
`DataSource`. Later, in our concrete implementation, we are going to define our `data` property marking it
with the `@Published` property wrapper, and define our `dataPublisher` as a computed property returning
that `data`'s projected value (`$data`) in order to tap into its related publisher.

### Concrete Mock Implementation of the `NetworkingService` Interface: `UserNetworkingService`

`UserNetworkingService` is a concrete networking service that works with a `User` type, and implements
a `fetchData(from:) async throws -> [User]` to fetch users via a specified `URL`.
In our example, we will use an instance of this struct to be injected as a dependency into our
`MockUserManager`; that way, it can use such a service to fetch some fake user data, and update its
`@Published` data array over time.

The following is the implementation of `UserNetworkingService`:

```swift
struct UserNetworkingService: NetworkingService {
    
    typealias Data = User
    
    func fetchData(from url: URL) async throws -> [Data] {
        
        let (usersData, _) = try await URLSession.shared.data(from: url)
        
        guard
            let decodedUsersData = try? JSONDecoder().decode([Data].self, from: usersData)
        else {
            throw URLError(.badServerResponse)
        }
        
        return decodedUsersData
    }
}
```

The following is the implementation for the `MockUserManager`:

```swift
actor MockUserManager: DataSource {
    
    typealias Data = User
    
    @Published var data: [Data] = []
    var dataPublisher: Published<[Data]>.Publisher {
        return $data
    }
    
    let service: UserNetworkingService
    
    init(service: UserNetworkingService) {
        self.service = service
    }
    
    func loadData() async {
        
        let url = URL(string: "https://jsonplaceholder.typicode.com/users")!
        let users = try! await self.service.fetchData(from: url) 
        
        // Fake user `data` being update over time
        for index in 0..<users.count {
           try? await Task.sleep(nanoseconds: UInt64(index * 500_000_000))
            
           self.data.append(users[index])
        }
    }
}
```

As previously mentioned, the concrete implementation of a `DataSource` type would hold the _definition_ of
our `data` stored property, which is the state that we were meaning to be publishing, using the `@Published`
property wrapper — which, once again, _defines_ how this property should be stored and managed in memory.
In order to make up for the lack of an `@Published` wrapper for `data` in the `DataSource` protocol,
we declared a `dataPublisher` read-only property of type `Published<[Data]>.Publisher` to then return,
in the concrete implementation of any `DataSource` type, the projected value of `data`; namely, the
actual `@Published` data's `Publisher`. This gave us a way to tap into the `data`'s publisher from any
concrete implementation of `DataSource`.

Notice how the manager's initializer takes in a `UserNetworkingService` instance as a dependency service
to use inside `loadData()` and fetch users using a fake `URL`.

Once I have fetched the data (`users`), I try to make our sample example a little bit closer to a real-life scenario
where we are dealing with data being loaded over time, and that's where the usefulness of a Combine's
publisher, and now with Structured Concurrency, an async publisher kicks in.

Now, we are in a situation where this data is somehow being updated over time, and its associated publisher
emits such publishes downstream to any subscribers. Since I have created a custom API that mimics Apple's
`AsyncPublisher`, we can simply interface our code to the async/await syntax without caring about
subscribing to the publisher. In other words, much like `AsyncPublisher` allows us to, my `CustomAsyncPublisher`
abstracts away the inner functionality of a Combine's publisher, and creates an asynchronous interface for
our Combine's publisher synchronous code using a continuation. All of this makes possible for an asynchronous
sequence to asynchronously await on values emitted by the publisher over time. All we have to do is tap into
our publisher's `customAsyncPublisher`, which I provided as an extension to the `Publisher` protocol, which
is pretty much equivalent to you tapping into the publisher's `values` property, which grants you
access to the Apple's native `AsyncPublisher`.

Let's see this in action inside our `UsersViewModel` implementation:

```swift
@Observable
class UsersViewModel<M: DataSource> {
    
    @MainActor private(set) var data: [M.Data] = []
    private let manager: M
    
    init(manager: M) {
        self.manager = manager
    }
    
    func loadData() async {
        // Concurrently load data from the manager and create an async stream that
        // awaits on emissions from the manager's published data's publisher.
        
        // Listen for emitted values from the publisher as the manager's user data
        // get updated — using an async sequence; namely, our `CustomAsyncPublisher`.
        Task {
            for await users in await self.manager.dataPublisher.customAsyncPublisher {
                
                if let lastUpdatedUser = users.last {
                    await MainActor.run {
                        self.data.append(lastUpdatedUser)
                    }
                }
            }
        }
        
        // Load user data from the manager over time
        Task {
            await self.manager.loadData()
        }
    }
}
```

Looking at the `UsersViewModel` class, we notice that it gets injected a manager of type `M` conforming to
`DataSource`.

Also, since this view model is collecting data awaited on the manager's published `data`, we also define
a `data` variable on the view model to hold elements of type `M.Data`.

```swift
@MainActor private(set) var data: [M.Data] = []
private let manager: M
```

At the heart of this type there's the `loadData()` async method. In this method, notice how we are concurrently
performing two tasks:

    - Task 1: Creates a `CustomAsyncPublisher` async sequence that wraps the publisher of the manager's published `data`.
      Then, it defines a for-await-in loop to asynchronously await on the emitted values from that publisher.
      Since, the emitted values are in the form of updates arrays of users, and we know that our mock manager
      updates its data _one_ user at a time, we are boldly grabbing the last updated user at each loop iteration,
      and then updating our view model's data array on the main thread, from which to trigger UI updates, that's why
      I have isolated the view model's `data` property to the `MainActor` global actor using `@MainActor`.
      
    - Task 2: triggers the fetching of user data and updates the manager's published `data` over time.
    
It's important to understand that those two operations need to happen concurrently, otherwise our
async stream would be awaiting on the next value forever, or until the termination of our application,
and the manager will never be able to initiate the fetching of users and the updating of its `@Published` data.

Anyhow, the end result would be you seeing a list of users continuously being updated over time.

Folks, that's all! I hope you enjoyed this workshop, and feel free to reach out for suggestions and improvements! 
      
The following is the complete code put together regarding our sample app to test `CustomAsyncPublisher`. Also, feel free
to organize it in various files. Either way, I attached all necessary files for you to test and use in this GitHub
repository!

Bye!

```swift
// Code from `CustomAsyncPublisherTest.swift`
import SwiftUI

struct User: Identifiable, Codable {
    let id: Int
    let name: String
    let email: String
}

protocol NetworkingService<Data> {
    associatedtype Data: Codable
    func fetchData(from url: URL) async throws -> [Data]
}

protocol DataSource<Data>: Actor {
    associatedtype Data
    var data: [Data] { get set }
    var dataPublisher: Published<[Data]>.Publisher { get }
    func loadData() async -> Void
}

struct UserNetworkingService: NetworkingService {
    
    typealias Data = User
    
    func fetchData(from url: URL) async throws -> [Data] {
        
        let (usersData, _) = try await URLSession.shared.data(from: url)
        
        guard
            let decodedUsersData = try? JSONDecoder().decode([Data].self, from: usersData)
        else {
            throw URLError(.badServerResponse)
        }
        
        return decodedUsersData
    }
}

actor MockUserManager: DataSource {
    
    typealias Data = User
    
    @Published var data: [Data] = []
    var dataPublisher: Published<[Data]>.Publisher {
        return $data
    }
    
    let service: UserNetworkingService
    
    init(service: UserNetworkingService) {
        self.service = service
    }
    
    func loadData() async {
        
        let url = URL(string: "https://jsonplaceholder.typicode.com/users")!
        let users = try! await self.service.fetchData(from: url) 
        
        // Fake user `data` being update over time
        for index in 0..<users.count {
           try? await Task.sleep(nanoseconds: UInt64(index * 500_000_000))
            
           self.data.append(users[index])
        }
    }
}

@Observable
class UsersViewModel<M: DataSource> {
    
    @MainActor private(set) var data: [M.Data] = []
    private let manager: M
    
    init(manager: M) {
        self.manager = manager
    }
    
    func loadData() async {
        // Concurrently load data from the manager and create an async stream that
        // awaits on emissions from the manager's published data's publisher.
        
        // Listen for emitted values from the publisher as the manager's user data
        // get updated — using an async sequence; namely, our `CustomAsyncPublisher`.
        Task {
            for await users in await self.manager.dataPublisher.customAsyncPublisher {
                
                if let lastUpdatedUser = users.last {
                    await MainActor.run {
                        self.data.append(lastUpdatedUser)
                    }
                }
            }
        }
        
        // Load user data from the manager over time
        Task {
            await self.manager.loadData()
        }
    }
}

struct UsersView: View {
    
    @State private var usersViewModel = UsersViewModel(
        manager: MockUserManager(service: UserNetworkingService())
    )
    
    var body: some View {
        ScrollView {
            VStack {
                ForEach(usersViewModel.data) { user in
                    VStack {
                        Text(user.name)
                            .font(.title)
                        Text(user.email)
                            .font(.headline)
                    }
                }
            }
        }
        .task {
            await usersViewModel.loadData()
        }
    }
}

#Preview {
    UsersView()
}
```


