import Foundation

public struct PTYRingBuffer {
    private let capacity: Int
    private var storage = Data()
    private var next = 0

    public init(capacity: Int = PTYProtocol.replayLimit) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public mutating func append(_ bytes: Data) {
        if bytes.count >= capacity {
            storage = Data(bytes.suffix(capacity))
            next = 0
            return
        }
        let tail = min(bytes.count, capacity - next)
        let end = next + tail
        storage.replaceSubrange(next..<min(end, storage.count), with: bytes.prefix(tail))
        let wrapped = bytes.count - tail
        if wrapped > 0 { storage.replaceSubrange(0..<wrapped, with: bytes.suffix(wrapped)) }
        next = (end + wrapped) % capacity
    }

    public var data: Data {
        guard storage.count == capacity, next != 0 else { return storage }
        var result = Data(storage[next...])
        result.append(storage[..<next])
        return result
    }
}
