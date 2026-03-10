//
//  CustomAsyncPublisher.swift
//  CustomAsyncPublisher
//
//  Created by Saverio Negro on 3/10/26.

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




