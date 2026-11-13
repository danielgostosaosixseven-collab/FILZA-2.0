//! FFI for device-initiated remote pairing (the "pairable host" / responder side).
//!
//! Starting with iOS 27 a device can initiate pairing to a computer instead of the
//! computer initiating pairing to the device. The computer advertises an
//! `_remotepairing-pairable-host._tcp` mDNS service; the device connects to the
//! advertised port and drives the rppairing conversation while this side acts as
//! the SRP server/accessory. We generate a setup PIN and hand it to the caller via
//! a callback; the user types it into the device.
//!
//! This mirrors the host-initiated FFI in [`crate::tunnel_provider`] and the
//! `pair_host` tool in `tools/src/pair_host.rs`.

use std::{
    ffi::{CStr, CString, c_char, c_void},
    net::Ipv4Addr,
    os::fd::FromRawFd,
    ptr::null_mut,
};

use idevice::IdeviceError;
use idevice::remote_pairing::{
    PAIRABLE_HOST_SERVICE_TYPE, PairableHost, PairableHostInfo, PeerDevice, RpPairingFile,
    RpPairingSocket,
};
use mdns_sd::{ServiceDaemon, ServiceInfo};

use crate::rp_pairing_file::RpPairingFileHandle;
use crate::{IdeviceFfiError, ffi_err, run_sync_local};

/// Wrapper so the raw PIN-callback context pointer can cross the async boundary.
struct PinCtx(*mut c_void);
unsafe impl Send for PinCtx {}
unsafe impl Sync for PinCtx {}

/// Opaque state prepared before the iOS Settings app connects to the advertised socket.
pub struct PairableHostHandle {
    host_info: Option<PairableHostInfo>,
    pairing_file: Option<RpPairingFile>,
}

/// C-ABI wrapper for the peer identity returned by a successful pair-setup.
pub struct RpPairingPeerDeviceC(PeerDevice);

/// Generates the host identity, service identifier, and XML-plist TXT records for
/// the caller to publish with its own mDNS implementation.
///
/// The generated `host_alt_irk` must be stored alongside the resulting pairing file.
/// The current `PairableHost` implementation supports PIN-based pairing only;
/// `allows_pinless_pairing` must therefore be false.
///
/// # Safety
/// All required output pointers and `name` must be valid and non-null. `model` and
/// `out_host_alt_irk` may be null. The IRK output must have room for 16 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pairable_host_prepare(
    name: *const c_char,
    model: *const c_char,
    allows_pinless_pairing: bool,
    out_handle: *mut *mut PairableHostHandle,
    out_service_id: *mut *mut c_char,
    out_txt_data: *mut *mut u8,
    out_txt_len: *mut usize,
    out_host_alt_irk: *mut u8,
) -> *mut IdeviceFfiError {
    if name.is_null()
        || out_handle.is_null()
        || out_service_id.is_null()
        || out_txt_data.is_null()
        || out_txt_len.is_null()
    {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    unsafe {
        *out_handle = null_mut();
        *out_service_id = null_mut();
        *out_txt_data = null_mut();
        *out_txt_len = 0;
    }

    if allows_pinless_pairing {
        return ffi_err!(IdeviceError::InternalError(
            "pinless pairing is not supported by this PairableHost implementation".into(),
        ));
    }

    let name = match unsafe { CStr::from_ptr(name) }.to_str() {
        Ok(value) => value.to_owned(),
        Err(_) => return ffi_err!(IdeviceError::FfiInvalidString),
    };
    let model = if model.is_null() {
        "Mac17,7".to_owned()
    } else {
        match unsafe { CStr::from_ptr(model) }.to_str() {
            Ok(value) => value.to_owned(),
            Err(_) => return ffi_err!(IdeviceError::FfiInvalidString),
        }
    };

    let pairing_file = RpPairingFile::generate(&name);
    let host_info = PairableHostInfo::generate(&name, &model);
    let service_identifier = pairing_file.identifier.clone();
    let txt_records = host_info
        .mdns_txt_records(&service_identifier)
        .into_iter()
        .map(|(key, value)| (key, plist::Value::String(value)))
        .collect::<plist::Dictionary>();

    let mut txt_data = Vec::new();
    if let Err(error) = plist::to_writer_xml(
        &mut txt_data,
        &plist::Value::Dictionary(txt_records),
    ) {
        return ffi_err!(IdeviceError::InternalError(format!(
            "serialize pairable-host TXT plist: {error}"
        )));
    }
    let service_id = match CString::new(service_identifier) {
        Ok(value) => value,
        Err(_) => {
            return ffi_err!(IdeviceError::InternalError(
                "pairable-host service identifier contains a NUL byte".into(),
            ));
        }
    };

    let service_id_ptr = service_id.into_raw();
    // `idevice_data_free` reconstructs a Vec with capacity == length. Converting
    // through Box<[u8]> gives the allocation exactly that layout.
    let mut txt_data = txt_data.into_boxed_slice().into_vec();
    let txt_len = txt_data.len();
    let txt_ptr = txt_data.as_mut_ptr();
    std::mem::forget(txt_data);

    if !out_host_alt_irk.is_null() {
        unsafe {
            std::ptr::copy_nonoverlapping(host_info.alt_irk.as_ptr(), out_host_alt_irk, 16);
        }
    }
    unsafe {
        *out_service_id = service_id_ptr;
        *out_txt_data = txt_ptr;
        *out_txt_len = txt_len;
        *out_handle = Box::into_raw(Box::new(PairableHostHandle {
            host_info: Some(host_info),
            pairing_file: Some(pairing_file),
        }));
    }
    null_mut()
}

/// Backwards-compatible alias for callers using AltStore's original function name.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pairable_host_new(
    name: *const c_char,
    model: *const c_char,
    out_handle: *mut *mut PairableHostHandle,
    out_service_id: *mut *mut c_char,
    out_txt_data: *mut *mut u8,
    out_txt_len: *mut usize,
) -> *mut IdeviceFfiError {
    unsafe {
        pairable_host_prepare(
            name,
            model,
            false,
            out_handle,
            out_service_id,
            out_txt_data,
            out_txt_len,
            null_mut(),
        )
    }
}

/// Runs device-initiated pair-setup against an already accepted TCP socket.
/// The fd is duplicated, leaving ownership of the caller's descriptor unchanged.
///
/// # Safety
/// `handle` must come from `pairable_host_prepare`/`pairable_host_new`, `fd` must
/// be a valid connected TCP socket, and `out_pairing_file` must be valid/non-null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pairable_host_accept_fd(
    handle: *mut PairableHostHandle,
    fd: i32,
    pin_callback: Option<extern "C" fn(pin: *const c_char, context: *mut c_void)>,
    pin_context: *mut c_void,
    out_peer_device: *mut *mut RpPairingPeerDeviceC,
    out_pairing_file: *mut *mut RpPairingFileHandle,
) -> *mut IdeviceFfiError {
    if handle.is_null() || fd < 0 || out_pairing_file.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    unsafe {
        *out_pairing_file = null_mut();
        if !out_peer_device.is_null() {
            *out_peer_device = null_mut();
        }
    }

    let duplicate_fd = unsafe { libc::dup(fd) };
    if duplicate_fd < 0 {
        return ffi_err!(IdeviceError::InternalError(format!(
            "duplicate accepted RemotePairing socket: {}",
            std::io::Error::last_os_error()
        )));
    }

    let host_handle = unsafe { &mut *handle };
    let Some(host_info) = host_handle.host_info.take() else {
        unsafe { libc::close(duplicate_fd) };
        return ffi_err!(IdeviceError::InternalError(
            "pairable-host handle has already been used".into(),
        ));
    };
    let Some(mut pairing_file) = host_handle.pairing_file.take() else {
        unsafe { libc::close(duplicate_fd) };
        return ffi_err!(IdeviceError::InternalError(
            "pairable-host pairing file is unavailable".into(),
        ));
    };

    let ctx = PinCtx(pin_context);
    let result = run_sync_local(async move {
        let std_stream = unsafe { std::net::TcpStream::from_raw_fd(duplicate_fd) };
        std_stream
            .set_nonblocking(true)
            .map_err(|error| IdeviceError::InternalError(format!("set socket nonblocking: {error}")))?;
        let stream = tokio::net::TcpStream::from_std(std_stream)
            .map_err(|error| IdeviceError::InternalError(format!("adopt accepted socket: {error}")))?;
        let mut host = PairableHost::new(RpPairingSocket::new_device(stream), host_info);
        let peer_device = host
            .accept(&mut pairing_file, |pin| async move {
                if let Some(callback) = pin_callback
                    && let Ok(c_pin) = CString::new(pin)
                {
                    callback(c_pin.as_ptr(), ctx.0);
                }
            })
            .await?;
        Ok::<_, IdeviceError>((pairing_file, peer_device))
    });

    match result {
        Ok((pairing_file, peer_device)) => {
            unsafe {
                *out_pairing_file = Box::into_raw(Box::new(RpPairingFileHandle(pairing_file)));
                if !out_peer_device.is_null() {
                    *out_peer_device = Box::into_raw(Box::new(RpPairingPeerDeviceC(peer_device)));
                }
            }
            null_mut()
        }
        Err(error) => ffi_err!(error),
    }
}

/// Backwards-compatible alias for callers using AltStore's original function name.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pairable_host_handshake(
    handle: *mut PairableHostHandle,
    fd: i32,
    pin_callback: Option<extern "C" fn(pin: *const c_char, context: *mut c_void)>,
    pin_context: *mut c_void,
    out_pairing_file: *mut *mut RpPairingFileHandle,
) -> *mut IdeviceFfiError {
    unsafe {
        pairable_host_accept_fd(
            handle,
            fd,
            pin_callback,
            pin_context,
            null_mut(),
            out_pairing_file,
        )
    }
}

/// Frees a pairable-host handle; null is accepted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pairable_host_free(handle: *mut PairableHostHandle) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// Frees a peer-device identity returned by `pairable_host_accept_fd`; null is accepted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rppairing_peer_device_free(peer_device: *mut RpPairingPeerDeviceC) {
    if !peer_device.is_null() {
        drop(unsafe { Box::from_raw(peer_device) });
    }
}

/// Advertises this computer as a pairable host and accepts a single device-initiated
/// pairing.
///
/// This blocks the calling thread until a device discovers the advertised
/// `_remotepairing-pairable-host._tcp` service, connects, and the pairing either
/// completes or fails. While the pairing is in progress `pin_callback` is invoked
/// once with the 6-digit setup code that the user must type into the device.
///
/// On success a freshly generated [`RpPairingFileHandle`] is written to
/// `out_pairing_file`; it carries this host's long-term keys plus the paired
/// device's `altIRK`. Persist it (and `out_host_alt_irk`, see below) so the device
/// keeps recognizing this host on future connections.
///
/// # Arguments
/// * `name` - human-readable name shown on the device (e.g. "Jackson's MacBook Pro").
/// * `model` - hardware model identifier shown on the device. `NULL` defaults to
///   `"Mac17,7"`. iOS treats the host as a computer, so keep this a Mac identifier.
/// * `port` - TCP port to listen on. `0` picks a free port.
/// * `pin_callback` - invoked with the setup PIN to display. May be `NULL`.
/// * `pin_context` - opaque pointer passed back to `pin_callback`.
/// * `out_host_alt_irk` - optional. If non-NULL, must point to a 16-byte buffer that
///   receives the host's generated `altIRK` (needed to re-advertise this host so an
///   already-paired device recognizes it). May be `NULL`.
/// * `out_pairing_file` - receives the resulting pairing file on success.
///
/// # Safety
/// `name` must be a valid null-terminated C string. `model` must be NULL or a valid
/// null-terminated C string. `out_host_alt_irk` must be NULL or point to at least 16
/// writable bytes. `out_pairing_file` must be valid and non-null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pairable_host_accept(
    name: *const c_char,
    model: *const c_char,
    port: u16,
    pin_callback: Option<extern "C" fn(pin: *const c_char, context: *mut c_void)>,
    pin_context: *mut c_void,
    out_host_alt_irk: *mut u8,
    out_pairing_file: *mut *mut RpPairingFileHandle,
) -> *mut IdeviceFfiError {
    if name.is_null() || out_pairing_file.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let name = match unsafe { CStr::from_ptr(name) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return ffi_err!(IdeviceError::FfiInvalidString),
    };
    let model = if model.is_null() {
        "Mac17,7".to_string()
    } else {
        match unsafe { CStr::from_ptr(model) }.to_str() {
            Ok(s) => s.to_string(),
            Err(_) => return ffi_err!(IdeviceError::FfiInvalidString),
        }
    };

    let ctx = PinCtx(pin_context);

    let res = run_sync_local(async move {
        // Bind first so we can advertise the real port.
        let listener = tokio::net::TcpListener::bind((Ipv4Addr::UNSPECIFIED, port))
            .await
            .map_err(|e| IdeviceError::InternalError(format!("bind: {e}")))?;
        let port = listener
            .local_addr()
            .map_err(|e| IdeviceError::InternalError(format!("{e}")))?
            .port();

        let mut pairing_file = RpPairingFile::generate(&name);
        let host_info = PairableHostInfo::generate(&name, &model);
        let host_alt_irk = host_info.alt_irk;
        let service_identifier = pairing_file.identifier.clone();

        // Advertise the pairable-host mDNS service so the device can find us.
        let mdns = ServiceDaemon::new()
            .map_err(|e| IdeviceError::InternalError(format!("mDNS daemon: {e}")))?;
        // Apple's instance names exceed the default cap.
        let _ = mdns.set_service_name_len_max(30);
        let hostname = format!("idevice-{}.local.", &service_identifier[..8]);
        let txt = host_info.mdns_txt_records(&service_identifier);
        let properties: Vec<(&str, &str)> =
            txt.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        let service_info = ServiceInfo::new(
            PAIRABLE_HOST_SERVICE_TYPE,
            &service_identifier,
            &hostname,
            "",
            port,
            &properties[..],
        )
        .map_err(|e| IdeviceError::InternalError(format!("mDNS service info: {e}")))?
        .enable_addr_auto();
        mdns.register(service_info)
            .map_err(|e| IdeviceError::InternalError(format!("mDNS register: {e}")))?;

        // Wait for a device to connect and start pairing.
        let (stream, _peer) = listener
            .accept()
            .await
            .map_err(|e| IdeviceError::InternalError(format!("accept: {e}")))?;

        let socket = RpPairingSocket::new_device(stream);
        let mut host = PairableHost::new(socket, host_info);

        host.accept(&mut pairing_file, |pin| async move {
            if let Some(cb) = pin_callback
                && let Ok(cpin) = CString::new(pin)
            {
                cb(cpin.as_ptr(), ctx.0);
            }
        })
        .await?;

        Ok::<_, IdeviceError>((pairing_file, host_alt_irk))
    });

    match res {
        Ok((rpf, host_alt_irk)) => {
            if !out_host_alt_irk.is_null() {
                unsafe {
                    std::ptr::copy_nonoverlapping(host_alt_irk.as_ptr(), out_host_alt_irk, 16);
                }
            }
            unsafe { *out_pairing_file = Box::into_raw(Box::new(RpPairingFileHandle(rpf))) };
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}
