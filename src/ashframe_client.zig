const std = @import("std");

const main = @import("main");

// --- ASHFRAME CUSTOM CLIENT ---
// Per-server asset + chunk caches. Active only on the configured Ashframe
// server; inert elsewhere (no new packets, stock request flow).
// Cache dir: ~/.cubyz/ashframeCache/<server>/ (delete to force redownload).

var dialAddress: ?[]u8 = null;

// --- ASHFRAME CUSTOM CLIENT: join-stage timing (observability only). ---
// Logs per-stage durations on every connect (vanilla + Ashframe) so slow
// joins can be attributed to a stage instead of guessed at. No behavior.
var timingStartMs: i64 = 0;
var timingLastMs: i64 = 0;

pub fn timingReset() void {
	timingStartMs = main.timestamp().toMilliseconds();
	timingLastMs = timingStartMs;
}

pub fn timingMark(stage: []const u8) void {
	const now = main.timestamp().toMilliseconds();
	if (timingStartMs == 0) timingReset();
	std.log.info("[timing] {s}: +{d}ms (total {d}ms)", .{ stage, now - timingLastMs, now - timingStartMs });
	timingLastMs = now;
}

/// Remembers the typed server address. Called from the connecting window.
pub fn noteDialAddress(ip: []const u8) void {
	if (dialAddress) |old| main.globalAllocator.free(old);
	dialAddress = main.globalAllocator.dupe(u8, ip);
	timingReset();
}

/// Master toggle on, and dialed address matches the Ashframe server.
pub fn isActive() bool {
	if (!main.settings.launchConfig.ashframeCache) return false;
	const dial = dialAddress orelse return false;
	const want = main.settings.launchConfig.ashframeServer;
	if (want.len == 0) return false;
	return std.mem.indexOf(u8, dial, want) != null;
}

/// Filesystem-safe per-server key derived from the dial address.
fn serverKey(buf: *[256]u8) []const u8 {
	const dial = dialAddress orelse return "unknown";
	var len: usize = 0;
	for (dial) |ch| {
		if (len >= buf.len) break;
		const c = std.ascii.toLower(ch);
		buf[len] = if (std.ascii.isAlphanumeric(c)) c else '_';
		len += 1;
	}
	if (len == 0) {
		buf[0] = 'u';
		return buf[0..1];
	}
	return buf[0..len];
}

fn cacheDir(buf: *[256]u8) []const u8 {
	var keyBuf: [256]u8 = undefined;
	const key = serverKey(&keyBuf);
	return std.fmt.bufPrint(buf, "ashframeCache/{s}", .{key}) catch "ashframeCache/unknown";
}

pub fn packHash(data: []const u8) u64 {
	return std.hash.Wyhash.hash(0, data);
}

/// Cached pack hash to announce at handshake, or null when there is nothing
/// usable to announce (feature off, no cache, TTL expired, version changed).
/// The server replies with an empty marker instead of the pack on a match;
/// otherwise it sends the full pack exactly as before.
pub fn announcedPackHash() ?u64 {
	if (!isActive()) return null;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	var dir = main.files.cubyzDir().openDir(dirPath) catch return null;
	defer dir.close();
	const zon = dir.readToZon(main.stackAllocator, metaFile) catch return null;
	defer zon.deinit(main.stackAllocator);
	const oldVer = zon.get([]const u8, "clientVersion") orelse return null;
	if (!std.mem.eql(u8, oldVer, main.settings.version.version)) return null;
	const ts = zon.get(i64, "flushedAtMs") orelse return null;
	const ttlMs: i64 = @as(i64, @intCast(main.settings.launchConfig.ashframeCacheTTLHours))*60*60*1000;
	if (ttlMs > 0 and main.timestamp().toMilliseconds() -% ts > ttlMs) return null;
	const h = zon.get(i64, "packHash") orelse return null;
	return @bitCast(h);
}

const metaFile = "cache.zon";

fn readMetaTs(dir: main.files.Dir) ?i64 {
	const zon = dir.readToZon(main.stackAllocator, metaFile) catch return null;
	defer zon.deinit(main.stackAllocator);
	const ts = zon.get(i64, "flushedAtMs") orelse return null;
	return ts;
}

fn writeMeta(dir: main.files.Dir, packHashValue: ?u64) void {
	const zon = main.ZonElement.initObject(main.stackAllocator);
	defer zon.deinit(main.stackAllocator);
	zon.put("flushedAtMs", main.timestamp().toMilliseconds());
	zon.put("clientVersion", main.settings.version.version);
	if (packHashValue) |h| zon.put("packHash", @as(i64, @bitCast(h)));
	dir.writeZon(metaFile, zon) catch |err| {
		std.log.err("Ashframe cache: could not write meta: {s}", .{@errorName(err)});
	};
}

/// Meta from another client build -> treat as changed (wipe).
fn clientVersionMismatch(dir: main.files.Dir) bool {
	const zon = dir.readToZon(main.stackAllocator, metaFile) catch return false;
	defer zon.deinit(main.stackAllocator);
	const old = zon.get([]const u8, "clientVersion") orelse return false;
	return !std.mem.eql(u8, old, main.settings.version.version);
}

pub const PackStatus = enum { off, unchanged, changed };

/// `.unchanged` -> skip delete+unpack; `.changed`/`.off` -> unpack, then
/// call noteAssetsUnpacked(). Enforces TTL expiry and pack-change wipes.
pub fn checkAssetPack(packData: []const u8) PackStatus {
	if (!isActive()) return .off;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	const cubyz = main.files.cubyzDir();
	cubyz.makePath(dirPath) catch |err| {
		std.log.err("Ashframe cache: could not create {s}: {s}", .{ dirPath, @errorName(err) });
		return .off;
	};
	var dir = cubyz.openDir(dirPath) catch return .off;
	defer dir.close();

	const h = packHash(packData);
	const nowMs = main.timestamp().toMilliseconds();
	const ttlMs: i64 = @as(i64, @intCast(main.settings.launchConfig.ashframeCacheTTLHours))*60*60*1000;
	if (readMetaTs(dir)) |ts| {
		if (ttlMs > 0 and nowMs -% ts > ttlMs) {
			std.log.info("Ashframe cache: expired (older than {d}h), flushing.", .{main.settings.launchConfig.ashframeCacheTTLHours});
			cubyz.deleteTree(dirPath) catch {};
			cubyz.makePath(dirPath) catch return .off;
			var fresh = cubyz.openDir(dirPath) catch return .off;
			defer fresh.close();
			writeMeta(fresh, h);
			return .changed;
		}
	}
	if (clientVersionMismatch(dir)) {
		std.log.info("Ashframe cache: client version changed, flushing chunk cache.", .{});
		cubyz.deleteTree(dirPath) catch {};
		cubyz.makePath(dirPath) catch return .off;
		var fresh = cubyz.openDir(dirPath) catch return .off;
		defer fresh.close();
		writeMeta(fresh, h);
		return .changed;
	}
	const zon = dir.readToZon(main.stackAllocator, metaFile) catch null;
	if (zon) |z| {
		defer z.deinit(main.stackAllocator);
		const old = z.get(i64, "packHash");
		if (old != null and old.? == @as(i64, @bitCast(h))) return .unchanged;
	}
	std.log.info("Ashframe cache: asset pack changed, flushing chunk cache.", .{});
	cubyz.deleteTree(dirPath) catch {};
	cubyz.makePath(dirPath) catch return .off;
	var fresh = cubyz.openDir(dirPath) catch return .off;
	defer fresh.close();
	writeMeta(fresh, h);
	return .changed;
}

pub fn noteAssetsUnpacked(packData: []const u8) void {
	if (!isActive()) return;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	var dir = main.files.cubyzDir().openDir(dirPath) catch return;
	defer dir.close();
	writeMeta(dir, packHash(packData));
}

fn chunkFileName(pos: main.chunk.ChunkPosition, buf: *[128]u8) []const u8 {
	return std.fmt.bufPrint(buf, "c_{d}_{d}_{d}_{d}.bin", .{ pos.wx, pos.wy, pos.wz, pos.voxelSize }) catch "c_invalid.bin";
}

/// Unique temp per call: duplicate in-flight tasks for the same chunk would
/// otherwise collide on the shared fixed temp name and fail the rename.
threadlocal var writeSeq: u64 = 0;

fn writeAtomic(dir: main.files.Dir, name: []const u8, data: []const u8) !void {
	writeSeq +%= 1;
	const seq = writeSeq;
	var tmpBuf: [192]u8 = undefined;
	const tmp = std.fmt.bufPrint(&tmpBuf, "{s}.{d}.{d}.tmp", .{ name, main.timestamp().toNanoseconds(), seq }) catch return error.OutOfMemory;
	try dir.dir.writeFile(main.io, .{ .sub_path = tmp, .data = data });
	try dir.dir.rename(tmp, dir.dir, name, main.io);
}

/// Disk budget (~a few hundred MB). Random eviction down to 4/5 of cap.
const maxCachedFiles: usize = 50000;

threadlocal var sweepCounter: u32 = 0;

fn maybeSweep(dirPath: []const u8) void {
	sweepCounter +%= 1;
	if (sweepCounter % 2048 != 0) return;
	const cubyz = main.files.cubyzDir();
	var dir = cubyz.openDir(dirPath) catch return;
	defer dir.close();
	var names: main.ListManaged([]const u8) = .init(main.globalAllocator);
	defer {
		for (names.items) |n| main.globalAllocator.free(n);
		names.deinit();
	}
	var it = dir.iterate();
	while (true) {
		const entry = (it.next(main.io) catch break) orelse break;
		if (entry.kind != .file) continue;
		if (!std.mem.endsWith(u8, entry.name, ".bin")) continue;
		names.append(main.globalAllocator.dupe(u8, entry.name));
	}
	if (names.items.len <= maxCachedFiles) return;
	var rng: u64 = @as(u64, @intCast(main.timestamp().toNanoseconds())) | 0x9e3779b97f4a7c15;
	const target = maxCachedFiles*4/5;
	var i: usize = names.items.len;
	while (i > target) {
		rng ^= rng << 13;
		rng ^= rng >> 7;
		rng ^= rng << 17;
		const victim = rng % i;
		i -= 1;
		const tmp = names.items[victim];
		names.items[victim] = names.items[i];
		names.items[i] = tmp;
		dir.deleteFile(tmp) catch {};
	}
}

var storeErrCount: u32 = 0;

/// Stores a received chunk blob. Failures log throttled, then give up.
pub fn storeChunk(pos: main.chunk.ChunkPosition, data: []const u8) void {
	if (!isActive()) return;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	const cubyz = main.files.cubyzDir();
	cubyz.makePath(dirPath) catch |err| {
		if (storeErrCount < 3) std.log.err("Ashframe cache: makePath {s}/{s}: {s}", .{ main.files.cubyzDirStr(), dirPath, @errorName(err) });
		storeErrCount +|= 1;
		return;
	};
	var dir = cubyz.openDir(dirPath) catch |err| {
		if (storeErrCount < 3) std.log.err("Ashframe cache: openDir {s}: {s}", .{dirPath, @errorName(err)});
		storeErrCount +|= 1;
		return;
	};
	defer dir.close();
	var nameBuf: [128]u8 = undefined;
	const name = chunkFileName(pos, &nameBuf);
	writeAtomic(dir, name, data) catch |err| {
		if (storeErrCount < 3) std.log.err("Ashframe cache: store {s}/{s}: {s}", .{ dirPath, name, @errorName(err) });
		storeErrCount +|= 1;
		return;
	};
	maybeSweep(dirPath);
}

/// Loads a cached chunk blob, or null on miss. Caller owns the memory.
pub fn loadChunk(pos: main.chunk.ChunkPosition) ?[]u8 {
	if (!isActive()) return null;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	var dir = main.files.cubyzDir().openDir(dirPath) catch return null;
	defer dir.close();
	var nameBuf: [128]u8 = undefined;
	const name = chunkFileName(pos, &nameBuf);
	const data = dir.read(main.globalAllocator, name) catch return null;
	return data;
}

/// Drops cached blobs for a live-edited block (all LODs + lightmap).
pub fn invalidateChunk(wx: i32, wy: i32, wz: i32) void {
	if (!isActive()) return;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	var dir = main.files.cubyzDir().openDir(dirPath) catch return;
	defer dir.close();
	for ([_]u31{ 1, 2, 4, 8, 16, 32 }) |vs| {
		const size: i32 = 32*@as(i32, @intCast(vs));
		const mask: i32 = size - 1;
		var nameBuf: [128]u8 = undefined;
		const name = chunkFileName(.{
			.wx = wx & ~mask,
			.wy = wy & ~mask,
			.wz = wz & ~mask,
			.voxelSize = vs,
		}, &nameBuf);
		dir.deleteFile(name) catch {};
		invalidateLightMapIn(dir, wx, wy, vs);
	}
}

fn lightMapFileName(wx: i32, wy: i32, vs: u31, buf: *[128]u8) []const u8 {
	return std.fmt.bufPrint(buf, "m_{d}_{d}_{d}.bin", .{ wx, wy, vs }) catch "m_invalid.bin";
}

/// Stores a received lightmap fragment blob. Same contract as storeChunk.
pub fn storeLightMap(wx: i32, wy: i32, vs: u31, data: []const u8) void {
	if (!isActive()) return;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	const cubyz = main.files.cubyzDir();
	cubyz.makePath(dirPath) catch return;
	var dir = cubyz.openDir(dirPath) catch return;
	defer dir.close();
	var nameBuf: [128]u8 = undefined;
	const name = lightMapFileName(wx, wy, vs, &nameBuf);
	writeAtomic(dir, name, data) catch {};
	maybeSweep(dirPath);
}

/// Loads a cached lightmap fragment, or null on miss. Caller owns the memory.
pub fn loadLightMap(wx: i32, wy: i32, vs: u31) ?[]u8 {
	if (!isActive()) return null;
	var dirBuf: [256]u8 = undefined;
	const dirPath = cacheDir(&dirBuf);
	var dir = main.files.cubyzDir().openDir(dirPath) catch return null;
	defer dir.close();
	var nameBuf: [128]u8 = undefined;
	const name = lightMapFileName(wx, wy, vs, &nameBuf);
	const data = dir.read(main.globalAllocator, name) catch return null;
	return data;
}

/// Deletes the cached lightmap fragment covering column (x, y).
fn invalidateLightMapIn(dir: main.files.Dir, x: i32, y: i32, vs: u31) void {
	const span: i32 = 256*@as(i32, @intCast(vs));
	const mask: i32 = span - 1;
	var nameBuf: [128]u8 = undefined;
	const name = lightMapFileName(x & ~mask, y & ~mask, vs, &nameBuf);
	dir.deleteFile(name) catch {};
}
// --- ASHFRAME CUSTOM CLIENT ---
