use std::ffi::CStr;

unsafe extern "C" {
    #[allow(non_snake_case)]
    fn ALGetGrappaToken(
        in_version: u32,
        in_device_type: u32,
        in_protocol_version: u32,
        out_buf: *mut u8,
        max_len: usize,
        out_len: *mut usize,
        err_buf: *mut libc::c_char,
        err_len: usize,
    ) -> libc::c_int;
}

/// Generate an authentic Grappa client token for AirTraffic sync.
///
/// Calls the Objective-C implementation in `GrappaHelper.m` directly. The native
/// linker must resolve this symbol when building the app, so runtime symbol
/// visibility and `dlsym(RTLD_DEFAULT)` are not required.
pub fn generate_grappa_token<F: Fn(&str)>(
    device_info: Option<(u32, u32, u32)>,
    log: F,
) -> Option<Vec<u8>> {
    let (ver, dt, pv) = device_info.unwrap_or((1, 0, 1));
    let mut buf = vec![0u8; 512];
    let mut out_len: usize = 0;
    let mut err_buf = [0 as libc::c_char; 256];

    let rc = unsafe {
        ALGetGrappaToken(
            ver,
            dt,
            pv,
            buf.as_mut_ptr(),
            buf.len(),
            &mut out_len,
            err_buf.as_mut_ptr(),
            err_buf.len(),
        )
    };

    if rc != 0 || out_len == 0 {
        let err_str = unsafe { CStr::from_ptr(err_buf.as_ptr()) }.to_string_lossy();
        log(&format!("airlift: grappa: token generation failed (rc={rc}): {err_str}"));
        return None;
    }

    buf.truncate(out_len);
    log(&format!("airlift: grappa: successfully generated authentic Grappa token ({out_len} bytes)"));
    Some(buf)
}
