//! Mandelbrot RGBA8 kernel, freestanding with no imports.
//! Build from the repository root (Zig 0.16.0):
//! zig build-exe docs/examples/fractal/kernel.zig -target wasm32-freestanding -O ReleaseFast -fstrip -fno-entry -rdynamic -femit-bin=docs/examples/fractal/kernel.wasm
//! zig build-exe docs/examples/fractal/kernel.zig -target wasm32-freestanding -mcpu=generic+simd128 -O ReleaseFast -fstrip -fno-entry -rdynamic -femit-bin=docs/examples/fractal/kernel_simd.wasm
//! ABI: set_view(f64, f64, f64) -> i32 (0 finite, -1 nonfinite);
//! render(i32, i32, i32) -> i64 and render_simd(i32, i32, i32) -> i64.
//! set_view stores even an invalid view. Render validates before any write.
//! fb_ptr() -> i32 addresses RGBA8 storage; fb_cap() -> i32 is pixel capacity.
//! The default build also exposes render_simd, with vector operations scalarized.
//! Invalid dimensions or nonfinite coordinates return -1 without writing pixels.
//! Iterations are capped at 2^26-1 so totals remain exactly representable by cljw.
const std = @import("std");
const capacity = 1024 * 1024;
var framebuffer: [capacity * 4]u8 = undefined;
var view_cx: f64 = -0.5;
var view_cy: f64 = 0;
var view_scale: f64 = 3.5 / 512.0;

export fn set_view(cx: f64, cy: f64, scale: f64) i32 {
    view_cx = cx;
    view_cy = cy;
    view_scale = scale;
    return if (std.math.isFinite(cx) and std.math.isFinite(cy) and std.math.isFinite(scale)) 0 else -1;
}

export fn fb_ptr() usize {
    return @intFromPtr(&framebuffer);
}
export fn fb_cap() i32 {
    return capacity;
}

fn valid(cx: f64, cy: f64, scale: f64, w: i32, h: i32, max_iter: i32) bool {
    return w > 0 and h > 0 and w <= capacity and h <= capacity and
        @as(i64, w) * h <= capacity and max_iter > 0 and
        std.math.isFinite(cx) and std.math.isFinite(cy) and std.math.isFinite(scale);
}

fn color(pixel: usize, n: u32, limit: u32, magnitude: f64) void {
    const out = framebuffer[pixel * 4 ..][0..4];
    out.* = .{ 0, 0, 0, 255 };
    if (n == limit) return;
    // Continuous escape count, mapped through a periodic triangular palette.
    const bounded = if (std.math.isFinite(magnitude)) @max(magnitude, 4.000001) else 1.0e300;
    const smooth = @as(f64, @floatFromInt(n)) + 1.0 - @log2(@log2(bounded) * 0.5);
    const phase = smooth * 0.025;
    inline for (0..3) |channel| {
        const t = phase + @as(f64, @floatFromInt(channel)) / 3.0;
        const wave = 1.0 - @abs(2.0 * (t - @floor(t)) - 1.0);
        out[channel] = @intFromFloat(wave * 255.0);
    }
}

export fn render(w: i32, h: i32, max_iter: i32) i64 {
    const cx = view_cx;
    const cy = view_cy;
    const scale = view_scale;
    if (!valid(cx, cy, scale, w, h, max_iter)) return -1;
    const limit: u32 = @intCast(@min(max_iter, (1 << 26) - 1));
    var total: i64 = 0;
    var y: usize = 0;
    while (y < @as(usize, @intCast(h))) : (y += 1) {
        const ci = cy + (@as(f64, @floatFromInt(y)) - @as(f64, @floatFromInt(h)) / 2.0) * scale;
        var x: usize = 0;
        while (x < @as(usize, @intCast(w))) : (x += 1) {
            const cr = cx + (@as(f64, @floatFromInt(x)) - @as(f64, @floatFromInt(w)) / 2.0) * scale;
            var zr: f64 = 0;
            var zi: f64 = 0;
            var n: u32 = 0;
            while (n < limit and zr * zr + zi * zi <= 4.0) : (n += 1) {
                const next = zr * zr - zi * zi + cr;
                zi = (2.0 * zr) * zi + ci;
                zr = next;
            }
            total += n;
            color(y * @as(usize, @intCast(w)) + x, n, limit, zr * zr + zi * zi);
        }
    }
    return total;
}

export fn render_simd(w: i32, h: i32, max_iter: i32) i64 {
    const cx = view_cx;
    const cy = view_cy;
    const scale = view_scale;
    if (!valid(cx, cy, scale, w, h, max_iter)) return -1;
    const V = @Vector(2, f64);
    const limit: u32 = @intCast(@min(max_iter, (1 << 26) - 1));
    const width: usize = @intCast(w);
    var total: i64 = 0;
    var y: usize = 0;
    while (y < @as(usize, @intCast(h))) : (y += 1) {
        const ci: V = @splat(cy + (@as(f64, @floatFromInt(y)) - @as(f64, @floatFromInt(h)) / 2.0) * scale);
        var x: usize = 0;
        while (x < width) : (x += 2) {
            const positions: V = .{ @floatFromInt(x), @floatFromInt(x + 1) };
            const cr = @as(V, @splat(cx)) + (positions - @as(V, @splat(@as(f64, @floatFromInt(w)) / 2.0))) * @as(V, @splat(scale));
            var zr: V = @splat(0);
            var zi: V = @splat(0);
            var counts = [_]u32{ 0, 0 };
            var step: u32 = 0;
            while (step < limit) : (step += 1) {
                const mag = zr * zr + zi * zi;
                const active: @Vector(2, bool) = .{ counts[0] == step and mag[0] <= 4.0, x + 1 < width and counts[1] == step and mag[1] <= 4.0 };
                if (!@reduce(.Or, active)) break;
                const next = zr * zr - zi * zi + cr;
                zi = @select(f64, active, (@as(V, @splat(2.0)) * zr) * zi + ci, zi);
                zr = @select(f64, active, next, zr);
                inline for (0..2) |lane| {
                    if (active[lane]) counts[lane] += 1;
                }
            }
            const magnitude = zr * zr + zi * zi;
            inline for (0..2) |lane| {
                if (x + lane < width) {
                    total += counts[lane];
                    color(y * width + x + lane, counts[lane], limit, magnitude[lane]);
                }
            }
        }
    }
    return total;
}
