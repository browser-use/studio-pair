use std::{
    ffi::{c_char, c_void, CStr, CString},
    fs::OpenOptions,
    io::{self, BufRead, Write},
    os::fd::AsRawFd,
    ptr,
    sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering::*},
    thread,
    time::{Duration, Instant},
};

#[repr(C)]
#[derive(Clone, Copy)]
struct Device {
    id: u32,
    channels: u32,
    mute: u32,
    running: u32,
    volume: f32,
    rate: f64,
    uid: [c_char; 512],
}
#[repr(C)]
#[derive(Clone, Copy)]
struct Buffer {
    channels: u32,
    bytes: u32,
    data: *mut f32,
}
#[repr(C)]
struct BufferList {
    count: u32,
    buffers: [Buffer; 1],
}
type Callback = unsafe extern "C" fn(
    u32,
    *const c_void,
    *const BufferList,
    *const c_void,
    *mut BufferList,
    *const c_void,
    *mut c_void,
) -> i32;
extern "C" {
    fn sp_error() -> *const c_char;
    fn sp_default_output() -> u32;
    fn sp_displays(out: *mut Device, capacity: i32) -> i32;
    fn sp_inspect();
    fn sp_create(a: u32, b: u32, bundle: *const c_char, pid: i32) -> *mut c_void;
    fn sp_validate(pair: *mut c_void) -> i32;
    fn sp_tap_mute(pair: *mut c_void, mode: i32) -> i32;
    fn sp_start(pair: *mut c_void, callback: Callback, context: *mut c_void) -> i32;
    fn sp_destroy(pair: *mut c_void);
    fn sp_journal_begin(path: *const c_char, secondary: u32) -> i32;
    fn sp_sync_volume(anchor: u32, secondary: u32) -> i32;
    fn sp_restore(path: *const c_char, stop: i32) -> i32;
    fn sp_tone_start(device: u32, callback: Callback, context: *mut c_void) -> *mut c_void;
    fn sp_tone_stop(tone: *mut c_void);
    fn flock(fd: i32, op: i32) -> i32;
    fn signal(sig: i32, handler: usize) -> usize;
    fn getppid() -> i32;
    fn _exit(code: i32) -> !;
}
static STOP: AtomicBool = AtomicBool::new(false);
static SWAP: AtomicBool = AtomicBool::new(false);
static ENABLED: AtomicBool = AtomicBool::new(false);
static CALLBACKS: AtomicU64 = AtomicU64::new(0);
static BAD: AtomicBool = AtomicBool::new(false);
static PEAK: AtomicU32 = AtomicU32::new(0);
static OUT_PEAK: AtomicU32 = AtomicU32::new(0);
static HEARTBEAT: AtomicU64 = AtomicU64::new(0);
extern "C" fn stop_signal(_: i32) {
    STOP.store(true, Relaxed);
}
fn error() -> String {
    unsafe { CStr::from_ptr(sp_error()).to_string_lossy().into_owned() }
}
fn check(value: i32) -> Result<(), String> {
    if value != 0 {
        Ok(())
    } else {
        Err(error())
    }
}
fn status(message: &str) {
    println!("{message}");
    let _ = io::stdout().flush();
}

// CoreAudio supplies the buffer descriptors. Reject unexpected shapes before reading data.
unsafe fn buffers<'a>(list: *const BufferList) -> Option<&'a [Buffer]> {
    if list.is_null() || (*list).count > 32 {
        return None;
    }
    Some(std::slice::from_raw_parts(
        ptr::addr_of!((*list).buffers).cast(),
        (*list).count as usize,
    ))
}
fn shape(bs: &[Buffer], expected: usize) -> Option<usize> {
    let mut channels = 0;
    let mut frames = None;
    for b in bs {
        let c = b.channels as usize;
        if c == 0
            || c > 32
            || b.data.is_null()
            || b.bytes == 0
            || !(b.bytes as usize).is_multiple_of(4 * c)
        {
            return None;
        }
        let n = b.bytes as usize / (4 * c);
        if n > 8192 || frames.is_some_and(|v| v != n) {
            return None;
        }
        frames = Some(n);
        channels += c;
    }
    if channels == expected {
        frames
    } else {
        None
    }
}
unsafe fn clear(bs: &[Buffer]) {
    for b in bs {
        if !b.data.is_null() && b.bytes <= 32 * 8192 * 4 {
            ptr::write_bytes(b.data.cast::<u8>(), 0, b.bytes as usize);
        }
    }
}
unsafe fn sample(bs: &[Buffer], channel: usize, frame: usize) -> f32 {
    let mut offset = 0;
    for b in bs {
        let c = b.channels as usize;
        if channel < offset + c {
            return *b.data.add(frame * c + channel - offset);
        }
        offset += c;
    }
    0.0
}
unsafe fn put(bs: &[Buffer], channel: usize, frame: usize, value: f32) {
    let mut offset = 0;
    for b in bs {
        let c = b.channels as usize;
        if channel < offset + c {
            *b.data.add(frame * c + channel - offset) = value;
            return;
        }
        offset += c;
    }
}
fn bounded(x: f32) -> f32 {
    if x.is_finite() {
        x.clamp(-1.0, 1.0)
    } else {
        0.0
    }
}
struct Router {
    gain: f32,
}
impl Router {
    unsafe fn render(
        &mut self,
        input: &[Buffer],
        output: &[Buffer],
        enabled: bool,
        swap: bool,
    ) -> bool {
        clear(output);
        let Some(frames) = shape(output, 16) else {
            return false;
        };
        if shape(input, 8) != Some(frames) {
            return false;
        }
        let mut peak = 0.0f32;
        let mut out_peak = 0.0f32;
        for frame in 0..frames {
            let left = bounded(sample(input, 0, frame));
            let right = bounded(sample(input, 1, frame));
            peak = peak.max(left.abs()).max(right.abs());
            let target = if enabled { 0.5 } else { 0.0 };
            self.gain += (target - self.gain).clamp(-1.0 / 4800.0, 1.0 / 4800.0);
            let (a, b) = if swap { (right, left) } else { (left, right) };
            for c in [0, 1] {
                put(output, c, frame, a * self.gain);
            }
            for c in [8, 9] {
                put(output, c, frame, b * self.gain);
            }
            out_peak = out_peak.max(a.abs() * self.gain).max(b.abs() * self.gain);
        }
        PEAK.fetch_max(peak.to_bits(), Relaxed);
        OUT_PEAK.fetch_max(out_peak.to_bits(), Relaxed);
        true
    }
}
unsafe extern "C" fn route(
    _: u32,
    _: *const c_void,
    input: *const BufferList,
    _: *const c_void,
    output: *mut BufferList,
    _: *const c_void,
    context: *mut c_void,
) -> i32 {
    let Some(out) = buffers(output) else {
        BAD.store(true, Relaxed);
        return 0;
    };
    let valid = match buffers(input) {
        Some(ib) => {
            (*context.cast::<Router>()).render(ib, out, ENABLED.load(Relaxed), SWAP.load(Relaxed))
        }
        None => {
            clear(out);
            false
        }
    };
    if !valid {
        BAD.store(true, Relaxed);
    }
    CALLBACKS.fetch_add(1, Relaxed);
    0
}
struct Tone {
    frame: u64,
    frames: u64,
    stereo: bool,
}
unsafe extern "C" fn tone(
    _: u32,
    _: *const c_void,
    _: *const BufferList,
    _: *const c_void,
    output: *mut BufferList,
    _: *const c_void,
    context: *mut c_void,
) -> i32 {
    let Some(out) = buffers(output) else {
        return 0;
    };
    clear(out);
    let Some(n) = shape(out, 8) else {
        BAD.store(true, Relaxed);
        return 0;
    };
    let t = &mut *context.cast::<Tone>();
    for i in 0..n {
        if t.frame < t.frames {
            let fade = (t.frame.min(t.frames - t.frame) as f32 / 2400.0).min(1.0);
            let phase = t.frame as f64 / 48000.0 * std::f64::consts::TAU;
            put(out, 0, i, (phase * 440.0).sin() as f32 * 0.06 * fade);
            put(
                out,
                1,
                i,
                (phase * if t.stereo { 660.0 } else { 440.0 }).sin() as f32 * 0.06 * fade,
            );
        }
        t.frame += 1;
    }
    CALLBACKS.fetch_add(1, Relaxed);
    0
}
struct Pair(*mut c_void);
impl Drop for Pair {
    fn drop(&mut self) {
        unsafe { sp_destroy(self.0) }
    }
}
fn displays() -> Result<[Device; 2], String> {
    let mut out: [Device; 2] = unsafe { std::mem::zeroed() };
    if unsafe { sp_displays(out.as_mut_ptr(), 2) } != 2 {
        return Err("Exactly two Studio Displays are required".into());
    }
    Ok(out)
}
fn watch(parent: i32, limit: Option<Duration>) {
    thread::spawn(move || {
        let start = Instant::now();
        let mut last = 0;
        let mut progress = Instant::now();
        loop {
            thread::sleep(Duration::from_millis(250));
            let now = HEARTBEAT.load(Relaxed);
            if now != last {
                last = now;
                progress = Instant::now();
            }
            if (parent > 0 && unsafe { getppid() } != parent)
                || limit.is_some_and(|limit| start.elapsed() > limit)
            {
                STOP.store(true, Relaxed);
            }
            // A stuck HAL call cannot retain a muted tap forever. Process death releases private resources.
            if progress.elapsed() > Duration::from_secs(12)
                || limit.is_some_and(|limit| start.elapsed() > limit + Duration::from_secs(6))
            {
                unsafe { _exit(70) }
            }
        }
    });
}
fn run(
    path: &str,
    seconds: u64,
    parent: i32,
    bundle: &str,
    pid: i32,
    swap: bool,
) -> Result<(), String> {
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(format!("{path}.lock"))
        .map_err(|e| e.to_string())?;
    if unsafe { flock(lock.as_raw_fd(), 2 | 4) } != 0 {
        return Err("A stereo route is already running".into());
    }
    let path = CString::new(path).map_err(|e| e.to_string())?;
    unsafe {
        check(sp_restore(path.as_ptr(), 0))?;
    }
    let ds = displays()?;
    let anchor = unsafe { sp_default_output() };
    let (a, b) = if ds[0].id == anchor {
        (ds[0].id, ds[1].id)
    } else if ds[1].id == anchor {
        (ds[1].id, ds[0].id)
    } else {
        return Err("Select one Studio Display as normal output before pairing".into());
    };
    SWAP.store(swap, Relaxed);
    // Zero means continuous operation. Stall and parent-death watchdogs remain enabled.
    watch(parent, (seconds > 0).then(|| Duration::from_secs(seconds)));
    if parent > 0 {
        thread::spawn(|| {
            for line in io::stdin().lock().lines() {
                match line.as_deref() {
                    Ok("stop") => break,
                    Ok("swap") => {
                        SWAP.fetch_xor(true, Relaxed);
                    }
                    _ => {}
                }
            }
            STOP.store(true, Relaxed);
        });
    }
    status("{\"state\":\"preparing\"}");
    let bundle = CString::new(bundle).map_err(|e| e.to_string())?;
    let raw = unsafe { sp_create(a, b, bundle.as_ptr(), pid) };
    if raw.is_null() {
        return Err(error());
    }
    // Drop the CoreAudio route before its callback context on every error path.
    let mut router = Box::new(Router { gain: 0.0 });
    let pair = Pair(raw);
    let mut ready = false;
    for _ in 0..20 {
        HEARTBEAT.fetch_add(1, Relaxed);
        if unsafe { sp_validate(pair.0) } != 0 {
            ready = true;
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    if !ready {
        return Err(error());
    }
    unsafe {
        check(sp_journal_begin(path.as_ptr(), b))?;
        check(sp_start(
            pair.0,
            route,
            (&mut *router as *mut Router).cast(),
        ))?;
    }
    status("{\"state\":\"warming\"}");
    let start = Instant::now();
    let mut active = false;
    let mut seen = 0;
    let mut last_io = Instant::now();
    let mut result = Ok(());
    loop {
        thread::sleep(Duration::from_millis(100));
        HEARTBEAT.fetch_add(1, Relaxed);
        if STOP.load(Relaxed) {
            break;
        }
        let count = CALLBACKS.load(Relaxed);
        if count != seen {
            seen = count;
            last_io = Instant::now();
        }
        if BAD.load(Relaxed) {
            result = Err("Unexpected audio buffer; returned to direct playback".into());
            break;
        }
        if last_io.elapsed() > Duration::from_secs(3) {
            result = Err("Audio callbacks stalled; returned to direct playback".into());
            break;
        }
        if unsafe { sp_default_output() } != anchor {
            result = Err("Output changed; returned to direct playback".into());
            break;
        }
        if !active {
            if count >= 10 && f32::from_bits(PEAK.load(Relaxed)) > 0.000001 {
                unsafe {
                    if let Err(e) =
                        check(sp_sync_volume(a, b)).and_then(|_| check(sp_tap_mute(pair.0, 2)))
                    {
                        result = Err(e);
                        break;
                    }
                }
                ENABLED.store(true, Relaxed);
                active = true;
            } else if start.elapsed() > Duration::from_secs(10) {
                result = Err(
                    "No captured music. Playback or macOS audio-capture permission is missing"
                        .into(),
                );
                break;
            }
        } else if let Err(e) = unsafe { check(sp_sync_volume(a, b)) } {
            result = Err(e);
            break;
        }
        if HEARTBEAT.load(Relaxed).is_multiple_of(10) {
            let peak = f32::from_bits(PEAK.swap(0, Relaxed));
            let out = f32::from_bits(OUT_PEAK.swap(0, Relaxed));
            status(&format!("{{\"state\":\"{}\",\"callbacks\":{},\"input_peak\":{},\"output_peak\":{},\"anchor\":{},\"secondary\":{},\"swapped\":{}}}",if active{"playing"}else{"warming"},count,peak,out,a,b,SWAP.load(Relaxed)));
        }
    }
    ENABLED.store(false, Relaxed);
    thread::sleep(Duration::from_millis(60));
    drop(pair);
    drop(router);
    unsafe {
        if let Err(e) = check(sp_restore(path.as_ptr(), 0)) {
            result = Err(e);
        }
    }
    status("{\"state\":\"stopped\"}");
    result
}
fn main() {
    unsafe {
        signal(2, stop_signal as usize);
        signal(15, stop_signal as usize);
        signal(13, 1);
    }
    let args: Vec<String> = std::env::args().collect();
    let result = (|| -> Result<(), String> {
        match args.get(1).map(String::as_str){
        Some("inspect")=>{unsafe{sp_inspect();}Ok(())},
        Some("restore")=>{let path=CString::new(args.get(2).ok_or("journal path required")?.as_str()).unwrap();unsafe{check(sp_restore(path.as_ptr(),1))}},
        Some("run") if args.len()==8=>run(&args[2],args[3].parse().map_err(|_|"seconds")?,args[4].parse().map_err(|_|"parent")?,&args[5],args[6].parse().map_err(|_|"pid")?,args[7]=="1"),
        Some("tone")=>{
            let ds=displays()?;let id=args.get(2).ok_or("device id required")?.parse::<u32>().map_err(|_|"device id")?;
            if !ds.iter().any(|d|d.id==id){return Err("Tone device must be a connected Studio Display".into());}
            let seconds=args.get(3).and_then(|s|s.parse::<f64>().ok()).unwrap_or(1.0).clamp(0.1,120.0);
            let mut state=Box::new(Tone{frame:0,frames:(seconds*48000.0) as u64,stereo:args.get(4).is_some_and(|s|s=="stereo")});
            watch(0,Some(Duration::from_secs_f64(seconds+2.0)));
            let handle=unsafe{sp_tone_start(id,tone,(&mut *state as *mut Tone).cast())};if handle.is_null(){return Err(error());}
            status(&format!("{{\"state\":\"tone\",\"pid\":{},\"device\":{id}}}",std::process::id()));
            let start=Instant::now();while start.elapsed().as_secs_f64()<seconds&&!STOP.load(Relaxed){HEARTBEAT.fetch_add(1,Relaxed);thread::sleep(Duration::from_millis(100));}
            unsafe{sp_tone_stop(handle);}if BAD.load(Relaxed){Err("Unexpected tone buffer".into())}else{Ok(())}
        },
        _=>Err("Usage: inspect | restore JOURNAL | tone DEVICE [SECONDS] [stereo] | run JOURNAL SECONDS PARENT BUNDLE PID SWAP (SECONDS=0 for continuous)".into())
    }
    })();
    if let Err(e) = result {
        eprintln!("Studio Pair: {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn buffer(samples: &mut [f32], channels: u32) -> Buffer {
        Buffer {
            channels,
            bytes: (samples.len() * 4) as u32,
            data: samples.as_mut_ptr(),
        }
    }
    #[test]
    fn channel_isolation_for_interleaved_and_planar_audio() {
        unsafe {
            let mut input = [0.8, -0.4, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0];
            let mut out = [99.0; 16];
            let mut r = Router { gain: 0.5 };
            assert!(r.render(
                &[buffer(&mut input, 8)],
                &[buffer(&mut out, 16)],
                true,
                false
            ));
            assert_eq!(
                out,
                [
                    0.4, 0.4, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -0.2, -0.2, 0.0, 0.0, 0.0, 0.0, 0.0,
                    0.0
                ]
            );
            let mut left = [0.8];
            let mut right = [-0.4];
            let mut unused = [1.0; 6];
            let mut a = [99.0; 8];
            let mut b = [99.0; 8];
            assert!(r.render(
                &[
                    buffer(&mut left, 1),
                    buffer(&mut right, 1),
                    buffer(&mut unused, 6)
                ],
                &[buffer(&mut a, 8), buffer(&mut b, 8)],
                true,
                true
            ));
            assert_eq!(a, [-0.2, -0.2, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]);
            assert_eq!(b, [0.4, 0.4, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]);
        }
    }
    #[test]
    fn warmup_is_silent_and_invalid_buffers_fail_closed() {
        unsafe {
            let mut input = [1.0; 16];
            let mut out = [99.0; 32];
            let mut r = Router { gain: 0.0 };
            assert!(r.render(
                &[buffer(&mut input, 8)],
                &[buffer(&mut out, 16)],
                false,
                false
            ));
            assert!(out.iter().all(|v| *v == 0.0));
            out.fill(99.0);
            assert!(!r.render(
                &[buffer(&mut input[..8], 8)],
                &[buffer(&mut out, 16)],
                true,
                false
            ));
            assert!(out.iter().all(|v| *v == 0.0));
        }
    }
    #[test]
    fn bad_samples_are_bounded_and_handoff_ramps() {
        unsafe {
            let mut input = [
                f32::NAN,
                f32::INFINITY,
                0.0,
                0.0,
                0.0,
                0.0,
                0.0,
                0.0,
                4.0,
                -4.0,
                0.0,
                0.0,
                0.0,
                0.0,
                0.0,
                0.0,
            ];
            let mut out = [0.0; 32];
            let mut r = Router { gain: 0.5 };
            assert!(r.render(
                &[buffer(&mut input, 8)],
                &[buffer(&mut out, 16)],
                true,
                false
            ));
            assert!(out.iter().all(|v| v.is_finite() && v.abs() <= 0.5));
            assert_eq!(out[16], 0.5);
            assert_eq!(out[24], -0.5);
            assert_eq!(out[0], 0.0);
            let mut input = [1.0; 38400];
            let mut out = [0.0; 76800];
            let mut r = Router { gain: 0.0 };
            assert!(r.render(
                &[buffer(&mut input, 8)],
                &[buffer(&mut out, 16)],
                true,
                false
            ));
            assert!(out[0] < 0.001);
            assert_eq!(out[4799 * 16], 0.5);
            assert!(r.render(
                &[buffer(&mut input, 8)],
                &[buffer(&mut out, 16)],
                false,
                false
            ));
            assert_eq!(out[4799 * 16], 0.0);
        }
    }
}
