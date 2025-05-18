const std = @import("std");

/// ...
pub const CircularBuffer = struct {
    size: usize,
    buffer: []align(std.heap.page_size_min) u8,
    len: usize,

    /// ...
    pub fn init(size: usize) !CircularBuffer {
        const ptr = try std.posix.mmap(null, size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);

        return CircularBuffer{ .size = size, .buffer = ptr, .len = 0 };
    }

    /// ...
    pub fn deinit(self: *CircularBuffer) void {
        std.posix.munmap(self.buffer);
    }

    /// ...
    /// Invalidated with each call to commit/consume.
    pub fn data(self: *const CircularBuffer) []const u8 {
        return self.buffer[0..self.len];
    }

    /// ...
    /// Invalidated with each call to commit/consume.
    pub fn uninitialized(self: *CircularBuffer) []u8 {
        return self.buffer[self.len..self.size];
    }

    /// ...
    /// Asserts that n is less or equal to the uninitialized region's size.
    pub fn commit(self: *CircularBuffer, n: usize) void {
        std.debug.assert(n <= self.uninitialized().len);

        self.len += n;
    }

    /// ...
    /// Asserts that n is less or equal to the data region's size.
    pub fn consume(self: *CircularBuffer, n: usize) void {
        std.debug.assert(n <= self.data().len);

        std.mem.copyForwards(u8, self.buffer, self.buffer[n..self.len]);
        self.len -= n;
    }
};

test "initially empty" {
    // given
    var circular_buffer = try CircularBuffer.init(8);
    defer circular_buffer.deinit();

    // then
    try std.testing.expectEqual(circular_buffer.data().len, 0);
    try std.testing.expectEqual(circular_buffer.uninitialized().len, 8);
}

test "commits data" {
    // given
    var circular_buffer = try CircularBuffer.init(8);
    defer circular_buffer.deinit();

    // when
    const uninitialized = circular_buffer.uninitialized();
    std.mem.copyForwards(u8, uninitialized, "hi");
    circular_buffer.commit("hi".len);

    // then
    try std.testing.expectEqualSlices(u8, circular_buffer.data(), "hi");
    try std.testing.expectEqual(circular_buffer.uninitialized().len, 6);
}

test "consumes committed data" {
    // given
    var circular_buffer = try CircularBuffer.init(8);
    defer circular_buffer.deinit();

    std.mem.copyForwards(u8, circular_buffer.uninitialized(), "hi there");
    circular_buffer.commit("hi there".len);

    // when
    circular_buffer.consume(3);

    // then
    try std.testing.expectEqualSlices(u8, circular_buffer.data(), "there");
    try std.testing.expectEqual(circular_buffer.uninitialized().len, 3);
}

test "transfers data larger than itself" {
    // given
    var circular_buffer = try CircularBuffer.init(1024);
    defer circular_buffer.deinit();

    var randomText = try std.testing.allocator.alloc(u8, 1024 * 1024); // big enough to overflow the buffer and u16 internal indices
    defer std.testing.allocator.free(randomText);

    var rng = std.Random.DefaultPrng.init(0);
    var random = rng.random();

    for (0..randomText.len) |i| {
        randomText[i] = random.intRangeAtMost(u8, 32, 126); // random ascii character
    }

    // when
    var bytes_committed: usize = 0;
    var bytes_consumed: usize = 0;

    while (bytes_consumed < randomText.len) {
        if (random.boolean()) {
            const n = @min(random.uintAtMost(usize, circular_buffer.uninitialized().len), randomText.len - bytes_committed);
            std.mem.copyForwards(u8, circular_buffer.uninitialized(), randomText[bytes_committed .. bytes_committed + n]);
            circular_buffer.commit(n);
            bytes_committed += n;
        }

        if (random.boolean()) {
            const n = random.uintAtMost(usize, circular_buffer.data().len);
            try std.testing.expectEqualStrings(circular_buffer.data()[0..n], randomText[bytes_consumed .. bytes_consumed + n]); // then
            circular_buffer.consume(n);
            bytes_consumed += n;
        }

        // then
        try std.testing.expectEqual(circular_buffer.data().len + circular_buffer.uninitialized().len, 1024);
        try std.testing.expect(bytes_committed >= bytes_consumed);
    }

    // then
    try std.testing.expectEqual(circular_buffer.data().len, 0);
    try std.testing.expectEqual(circular_buffer.uninitialized().len, 1024);
    try std.testing.expectEqual(bytes_committed, bytes_consumed);
}
