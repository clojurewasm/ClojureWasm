//! Mandelbrot RGBA8 kernel in Rust, no_std with no imports.
//! Same ABI and pixel math as kernel.zig; see README.md "The kernel ABI".
//! Build from the repository root (rustup target add wasm32-unknown-unknown):
//! rustc --edition 2021 --crate-type=cdylib --target wasm32-unknown-unknown -C opt-level=3 -C panic=abort -C strip=symbols -o docs/examples/fractal/kernel_rust.wasm docs/examples/fractal/kernel.rs
//! log2 is computed locally (core has no libm), with the same series as
//! kernel.c, so kernel_c.wasm and kernel_rust.wasm agree byte for byte.
#![no_std]

const CAPACITY: usize = 1024 * 1024;
static mut FRAMEBUFFER: [u8; CAPACITY * 4] = [0; CAPACITY * 4];
static mut VIEW: (f64, f64, f64) = (-0.5, 0.0, 3.5 / 512.0);

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    core::arch::wasm32::unreachable()
}

fn finite(x: f64) -> bool {
    x - x == 0.0
}

fn floor(t: f64) -> f64 {
    let i = t as i64 as f64;
    if i > t { i - 1.0 } else { i }
}

fn abs(x: f64) -> f64 {
    if x < 0.0 { -x } else { x }
}

fn log2_pos(x: f64) -> f64 {
    let bits = x.to_bits();
    let mut e = ((bits >> 52) & 0x7ff) as i64 - 1023;
    let mut m = f64::from_bits((bits & 0x000f_ffff_ffff_ffff) | 0x3ff0_0000_0000_0000);
    if m > 1.4142135623730951 {
        m *= 0.5;
        e += 1;
    }
    let s = (m - 1.0) / (m + 1.0);
    let s2 = s * s;
    let series = 1.0 + s2 * (1.0 / 3.0 + s2 * (1.0 / 5.0 + s2 * (1.0 / 7.0 + s2 * (1.0 / 9.0
        + s2 * (1.0 / 11.0 + s2 * (1.0 / 13.0 + s2 * (1.0 / 15.0 + s2 * (1.0 / 17.0
        + s2 * (1.0 / 19.0 + s2 * (1.0 / 21.0))))))))));
    e as f64 + 2.0 * s * series * 1.4426950408889634
}

#[no_mangle]
pub extern "C" fn set_view(cx: f64, cy: f64, scale: f64) -> i32 {
    unsafe { VIEW = (cx, cy, scale) };
    if finite(cx) && finite(cy) && finite(scale) { 0 } else { -1 }
}

#[no_mangle]
pub extern "C" fn fb_ptr() -> i32 {
    unsafe { core::ptr::addr_of!(FRAMEBUFFER) as i32 }
}

#[no_mangle]
pub extern "C" fn fb_cap() -> i32 {
    CAPACITY as i32
}

fn color(fb: &mut [u8], pixel: usize, n: u32, limit: u32, magnitude: f64) {
    let out = &mut fb[pixel * 4..pixel * 4 + 4];
    out.copy_from_slice(&[0, 0, 0, 255]);
    if n == limit {
        return;
    }
    let bounded = if finite(magnitude) {
        if magnitude > 4.000001 { magnitude } else { 4.000001 }
    } else {
        1.0e300
    };
    let smooth = n as f64 + 1.0 - log2_pos(log2_pos(bounded) * 0.5);
    let phase = smooth * 0.025;
    for channel in 0..3 {
        let t = phase + channel as f64 / 3.0;
        let wave = 1.0 - abs(2.0 * (t - floor(t)) - 1.0);
        out[channel] = (wave * 255.0) as u8;
    }
}

#[no_mangle]
pub extern "C" fn render(w: i32, h: i32, max_iter: i32) -> i64 {
    let (cx, cy, scale) = unsafe { VIEW };
    let ok = w > 0 && h > 0 && (w as i64) * (h as i64) <= CAPACITY as i64 && max_iter > 0
        && finite(cx) && finite(cy) && finite(scale);
    if !ok {
        return -1;
    }
    let fb = unsafe { &mut *core::ptr::addr_of_mut!(FRAMEBUFFER) };
    let limit = max_iter.min((1 << 26) - 1) as u32;
    let (wu, hu) = (w as usize, h as usize);
    let mut total: i64 = 0;
    for y in 0..hu {
        let ci = cy + (y as f64 - h as f64 / 2.0) * scale;
        for x in 0..wu {
            let cr = cx + (x as f64 - w as f64 / 2.0) * scale;
            let (mut zr, mut zi) = (0.0f64, 0.0f64);
            let mut n: u32 = 0;
            while n < limit && zr * zr + zi * zi <= 4.0 {
                let next = zr * zr - zi * zi + cr;
                zi = (2.0 * zr) * zi + ci;
                zr = next;
                n += 1;
            }
            total += n as i64;
            color(fb, y * wu + x, n, limit, zr * zr + zi * zi);
        }
    }
    total
}

/// Scalar twin so every kernel answers the same export set.
#[no_mangle]
pub extern "C" fn render_simd(w: i32, h: i32, max_iter: i32) -> i64 {
    render(w, h, max_iter)
}
