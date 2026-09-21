//! C ABI for [`wonder_relay`].
//!
//! The ABI owns opaque handshake and session handles. Callers must release every
//! successful handle with its matching `*_free` function. Private keys and
//! identity bytes are borrowed only for the duration of each call; applications
//! remain responsible for secure key storage and authorization.

use std::{ffi::c_void, panic::AssertUnwindSafe, ptr, slice, str};

use wonder_relay::{
    EndpointConfig, Initiator, RelayError, Responder, Session, SessionContext,
    FRAME_LENGTH_PREFIX_SIZE, MAX_FRAME_SIZE, MAX_PAYLOAD_SIZE, STATIC_KEY_LENGTH,
    TRANSPORT_TAG_LENGTH,
};

const OK: i32 = 0;
const INVALID_ARGUMENT: i32 = 1;
const INVALID_KEY: i32 = 2;
const INVALID_STATE: i32 = 3;
const BUFFER_TOO_SMALL: i32 = 4;
const AUTHENTICATION_FAILED: i32 = 5;
const MESSAGE_TOO_LARGE: i32 = 6;
const INVALID_FRAME: i32 = 7;
const INTERNAL_ERROR: i32 = 255;
const MAX_HANDSHAKE_SIZE: usize = 1024;

fn guarded(function: impl FnOnce() -> i32) -> i32 {
    std::panic::catch_unwind(AssertUnwindSafe(function)).unwrap_or(INTERNAL_ERROR)
}

fn map_error(error: RelayError) -> i32 {
    match error {
        RelayError::InvalidFrame => INVALID_FRAME,
        RelayError::InvalidHandshakeMessage => AUTHENTICATION_FAILED,
        RelayError::MessageTooLarge { .. } => MESSAGE_TOO_LARGE,
        RelayError::ContextFieldTooLarge { .. }
        | RelayError::EmptyContextIdentity { .. }
        | RelayError::UnsupportedProtocolVersion { .. } => INVALID_ARGUMENT,
        RelayError::SessionPoisoned => INVALID_STATE,
        RelayError::InvalidGeneratedKeyMaterial => INTERNAL_ERROR,
        RelayError::Noise(error) => match error {
            snow::Error::Decrypt | snow::Error::Dh => AUTHENTICATION_FAILED,
            snow::Error::Input => INVALID_ARGUMENT,
            snow::Error::State(_) => INVALID_STATE,
            _ => INTERNAL_ERROR,
        },
    }
}

unsafe fn input_bytes<'a>(pointer: *const u8, length: usize) -> Result<&'a [u8], i32> {
    if length == 0 {
        Ok(&[])
    } else if pointer.is_null() {
        Err(INVALID_ARGUMENT)
    } else {
        // SAFETY: the caller supplied a non-null pointer and length for this ABI call.
        Ok(unsafe { slice::from_raw_parts(pointer, length) })
    }
}

unsafe fn output_bytes<'a>(pointer: *mut u8, capacity: usize) -> Result<&'a mut [u8], i32> {
    if capacity == 0 {
        // SAFETY: dangling is non-null, aligned, and valid for a zero-length slice.
        Ok(unsafe { slice::from_raw_parts_mut(ptr::NonNull::<u8>::dangling().as_ptr(), 0) })
    } else if pointer.is_null() {
        Err(INVALID_ARGUMENT)
    } else {
        // SAFETY: the caller supplied a non-null pointer and capacity for this ABI call.
        Ok(unsafe { slice::from_raw_parts_mut(pointer, capacity) })
    }
}

unsafe fn key<'a>(pointer: *const u8, length: usize) -> Result<&'a [u8; STATIC_KEY_LENGTH], i32> {
    if length != STATIC_KEY_LENGTH {
        return Err(INVALID_KEY);
    }
    let bytes = unsafe { input_bytes(pointer, length) }?;
    bytes.try_into().map_err(|_| INVALID_KEY)
}

unsafe fn identity<'a>(pointer: *const u8, length: usize) -> Result<&'a str, i32> {
    let bytes = unsafe { input_bytes(pointer, length) }?;
    str::from_utf8(bytes).map_err(|_| INVALID_ARGUMENT)
}

#[allow(clippy::too_many_arguments)]
unsafe fn config<'a>(
    local_private_key: *const u8,
    local_private_key_len: usize,
    peer_public_key: *const u8,
    peer_public_key_len: usize,
    host_identity: *const u8,
    host_identity_len: usize,
    device_identity: *const u8,
    device_identity_len: usize,
    routing_identity: *const u8,
    routing_identity_len: usize,
) -> Result<EndpointConfig<'a>, i32> {
    let local = unsafe { key(local_private_key, local_private_key_len) }?;
    let peer = unsafe { key(peer_public_key, peer_public_key_len) }?;
    let host = unsafe { identity(host_identity, host_identity_len) }?;
    let device = unsafe { identity(device_identity, device_identity_len) }?;
    let routing = unsafe { identity(routing_identity, routing_identity_len) }?;
    Ok(EndpointConfig::new(
        local,
        peer,
        SessionContext::new(host, device, routing),
    ))
}

#[allow(clippy::too_many_arguments)]
unsafe fn start_initiator(
    local_private_key: *const u8,
    local_private_key_len: usize,
    peer_public_key: *const u8,
    peer_public_key_len: usize,
    host_identity: *const u8,
    host_identity_len: usize,
    device_identity: *const u8,
    device_identity_len: usize,
    routing_identity: *const u8,
    routing_identity_len: usize,
    out_initiator: *mut *mut c_void,
    message: *mut u8,
    message_capacity: usize,
    message_len: *mut usize,
) -> i32 {
    // SAFETY: each output pointer is initialized only after its own null check.
    if !out_initiator.is_null() {
        *out_initiator = ptr::null_mut();
    }
    if !message_len.is_null() {
        *message_len = 0;
    }
    if out_initiator.is_null() || message_len.is_null() {
        return INVALID_ARGUMENT;
    }
    if message_capacity > 0 && message.is_null() {
        return INVALID_ARGUMENT;
    }

    let config = match unsafe {
        config(
            local_private_key,
            local_private_key_len,
            peer_public_key,
            peer_public_key_len,
            host_identity,
            host_identity_len,
            device_identity,
            device_identity_len,
            routing_identity,
            routing_identity_len,
        )
    } {
        Ok(config) => config,
        Err(error) => return error,
    };
    let (initiator, first_message) = match Initiator::start(config) {
        Ok(result) => result,
        Err(error) => return map_error(error),
    };
    if first_message.len() > message_capacity || first_message.len() > MAX_HANDSHAKE_SIZE {
        return BUFFER_TOO_SMALL;
    }
    // SAFETY: capacity was checked against the source length and the pointer was
    // checked when capacity was nonzero. Noise handshake messages are nonempty.
    unsafe {
        ptr::copy_nonoverlapping(first_message.as_ptr(), message, first_message.len());
    }
    let handle = Box::into_raw(Box::new(initiator)) as *mut c_void;
    // SAFETY: output pointers were checked above and the handle is now owned by C.
    unsafe {
        *message_len = first_message.len();
        *out_initiator = handle;
    }
    OK
}

unsafe fn finish_initiator(
    initiator: Box<Initiator>,
    message: *const u8,
    message_len: usize,
    out_session: *mut *mut c_void,
) -> i32 {
    if out_session.is_null() {
        return INVALID_ARGUMENT;
    }
    // SAFETY: output pointer was checked above.
    unsafe { *out_session = ptr::null_mut() };
    let message = match unsafe { input_bytes(message, message_len) } {
        Ok(message) => message,
        Err(error) => return error,
    };
    let session = match initiator.finish(message) {
        Ok(session) => session,
        Err(error) => return map_error(error),
    };
    let handle = Box::into_raw(Box::new(session)) as *mut c_void;
    // SAFETY: output pointer was checked above and the handle is now owned by C.
    unsafe { *out_session = handle };
    OK
}

#[allow(clippy::too_many_arguments)]
unsafe fn accept_responder(
    local_private_key: *const u8,
    local_private_key_len: usize,
    peer_public_key: *const u8,
    peer_public_key_len: usize,
    host_identity: *const u8,
    host_identity_len: usize,
    device_identity: *const u8,
    device_identity_len: usize,
    routing_identity: *const u8,
    routing_identity_len: usize,
    message: *const u8,
    message_len: usize,
    response: *mut u8,
    response_capacity: usize,
    response_len: *mut usize,
    out_session: *mut *mut c_void,
) -> i32 {
    // SAFETY: each output pointer is initialized only after its own null check.
    if !response_len.is_null() {
        *response_len = 0;
    }
    if !out_session.is_null() {
        *out_session = ptr::null_mut();
    }
    if response_len.is_null() || out_session.is_null() {
        return INVALID_ARGUMENT;
    }
    if response_capacity > 0 && response.is_null() {
        return INVALID_ARGUMENT;
    }
    let message = match unsafe { input_bytes(message, message_len) } {
        Ok(message) => message,
        Err(error) => return error,
    };
    let config = match unsafe {
        config(
            local_private_key,
            local_private_key_len,
            peer_public_key,
            peer_public_key_len,
            host_identity,
            host_identity_len,
            device_identity,
            device_identity_len,
            routing_identity,
            routing_identity_len,
        )
    } {
        Ok(config) => config,
        Err(error) => return error,
    };
    let (response_message, session) = match Responder::accept(config, message) {
        Ok(result) => result,
        Err(error) => return map_error(error),
    };
    if response_message.len() > response_capacity || response_message.len() > MAX_HANDSHAKE_SIZE {
        return BUFFER_TOO_SMALL;
    }
    // SAFETY: capacity was checked against source length and pointer was checked
    // when capacity was nonzero.
    unsafe {
        ptr::copy_nonoverlapping(response_message.as_ptr(), response, response_message.len());
    }
    let handle = Box::into_raw(Box::new(session)) as *mut c_void;
    // SAFETY: output pointers were checked above and the handle is now owned by C.
    unsafe {
        *response_len = response_message.len();
        *out_session = handle;
    }
    OK
}

unsafe fn seal(
    session: &mut Session,
    payload: *const u8,
    payload_len: usize,
    frame: *mut u8,
    frame_capacity: usize,
    frame_len: *mut usize,
) -> i32 {
    if frame_len.is_null() {
        return INVALID_ARGUMENT;
    }
    // SAFETY: output pointer was checked above.
    unsafe { *frame_len = 0 };
    if payload_len > MAX_PAYLOAD_SIZE {
        return MESSAGE_TOO_LARGE;
    }
    let payload = match unsafe { input_bytes(payload, payload_len) } {
        Ok(payload) => payload,
        Err(error) => return error,
    };
    let required = FRAME_LENGTH_PREFIX_SIZE + payload_len + TRANSPORT_TAG_LENGTH;
    if frame_capacity < required {
        return BUFFER_TOO_SMALL;
    }
    if frame_capacity > 0 && frame.is_null() {
        return INVALID_ARGUMENT;
    }
    let frame_output = match unsafe { output_bytes(frame, frame_capacity) } {
        Ok(output) => output,
        Err(error) => return error,
    };
    let encrypted = match session.seal_frame(payload) {
        Ok(frame) => frame,
        Err(error) => return map_error(error),
    };
    // `required` is exact for Noise ChaChaPoly and the core enforces the same bound.
    frame_output[..encrypted.len()].copy_from_slice(&encrypted);
    // SAFETY: output pointer was checked above.
    unsafe { *frame_len = encrypted.len() };
    OK
}

unsafe fn open(
    session: &mut Session,
    frame: *const u8,
    frame_len: usize,
    payload: *mut u8,
    payload_capacity: usize,
    payload_len: *mut usize,
) -> i32 {
    if payload_len.is_null() {
        return INVALID_ARGUMENT;
    }
    // SAFETY: output pointer was checked above.
    unsafe { *payload_len = 0 };
    let frame = match unsafe { input_bytes(frame, frame_len) } {
        Ok(frame) => frame,
        Err(error) => return error,
    };
    if frame.len() <= MAX_FRAME_SIZE && frame.len() >= FRAME_LENGTH_PREFIX_SIZE {
        let declared = u32::from_be_bytes(
            frame[..FRAME_LENGTH_PREFIX_SIZE]
                .try_into()
                .expect("four-byte frame prefix"),
        ) as usize;
        let actual = frame.len() - FRAME_LENGTH_PREFIX_SIZE;
        if declared == actual && declared >= TRANSPORT_TAG_LENGTH {
            let required = declared - TRANSPORT_TAG_LENGTH;
            if payload_capacity < required {
                return BUFFER_TOO_SMALL;
            }
        }
    }
    if payload_capacity > 0 && payload.is_null() {
        return INVALID_ARGUMENT;
    }
    let payload_output = match unsafe { output_bytes(payload, payload_capacity) } {
        Ok(output) => output,
        Err(error) => return error,
    };
    let plaintext = match session.open_frame(frame) {
        Ok(plaintext) => plaintext,
        Err(error) => return map_error(error),
    };
    if plaintext.len() > payload_output.len() {
        // This should be unreachable after the conservative structural bound.
        return BUFFER_TOO_SMALL;
    }
    payload_output[..plaintext.len()].copy_from_slice(&plaintext);
    // SAFETY: output pointer was checked above.
    unsafe { *payload_len = plaintext.len() };
    OK
}

/// Start an initiator handshake. Output handles are null on every error.
///
/// # Safety
/// All non-null input and output pointers must remain valid for this call. Output
/// handles are owned by the caller after a successful return and must be freed by
/// `wonder_relay_initiator_free`.
#[no_mangle]
pub unsafe extern "C" fn wonder_relay_initiator_start(
    local_private_key: *const u8,
    local_private_key_len: usize,
    peer_public_key: *const u8,
    peer_public_key_len: usize,
    host_identity: *const u8,
    host_identity_len: usize,
    device_identity: *const u8,
    device_identity_len: usize,
    routing_identity: *const u8,
    routing_identity_len: usize,
    out_initiator: *mut *mut c_void,
    message: *mut u8,
    message_capacity: usize,
    message_len: *mut usize,
) -> i32 {
    guarded(|| unsafe {
        start_initiator(
            local_private_key,
            local_private_key_len,
            peer_public_key,
            peer_public_key_len,
            host_identity,
            host_identity_len,
            device_identity,
            device_identity_len,
            routing_identity,
            routing_identity_len,
            out_initiator,
            message,
            message_capacity,
            message_len,
        )
    })
}

/// Free an initiator returned by [`wonder_relay_initiator_start`].
///
/// # Safety
/// `initiator` must be null or an unconsumed handle returned by this crate.
#[no_mangle]
pub unsafe extern "C" fn wonder_relay_initiator_free(initiator: *mut c_void) {
    let _ = std::panic::catch_unwind(AssertUnwindSafe(|| {
        if !initiator.is_null() {
            // SAFETY: callers must pass the opaque pointer returned by this crate.
            drop(unsafe { Box::from_raw(initiator as *mut Initiator) });
        }
    }));
}

/// Finish an initiator handshake. The initiator handle is consumed on every return path.
///
/// # Safety
/// `initiator` must be an unconsumed handle returned by this crate. Input and
/// output pointers must remain valid for this call.
#[no_mangle]
pub unsafe extern "C" fn wonder_relay_initiator_finish(
    initiator: *mut c_void,
    message: *const u8,
    message_len: usize,
    out_session: *mut *mut c_void,
) -> i32 {
    if !out_session.is_null() {
        // SAFETY: the pointer is checked above before initialization.
        unsafe { *out_session = ptr::null_mut() };
    }
    if initiator.is_null() {
        return INVALID_ARGUMENT;
    }
    // SAFETY: the non-null pointer is an opaque handle returned by this crate.
    let initiator = unsafe { Box::from_raw(initiator as *mut Initiator) };
    guarded(|| unsafe { finish_initiator(initiator, message, message_len, out_session) })
}

/// Accept a responder handshake. Output handles are null on every error.
///
/// # Safety
/// All non-null input and output pointers must remain valid for this call. The
/// returned session is owned by the caller and must be freed by
/// `wonder_relay_session_free`.
#[no_mangle]
pub unsafe extern "C" fn wonder_relay_responder_accept(
    local_private_key: *const u8,
    local_private_key_len: usize,
    peer_public_key: *const u8,
    peer_public_key_len: usize,
    host_identity: *const u8,
    host_identity_len: usize,
    device_identity: *const u8,
    device_identity_len: usize,
    routing_identity: *const u8,
    routing_identity_len: usize,
    message: *const u8,
    message_len: usize,
    response: *mut u8,
    response_capacity: usize,
    response_len: *mut usize,
    out_session: *mut *mut c_void,
) -> i32 {
    guarded(|| unsafe {
        accept_responder(
            local_private_key,
            local_private_key_len,
            peer_public_key,
            peer_public_key_len,
            host_identity,
            host_identity_len,
            device_identity,
            device_identity_len,
            routing_identity,
            routing_identity_len,
            message,
            message_len,
            response,
            response_capacity,
            response_len,
            out_session,
        )
    })
}

/// Free a session returned by this crate.
///
/// # Safety
/// `session` must be null or an unconsumed handle returned by this crate.
#[no_mangle]
pub unsafe extern "C" fn wonder_relay_session_free(session: *mut c_void) {
    let _ = std::panic::catch_unwind(AssertUnwindSafe(|| {
        if !session.is_null() {
            // SAFETY: callers must pass the opaque pointer returned by this crate.
            drop(unsafe { Box::from_raw(session as *mut Session) });
        }
    }));
}

/// Encrypt one payload into a length-prefixed transport frame.
///
/// # Safety
/// `session` must be a valid session handle exclusively owned for this call. All
/// non-null input and output pointers must remain valid for this call.
#[no_mangle]
pub unsafe extern "C" fn wonder_relay_seal_frame(
    session: *mut c_void,
    payload: *const u8,
    payload_len: usize,
    frame: *mut u8,
    frame_capacity: usize,
    frame_len: *mut usize,
) -> i32 {
    if !frame_len.is_null() {
        // SAFETY: the pointer is checked above before initialization.
        unsafe { *frame_len = 0 };
    }
    if session.is_null() {
        return INVALID_ARGUMENT;
    }
    // SAFETY: the non-null pointer is an opaque handle returned by this crate.
    let session = unsafe { &mut *(session as *mut Session) };
    guarded(|| unsafe {
        seal(
            session,
            payload,
            payload_len,
            frame,
            frame_capacity,
            frame_len,
        )
    })
}

/// Authenticate and decrypt one complete length-prefixed transport frame.
///
/// # Safety
/// `session` must be a valid session handle exclusively owned for this call. All
/// non-null input and output pointers must remain valid for this call.
#[no_mangle]
pub unsafe extern "C" fn wonder_relay_open_frame(
    session: *mut c_void,
    frame: *const u8,
    frame_len: usize,
    payload: *mut u8,
    payload_capacity: usize,
    payload_len: *mut usize,
) -> i32 {
    if !payload_len.is_null() {
        // SAFETY: the pointer is checked above before initialization.
        unsafe { *payload_len = 0 };
    }
    if session.is_null() {
        return INVALID_ARGUMENT;
    }
    // SAFETY: the non-null pointer is an opaque handle returned by this crate.
    let session = unsafe { &mut *(session as *mut Session) };
    guarded(|| unsafe {
        open(
            session,
            frame,
            frame_len,
            payload,
            payload_capacity,
            payload_len,
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use snow::{params::NoiseParams, Builder};
    use std::str::FromStr;

    fn keypair() -> ([u8; STATIC_KEY_LENGTH], [u8; STATIC_KEY_LENGTH]) {
        let params = NoiseParams::from_str(wonder_relay::NOISE_PATTERN).unwrap();
        let keypair = Builder::new(params).generate_keypair().unwrap();
        (
            keypair.private.try_into().unwrap(),
            keypair.public.try_into().unwrap(),
        )
    }

    #[test]
    fn c_abi_round_trip() {
        let (host_private, host_public) = keypair();
        let (device_private, device_public) = keypair();
        let host = b"host";
        let device = b"device";
        let route = b"route";
        let mut initiator = ptr::null_mut();
        let mut first = [0_u8; MAX_HANDSHAKE_SIZE];
        let mut first_len = 0;
        let status = unsafe {
            wonder_relay_initiator_start(
                device_private.as_ptr(),
                32,
                host_public.as_ptr(),
                32,
                host.as_ptr(),
                host.len(),
                device.as_ptr(),
                device.len(),
                route.as_ptr(),
                route.len(),
                &mut initiator,
                first.as_mut_ptr(),
                first.len(),
                &mut first_len,
            )
        };
        assert_eq!(status, OK);
        let mut responder = ptr::null_mut();
        let mut second = [0_u8; MAX_HANDSHAKE_SIZE];
        let mut second_len = 0;
        assert_eq!(
            unsafe {
                wonder_relay_responder_accept(
                    host_private.as_ptr(),
                    32,
                    device_public.as_ptr(),
                    32,
                    host.as_ptr(),
                    host.len(),
                    device.as_ptr(),
                    device.len(),
                    route.as_ptr(),
                    route.len(),
                    first.as_ptr(),
                    first_len,
                    second.as_mut_ptr(),
                    second.len(),
                    &mut second_len,
                    &mut responder,
                )
            },
            OK
        );
        let mut initiator_session = ptr::null_mut();
        assert_eq!(
            unsafe {
                wonder_relay_initiator_finish(
                    initiator,
                    second.as_ptr(),
                    second_len,
                    &mut initiator_session,
                )
            },
            OK
        );

        // A zero-length application payload may use null input/output pointers.
        let mut empty_frame = [0_u8; MAX_FRAME_SIZE];
        let mut empty_frame_len = 0;
        assert_eq!(
            unsafe {
                wonder_relay_seal_frame(
                    initiator_session,
                    ptr::null(),
                    0,
                    empty_frame.as_mut_ptr(),
                    empty_frame.len(),
                    &mut empty_frame_len,
                )
            },
            OK
        );
        let mut empty_plaintext_len = 99;
        assert_eq!(
            unsafe {
                wonder_relay_open_frame(
                    responder,
                    empty_frame.as_ptr(),
                    empty_frame_len,
                    ptr::null_mut(),
                    0,
                    &mut empty_plaintext_len,
                )
            },
            OK
        );
        assert_eq!(empty_plaintext_len, 0);

        let payload = b"ffi round trip";
        let mut frame = [0_u8; MAX_FRAME_SIZE];
        let mut frame_len = 0;
        let mut too_small = [0_u8; 1];
        let mut too_small_len = 99;
        assert_eq!(
            unsafe {
                wonder_relay_seal_frame(
                    initiator_session,
                    payload.as_ptr(),
                    payload.len(),
                    too_small.as_mut_ptr(),
                    too_small.len(),
                    &mut too_small_len,
                )
            },
            BUFFER_TOO_SMALL
        );
        assert_eq!(too_small_len, 0);
        assert_eq!(
            unsafe {
                wonder_relay_seal_frame(
                    initiator_session,
                    payload.as_ptr(),
                    payload.len(),
                    frame.as_mut_ptr(),
                    frame.len(),
                    &mut frame_len,
                )
            },
            OK
        );
        let mut plaintext = [0_u8; MAX_PAYLOAD_SIZE];
        let mut plaintext_len = 0;
        assert_eq!(
            unsafe {
                wonder_relay_open_frame(
                    responder,
                    frame.as_ptr(),
                    frame_len,
                    plaintext.as_mut_ptr(),
                    plaintext.len(),
                    &mut plaintext_len,
                )
            },
            OK
        );
        assert_eq!(&plaintext[..plaintext_len], payload);

        let mut too_small_plaintext = [0_u8; 1];
        let mut too_small_plaintext_len = 99;
        assert_eq!(
            unsafe {
                wonder_relay_open_frame(
                    responder,
                    frame.as_ptr(),
                    frame_len,
                    too_small_plaintext.as_mut_ptr(),
                    too_small_plaintext.len(),
                    &mut too_small_plaintext_len,
                )
            },
            BUFFER_TOO_SMALL
        );
        assert_eq!(too_small_plaintext_len, 0);

        let mut empty_payload_len = 99;
        assert_eq!(
            unsafe {
                wonder_relay_open_frame(
                    responder,
                    ptr::null(),
                    0,
                    ptr::null_mut(),
                    0,
                    &mut empty_payload_len,
                )
            },
            INVALID_FRAME
        );
        assert_eq!(empty_payload_len, 0);
        assert_eq!(
            unsafe {
                wonder_relay_open_frame(
                    responder,
                    frame.as_ptr(),
                    frame_len,
                    plaintext.as_mut_ptr(),
                    plaintext.len(),
                    &mut plaintext_len,
                )
            },
            INVALID_STATE
        );

        unsafe {
            wonder_relay_session_free(initiator_session);
            wonder_relay_session_free(responder);
        }
    }

    #[test]
    fn invalid_pointers_and_lengths_are_rejected_without_handles() {
        let mut handle = ptr::null_mut();
        let mut output_len = 99;
        assert_eq!(
            unsafe {
                wonder_relay_initiator_start(
                    ptr::null(),
                    32,
                    ptr::null(),
                    32,
                    ptr::null(),
                    0,
                    ptr::null(),
                    0,
                    ptr::null(),
                    0,
                    &mut handle,
                    ptr::null_mut(),
                    0,
                    &mut output_len,
                )
            },
            INVALID_ARGUMENT
        );
        assert!(handle.is_null());
        assert_eq!(output_len, 0);

        let mut output_handle = ptr::dangling_mut::<c_void>();
        assert_eq!(
            unsafe {
                wonder_relay_initiator_finish(ptr::null_mut(), ptr::null(), 0, &mut output_handle)
            },
            INVALID_ARGUMENT
        );
        assert!(output_handle.is_null());

        let mut frame_len = 99;
        assert_eq!(
            unsafe {
                wonder_relay_seal_frame(
                    ptr::null_mut(),
                    ptr::null(),
                    0,
                    ptr::null_mut(),
                    0,
                    &mut frame_len,
                )
            },
            INVALID_ARGUMENT
        );
        assert_eq!(frame_len, 0);

        let mut payload_len = 99;
        assert_eq!(
            unsafe {
                wonder_relay_open_frame(
                    ptr::null_mut(),
                    ptr::null(),
                    0,
                    ptr::null_mut(),
                    0,
                    &mut payload_len,
                )
            },
            INVALID_ARGUMENT
        );
        assert_eq!(payload_len, 0);
    }
}
