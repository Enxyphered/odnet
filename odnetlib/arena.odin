package odnetlib

// Fast Linear/Bump Allocator for zero runtime allocation lifecycles.
Bump_Arena :: struct {
	backing:   []u8,
	offset:    int,
	peak_used: int,
}

bump_arena_init :: proc(arena: ^Bump_Arena, backing_memory: []u8) {
	arena.backing = backing_memory
	arena.offset = 0
	arena.peak_used = 0
}

bump_arena_alloc :: proc(arena: ^Bump_Arena, size: int, alignment: int = 8) -> []u8 {
	aligned_offset := (arena.offset + (alignment - 1)) &~ (alignment - 1)
	if aligned_offset + size > len(arena.backing) {
		return nil
	}
	res := arena.backing[aligned_offset : aligned_offset + size]
	arena.offset = aligned_offset + size
	if arena.offset > arena.peak_used {
		arena.peak_used = arena.offset
	}
	return res
}

bump_arena_reset :: proc(arena: ^Bump_Arena) {
	arena.offset = 0
}
