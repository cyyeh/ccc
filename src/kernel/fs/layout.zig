// src/kernel/fs/layout.zig — Phase 3.D on-disk FS constants.
//
// 4 MB total = 1024 × 4 KB blocks:
//   block 0       boot sector (zeros, reserved)
//   block 1       superblock
//   block 2       block bitmap (one bit per data block)
//   blocks 3..6   inode table (4 blocks; 64 inodes × 64 B = 1 block in use)
//   blocks 7..1023  data blocks (1017 of them)
//
// Inode is 64 bytes; directory entry is 16 bytes. Both are extern struct
// — same layout on disk as in memory — so mkfs (host Zig) and the kernel
// can share this file as-is.

const std = @import("std");

pub const BLOCK_SIZE: u32 = 4096;
pub const NBLOCKS: u32 = 1024;
pub const NINODES: u32 = 64;
pub const INODES_PER_BLOCK: u32 = BLOCK_SIZE / @sizeOf(DiskInode);

pub const SUPERBLOCK_BLK: u32 = 1;
pub const BITMAP_BLK: u32 = 2;
pub const INODE_START_BLK: u32 = 3;
pub const DATA_START_BLK: u32 = 7;

pub const ROOT_INUM: u32 = 1;
pub const SUPER_MAGIC: u32 = 0xC3CC_F500;

pub const NDIRECT: u32 = 12;
pub const NINDIRECT: u32 = BLOCK_SIZE / 4;
pub const MAX_FILE_BLOCKS: u32 = NDIRECT + NINDIRECT;

pub const FileType = enum(u16) { Free = 0, File = 1, Dir = 2 };

pub const SuperBlock = extern struct {
    magic: u32,
    nblocks: u32,
    ninodes: u32,
    bitmap_blk: u32,
    inode_start: u32,
    data_start: u32,
    dirty: u32,
};

pub const DiskInode = extern struct {
    type: FileType, // u16
    nlink: u16,
    size: u32,
    addrs: [NDIRECT + 1]u32, // 12 direct + 1 indirect = 13 * 4 = 52 B
    _reserved: [4]u8, // pad to 64 B (2 + 2 + 4 + 52 + 4 = 64)
};

comptime {
    std.debug.assert(@sizeOf(DiskInode) == 64);
    std.debug.assert(@sizeOf(SuperBlock) == 28);
}

pub const DIR_NAME_LEN: u32 = 14;
pub const DirEntry = extern struct {
    inum: u16,
    name: [DIR_NAME_LEN]u8,
};

comptime {
    std.debug.assert(@sizeOf(DirEntry) == 16);
}

test "DiskInode is exactly 64 bytes" {
    if (@import("builtin").os.tag != .freestanding) {
        try std.testing.expectEqual(@as(usize, 64), @sizeOf(DiskInode));
    }
}

test "DirEntry is exactly 16 bytes" {
    if (@import("builtin").os.tag != .freestanding) {
        try std.testing.expectEqual(@as(usize, 16), @sizeOf(DirEntry));
    }
}

test "INODES_PER_BLOCK is 64" {
    if (@import("builtin").os.tag != .freestanding) {
        try std.testing.expectEqual(@as(u32, 64), INODES_PER_BLOCK);
    }
}
