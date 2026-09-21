//! Encrypted, mutually authenticated channels for Wonder relay endpoints.
//!
//! Each connection performs a fresh `Noise_KK_25519_ChaChaPoly_BLAKE2s` handshake.
//! The two endpoint static keys are pinned by the caller before the handshake; the
//! handshake's ephemeral keys provide fresh transport keys for every connection.
//!
//! This crate deliberately stops at an authenticated encrypted channel. It does
//! not open sockets, persist keys, authorize requests, queue application requests,
//! or retry failed requests. The caller owns local private-key and peer public-key
//! material and must keep private material in secure storage and handle its lifetime
//! appropriately. The library alone is not a runnable relay product and does not
//! establish application authorization.

use std::{error::Error as StdError, fmt, str::FromStr};

use snow::params::NoiseParams;
use snow::{Builder, HandshakeState, TransportState};
use zeroize::Zeroizing;

/// The Noise protocol used by this crate.
pub const NOISE_PATTERN: &str = "Noise_KK_25519_ChaChaPoly_BLAKE2s";
/// Protocol version encoded in a context made with [`SessionContext::new`].
pub const PROTOCOL_VERSION: u16 = 1;
/// Length of a Curve25519 static private or public key.
pub const STATIC_KEY_LENGTH: usize = 32;
/// Maximum encoded frame size, including its four-byte length prefix.
pub const MAX_FRAME_SIZE: usize = 65_535;
/// Length of the encoded ciphertext length prefix.
pub const FRAME_LENGTH_PREFIX_SIZE: usize = 4;
/// ChaChaPoly's Noise transport authentication tag length.
pub const TRANSPORT_TAG_LENGTH: usize = 16;
/// Largest application payload accepted by [`Session::seal_frame`].
pub const MAX_PAYLOAD_SIZE: usize =
    MAX_FRAME_SIZE - FRAME_LENGTH_PREFIX_SIZE - TRANSPORT_TAG_LENGTH;

const PROLOGUE_DOMAIN: &[u8] = b"wonder-relay/noise-kk/prologue\0";
const MAX_CONTEXT_FIELD_LENGTH: usize = 4096;
/// Maximum unframed Noise handshake message accepted or emitted by this API.
pub const MAX_HANDSHAKE_MESSAGE_SIZE: usize = 1024;

/// Context that is cryptographically bound to a connection handshake.
///
/// Each identity is encoded as a length-prefixed UTF-8 byte string. This avoids
/// ambiguity from concatenating values such as `("ab", "c")` and `("a", "bc")`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SessionContext<'a> {
    /// Protocol version understood by both endpoints.
    pub protocol_version: u16,
    /// Stable identity of the host endpoint.
    pub host_identity: &'a str,
    /// Stable identity of the device endpoint.
    pub device_identity: &'a str,
    /// Identity of the route or relay path being authorized by the caller.
    pub routing_identity: &'a str,
}

impl<'a> SessionContext<'a> {
    /// Construct context for the current protocol version.
    #[must_use]
    pub const fn new(
        host_identity: &'a str,
        device_identity: &'a str,
        routing_identity: &'a str,
    ) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            host_identity,
            device_identity,
            routing_identity,
        }
    }

    /// Construct context with an explicitly selected protocol version.
    #[must_use]
    pub const fn with_protocol_version(
        protocol_version: u16,
        host_identity: &'a str,
        device_identity: &'a str,
        routing_identity: &'a str,
    ) -> Self {
        Self {
            protocol_version,
            host_identity,
            device_identity,
            routing_identity,
        }
    }
}

/// Static endpoint configuration for one connection handshake.
///
/// Keys are borrowed so key persistence remains the caller's responsibility.
/// Use a fresh configuration to create each connection; [`Initiator`] and
/// [`Session`] are intentionally single-connection values.
#[derive(Clone, Copy)]
pub struct EndpointConfig<'a> {
    /// This endpoint's Curve25519 static private key.
    pub local_static_private_key: &'a [u8; STATIC_KEY_LENGTH],
    /// The pinned Curve25519 static public key expected from the peer.
    pub peer_static_public_key: &'a [u8; STATIC_KEY_LENGTH],
    /// Context to bind into the Noise handshake hash.
    pub context: SessionContext<'a>,
}

impl<'a> EndpointConfig<'a> {
    /// Construct an endpoint configuration from caller-owned key material.
    #[must_use]
    pub const fn new(
        local_static_private_key: &'a [u8; STATIC_KEY_LENGTH],
        peer_static_public_key: &'a [u8; STATIC_KEY_LENGTH],
        context: SessionContext<'a>,
    ) -> Self {
        Self {
            local_static_private_key,
            peer_static_public_key,
            context,
        }
    }
}

/// Errors produced by handshake, framing, or authenticated transport operations.
#[derive(Debug)]
pub enum RelayError {
    /// An operation failed inside the established `snow` Noise state machine.
    Noise(snow::Error),
    /// The encoded frame is malformed or its length prefix does not match.
    InvalidFrame,
    /// A frame or handshake message exceeds this crate's hard limit.
    MessageTooLarge { actual: usize, maximum: usize },
    /// A context identity exceeds the bounded prologue field size.
    ContextFieldTooLarge { actual: usize, maximum: usize },
    /// The handshake message was not the expected message for this endpoint.
    InvalidHandshakeMessage,
    /// The supplied context has no identity for one of its required fields.
    EmptyContextIdentity { field: &'static str },
    /// The endpoint does not understand the supplied context protocol version.
    UnsupportedProtocolVersion { version: u16 },
    /// Snow returned key material of an unexpected length while generating a pair.
    InvalidGeneratedKeyMaterial,
    /// A fatal transport read or write error has permanently closed this session.
    SessionPoisoned,
}

impl fmt::Display for RelayError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Noise(error) => write!(formatter, "Noise operation failed: {error}"),
            Self::InvalidFrame => formatter.write_str("invalid relay frame"),
            Self::MessageTooLarge { actual, maximum } => {
                write!(formatter, "message is {actual} bytes; maximum is {maximum}")
            }
            Self::ContextFieldTooLarge { actual, maximum } => {
                write!(
                    formatter,
                    "context field is {actual} bytes; maximum is {maximum}"
                )
            }
            Self::InvalidHandshakeMessage => formatter.write_str("invalid handshake message"),
            Self::EmptyContextIdentity { field } => {
                write!(formatter, "context identity {field} must not be empty")
            }
            Self::UnsupportedProtocolVersion { version } => {
                write!(formatter, "unsupported relay protocol version {version}")
            }
            Self::InvalidGeneratedKeyMaterial => {
                formatter.write_str("invalid generated key material")
            }
            Self::SessionPoisoned => formatter.write_str("relay session is poisoned"),
        }
    }
}

impl StdError for RelayError {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        match self {
            Self::Noise(error) => Some(error),
            _ => None,
        }
    }
}

impl From<snow::Error> for RelayError {
    fn from(error: snow::Error) -> Self {
        Self::Noise(error)
    }
}

/// A caller-owned endpoint static key pair suitable for pinning on the peer.
///
/// The private key is zeroized when this value is dropped. Applications should
/// still load and persist it only through their platform's secure key storage.
/// This convenience generator does not establish identity, authorization, or
/// trust on its own.
pub struct StaticKeyPair {
    private_key: Zeroizing<[u8; STATIC_KEY_LENGTH]>,
    public_key: [u8; STATIC_KEY_LENGTH],
}

impl fmt::Debug for StaticKeyPair {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("StaticKeyPair { private_key: [redacted], public_key: [redacted] }")
    }
}

impl StaticKeyPair {
    /// Generate a fresh Curve25519 static key pair using Snow's configured CSPRNG.
    pub fn generate() -> Result<Self, RelayError> {
        let params =
            NoiseParams::from_str(NOISE_PATTERN).expect("Noise pattern is a crate constant");
        let keypair = Builder::new(params).generate_keypair()?;
        let private_bytes = Zeroizing::new(keypair.private);
        let private_key = private_bytes
            .as_slice()
            .try_into()
            .map_err(|_| RelayError::InvalidGeneratedKeyMaterial)?;
        let public_key = keypair
            .public
            .try_into()
            .map_err(|_| RelayError::InvalidGeneratedKeyMaterial)?;
        Ok(Self {
            private_key: Zeroizing::new(private_key),
            public_key,
        })
    }

    /// Borrow the private key for a connection configuration.
    #[must_use]
    pub fn private_key(&self) -> &[u8; STATIC_KEY_LENGTH] {
        &self.private_key
    }

    /// Borrow the public key for pinning in the peer's configuration.
    #[must_use]
    pub const fn public_key(&self) -> &[u8; STATIC_KEY_LENGTH] {
        &self.public_key
    }
}

/// Initiator-side state between the two handshake messages.
pub struct Initiator {
    state: HandshakeState,
}

impl fmt::Debug for Initiator {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("Initiator { handshake: in progress } ")
    }
}

impl Initiator {
    /// Start a fresh connection and produce its first handshake message.
    pub fn start(config: EndpointConfig<'_>) -> Result<(Self, Vec<u8>), RelayError> {
        let prologue = encode_context(config.context)?;
        let mut state = build_handshake(config, &prologue, true)?;
        let first = write_handshake_message(&mut state)?;
        Ok((Self { state }, first))
    }

    /// Consume the responder's handshake message and enter transport mode.
    ///
    /// This consumes the handshake state even when the peer message is rejected;
    /// callers should establish a new connection and handshake rather than retrying
    /// an application request on a failed channel.
    pub fn finish(self, responder_message: &[u8]) -> Result<Session, RelayError> {
        validate_handshake_message(responder_message)?;
        let mut state = self.state;
        let mut payload = [0_u8; MAX_HANDSHAKE_MESSAGE_SIZE];
        if state.read_message(responder_message, &mut payload)? != 0 {
            return Err(RelayError::InvalidHandshakeMessage);
        }
        Ok(Session {
            transport: state.into_transport_mode()?,
            poisoned: false,
        })
    }
}

/// Responder-side entry point for a fresh connection.
pub struct Responder;

impl Responder {
    /// Authenticate the initiator's first message and produce the response plus
    /// an established transport session.
    pub fn accept(
        config: EndpointConfig<'_>,
        initiator_message: &[u8],
    ) -> Result<(Vec<u8>, Session), RelayError> {
        validate_handshake_message(initiator_message)?;
        let prologue = encode_context(config.context)?;
        let mut state = build_handshake(config, &prologue, false)?;
        let mut payload = [0_u8; MAX_HANDSHAKE_MESSAGE_SIZE];
        if state.read_message(initiator_message, &mut payload)? != 0 {
            return Err(RelayError::InvalidHandshakeMessage);
        }
        let response = write_handshake_message(&mut state)?;
        let session = Session {
            transport: state.into_transport_mode()?,
            poisoned: false,
        };
        Ok((response, session))
    }
}

/// An authenticated Noise transport channel for exactly one connection.
pub struct Session {
    transport: TransportState,
    poisoned: bool,
}

impl fmt::Debug for Session {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("Session { encrypted transport } ")
    }
}

impl Session {
    /// Encrypt one application payload into a length-prefixed binary frame.
    ///
    /// The complete returned frame is at most [`MAX_FRAME_SIZE`]. Frames must be
    /// delivered in order on a reliable byte stream; Noise transport nonces reject
    /// replayed or out-of-order frames.
    pub fn seal_frame(&mut self, payload: &[u8]) -> Result<Vec<u8>, RelayError> {
        if self.poisoned {
            return Err(RelayError::SessionPoisoned);
        }
        if payload.len() > MAX_PAYLOAD_SIZE {
            return Err(RelayError::MessageTooLarge {
                actual: payload.len(),
                maximum: MAX_PAYLOAD_SIZE,
            });
        }

        let mut frame = vec![0_u8; FRAME_LENGTH_PREFIX_SIZE + payload.len() + TRANSPORT_TAG_LENGTH];
        let ciphertext_length = match self
            .transport
            .write_message(payload, &mut frame[FRAME_LENGTH_PREFIX_SIZE..])
        {
            Ok(length) => length,
            Err(error) => {
                self.poisoned = true;
                return Err(error.into());
            }
        };
        frame.truncate(FRAME_LENGTH_PREFIX_SIZE + ciphertext_length);
        frame[..FRAME_LENGTH_PREFIX_SIZE]
            .copy_from_slice(&(ciphertext_length as u32).to_be_bytes());
        Ok(frame)
    }

    /// Authenticate and decrypt one complete length-prefixed binary frame.
    ///
    /// Any framing or authentication failure permanently poisons this session.
    /// A successfully opened frame cannot be opened again or moved ahead of an
    /// earlier frame.
    pub fn open_frame(&mut self, frame: &[u8]) -> Result<Vec<u8>, RelayError> {
        if self.poisoned {
            return Err(RelayError::SessionPoisoned);
        }
        if frame.len() > MAX_FRAME_SIZE {
            self.poisoned = true;
            return Err(RelayError::MessageTooLarge {
                actual: frame.len(),
                maximum: MAX_FRAME_SIZE,
            });
        }
        if frame.len() < FRAME_LENGTH_PREFIX_SIZE {
            self.poisoned = true;
            return Err(RelayError::InvalidFrame);
        }

        let declared_ciphertext_length = u32::from_be_bytes(
            frame[..FRAME_LENGTH_PREFIX_SIZE]
                .try_into()
                .expect("four-byte frame prefix"),
        ) as usize;
        let actual_ciphertext_length = frame.len() - FRAME_LENGTH_PREFIX_SIZE;
        if declared_ciphertext_length != actual_ciphertext_length
            || declared_ciphertext_length < TRANSPORT_TAG_LENGTH
        {
            self.poisoned = true;
            return Err(RelayError::InvalidFrame);
        }

        let mut payload = vec![0_u8; declared_ciphertext_length - TRANSPORT_TAG_LENGTH];
        let payload_length = match self
            .transport
            .read_message(&frame[FRAME_LENGTH_PREFIX_SIZE..], &mut payload)
        {
            Ok(length) => length,
            Err(error) => {
                self.poisoned = true;
                return Err(error.into());
            }
        };
        payload.truncate(payload_length);
        Ok(payload)
    }

    /// Return whether a fatal frame, decryption, or transport error closed this session.
    #[must_use]
    pub const fn is_poisoned(&self) -> bool {
        self.poisoned
    }
}

fn build_handshake(
    config: EndpointConfig<'_>,
    prologue: &[u8],
    initiator: bool,
) -> Result<HandshakeState, RelayError> {
    let params = NoiseParams::from_str(NOISE_PATTERN).expect("Noise pattern is a crate constant");
    let builder = Builder::new(params)
        .local_private_key(config.local_static_private_key)?
        .remote_public_key(config.peer_static_public_key)?
        .prologue(prologue)?;
    if initiator {
        Ok(builder.build_initiator()?)
    } else {
        Ok(builder.build_responder()?)
    }
}

fn write_handshake_message(state: &mut HandshakeState) -> Result<Vec<u8>, RelayError> {
    let mut message = [0_u8; MAX_HANDSHAKE_MESSAGE_SIZE];
    let message_length = state.write_message(&[], &mut message)?;
    Ok(message[..message_length].to_vec())
}

fn validate_handshake_message(message: &[u8]) -> Result<(), RelayError> {
    if message.is_empty() {
        return Err(RelayError::InvalidHandshakeMessage);
    }
    if message.len() > MAX_HANDSHAKE_MESSAGE_SIZE {
        return Err(RelayError::MessageTooLarge {
            actual: message.len(),
            maximum: MAX_HANDSHAKE_MESSAGE_SIZE,
        });
    }
    Ok(())
}

fn encode_context(context: SessionContext<'_>) -> Result<Vec<u8>, RelayError> {
    if context.protocol_version != PROTOCOL_VERSION {
        return Err(RelayError::UnsupportedProtocolVersion {
            version: context.protocol_version,
        });
    }
    let fields = [
        context.host_identity.as_bytes(),
        context.device_identity.as_bytes(),
        context.routing_identity.as_bytes(),
    ];
    for (name, field) in [
        ("host", fields[0]),
        ("device", fields[1]),
        ("routing", fields[2]),
    ] {
        if field.is_empty() {
            return Err(RelayError::EmptyContextIdentity { field: name });
        }
        if field.len() > MAX_CONTEXT_FIELD_LENGTH {
            return Err(RelayError::ContextFieldTooLarge {
                actual: field.len(),
                maximum: MAX_CONTEXT_FIELD_LENGTH,
            });
        }
    }

    let mut prologue = Vec::with_capacity(
        PROLOGUE_DOMAIN.len()
            + 2
            + fields.len() * 4
            + fields.iter().map(|field| field.len()).sum::<usize>(),
    );
    prologue.extend_from_slice(PROLOGUE_DOMAIN);
    prologue.extend_from_slice(&context.protocol_version.to_be_bytes());
    for field in fields {
        prologue.extend_from_slice(&(field.len() as u32).to_be_bytes());
        prologue.extend_from_slice(field);
    }
    Ok(prologue)
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONTEXT: SessionContext<'static> = SessionContext::new("host-a", "device-b", "route-c");

    struct TestKeys {
        host_private: [u8; STATIC_KEY_LENGTH],
        host_public: [u8; STATIC_KEY_LENGTH],
        device_private: [u8; STATIC_KEY_LENGTH],
        device_public: [u8; STATIC_KEY_LENGTH],
        wrong_public: [u8; STATIC_KEY_LENGTH],
    }

    fn test_keys() -> TestKeys {
        let params = NoiseParams::from_str(NOISE_PATTERN).unwrap();
        let host = Builder::new(params.clone()).generate_keypair().unwrap();
        let device = Builder::new(params.clone()).generate_keypair().unwrap();
        let wrong = Builder::new(params).generate_keypair().unwrap();
        TestKeys {
            host_private: host.private.try_into().unwrap(),
            host_public: host.public.try_into().unwrap(),
            device_private: device.private.try_into().unwrap(),
            device_public: device.public.try_into().unwrap(),
            wrong_public: wrong.public.try_into().unwrap(),
        }
    }

    fn pair<'a>(keys: &'a TestKeys, context: SessionContext<'a>) -> (Session, Session) {
        let (initiator, first) = Initiator::start(EndpointConfig::new(
            &keys.device_private,
            &keys.host_public,
            context,
        ))
        .unwrap();
        let (second, responder) = Responder::accept(
            EndpointConfig::new(&keys.host_private, &keys.device_public, context),
            &first,
        )
        .unwrap();
        let initiator = initiator.finish(&second).unwrap();
        (initiator, responder)
    }

    #[test]
    fn handshake_and_bidirectional_frames() {
        let keys = test_keys();
        let (mut initiator, mut responder) = pair(&keys, CONTEXT);
        let outbound = initiator.seal_frame(b"from device").unwrap();
        assert_eq!(responder.open_frame(&outbound).unwrap(), b"from device");
        let reply = responder.seal_frame(b"from host").unwrap();
        assert_eq!(initiator.open_frame(&reply).unwrap(), b"from host");
    }

    #[test]
    fn frame_limit_is_strict() {
        let keys = test_keys();
        let (mut initiator, mut responder) = pair(&keys, CONTEXT);
        let max = initiator.seal_frame(&vec![7_u8; MAX_PAYLOAD_SIZE]).unwrap();
        assert_eq!(max.len(), MAX_FRAME_SIZE);
        assert_eq!(responder.open_frame(&max).unwrap().len(), MAX_PAYLOAD_SIZE);
        let too_large = initiator.seal_frame(&vec![7_u8; MAX_PAYLOAD_SIZE + 1]);
        assert!(matches!(too_large, Err(RelayError::MessageTooLarge { .. })));
        assert!(matches!(
            responder.open_frame(&vec![0_u8; MAX_FRAME_SIZE + 1]),
            Err(RelayError::MessageTooLarge { .. })
        ));
        assert!(responder.is_poisoned());
    }

    #[test]
    fn tamper_does_not_authenticate_and_poison_session() {
        let keys = test_keys();
        let (mut initiator, mut responder) = pair(&keys, CONTEXT);
        let frame = initiator.seal_frame(b"authenticated").unwrap();
        let mut tampered = frame.clone();
        let last = tampered.len() - 1;
        tampered[last] ^= 1;
        assert!(matches!(
            responder.open_frame(&tampered),
            Err(RelayError::Noise(snow::Error::Decrypt))
        ));
        assert!(responder.is_poisoned());
        assert!(matches!(
            responder.open_frame(&frame),
            Err(RelayError::SessionPoisoned)
        ));
    }

    #[test]
    fn wrong_pinned_peer_key_rejects_handshake() {
        let keys = test_keys();
        let (_initiator, first) = Initiator::start(EndpointConfig::new(
            &keys.device_private,
            &keys.wrong_public,
            CONTEXT,
        ))
        .unwrap();
        let result = Responder::accept(
            EndpointConfig::new(&keys.host_private, &keys.device_public, CONTEXT),
            &first,
        );
        assert!(matches!(result, Err(RelayError::Noise(_))));
    }

    #[test]
    fn wrong_context_rejects_handshake() {
        let keys = test_keys();
        let (_initiator, first) = Initiator::start(EndpointConfig::new(
            &keys.device_private,
            &keys.host_public,
            CONTEXT,
        ))
        .unwrap();
        let result = Responder::accept(
            EndpointConfig::new(
                &keys.host_private,
                &keys.device_public,
                SessionContext::new("host-a", "device-b", "different-route"),
            ),
            &first,
        );
        assert!(matches!(result, Err(RelayError::Noise(_))));
    }

    #[test]
    fn replay_and_out_of_order_frames_are_rejected() {
        let keys = test_keys();
        let (mut initiator, mut responder) = pair(&keys, CONTEXT);
        let first = initiator.seal_frame(b"first").unwrap();
        let second = initiator.seal_frame(b"second").unwrap();
        assert!(matches!(
            responder.open_frame(&second),
            Err(RelayError::Noise(snow::Error::Decrypt))
        ));
        assert!(matches!(
            responder.open_frame(&first),
            Err(RelayError::SessionPoisoned)
        ));

        let (mut initiator, mut responder) = pair(&keys, CONTEXT);
        let frame = initiator.seal_frame(b"once").unwrap();
        assert_eq!(responder.open_frame(&frame).unwrap(), b"once");
        assert!(matches!(
            responder.open_frame(&frame),
            Err(RelayError::Noise(snow::Error::Decrypt))
        ));
        assert!(responder.is_poisoned());
    }

    #[test]
    fn old_session_frame_fails_after_restart() {
        let keys = test_keys();
        let (mut old_initiator, mut old_responder) = pair(&keys, CONTEXT);
        let old_frame = old_initiator.seal_frame(b"old connection").unwrap();
        assert_eq!(
            old_responder.open_frame(&old_frame).unwrap(),
            b"old connection"
        );

        let (_new_initiator, mut new_responder) = pair(&keys, CONTEXT);
        assert!(matches!(
            new_responder.open_frame(&old_frame),
            Err(RelayError::Noise(snow::Error::Decrypt))
        ));
        assert!(new_responder.is_poisoned());

        let (mut fresh_initiator, mut fresh_responder) = pair(&keys, CONTEXT);
        let new_frame = fresh_initiator.seal_frame(b"new connection").unwrap();
        assert_eq!(
            fresh_responder.open_frame(&new_frame).unwrap(),
            b"new connection"
        );
    }

    #[test]
    fn context_encoding_is_unambiguous() {
        let left = encode_context(SessionContext::new("ab", "c", "route")).unwrap();
        let right = encode_context(SessionContext::new("a", "bc", "route")).unwrap();
        assert_ne!(left, right);
    }

    #[test]
    fn context_requires_all_identities_and_known_version() {
        let keys = test_keys();
        let empty = Initiator::start(EndpointConfig::new(
            &keys.device_private,
            &keys.host_public,
            SessionContext::new("", "device-b", "route-c"),
        ));
        assert!(matches!(
            empty,
            Err(RelayError::EmptyContextIdentity { field: "host" })
        ));

        let unknown = Initiator::start(EndpointConfig::new(
            &keys.device_private,
            &keys.host_public,
            SessionContext::with_protocol_version(99, "host-a", "device-b", "route-c"),
        ));
        assert!(matches!(
            unknown,
            Err(RelayError::UnsupportedProtocolVersion { version: 99 })
        ));
    }

    #[test]
    fn generated_key_pair_is_usable_and_debug_redacts_material() {
        let key_pair = StaticKeyPair::generate().unwrap();
        assert_eq!(key_pair.private_key().len(), STATIC_KEY_LENGTH);
        assert_eq!(key_pair.public_key().len(), STATIC_KEY_LENGTH);
        let debug = format!("{key_pair:?}");
        assert!(debug.contains("redacted"));
    }

    #[test]
    fn nonempty_handshake_payload_is_rejected_in_both_directions() {
        let keys = test_keys();

        let initiator_config =
            EndpointConfig::new(&keys.device_private, &keys.host_public, CONTEXT);
        let mut raw_initiator =
            build_handshake(initiator_config, &encode_context(CONTEXT).unwrap(), true).unwrap();
        let mut first = [0_u8; MAX_HANDSHAKE_MESSAGE_SIZE];
        let first_length = raw_initiator
            .write_message(b"unexpected", &mut first)
            .unwrap();
        let responder_result = Responder::accept(
            EndpointConfig::new(&keys.host_private, &keys.device_public, CONTEXT),
            &first[..first_length],
        );
        assert!(matches!(
            responder_result,
            Err(RelayError::InvalidHandshakeMessage)
        ));

        let (initiator, first) = Initiator::start(initiator_config).unwrap();
        let mut raw_responder = build_handshake(
            EndpointConfig::new(&keys.host_private, &keys.device_public, CONTEXT),
            &encode_context(CONTEXT).unwrap(),
            false,
        )
        .unwrap();
        let mut scratch = [0_u8; MAX_HANDSHAKE_MESSAGE_SIZE];
        assert_eq!(raw_responder.read_message(&first, &mut scratch).unwrap(), 0);
        let mut second = [0_u8; MAX_HANDSHAKE_MESSAGE_SIZE];
        let second_length = raw_responder
            .write_message(b"unexpected", &mut second)
            .unwrap();
        assert!(matches!(
            initiator.finish(&second[..second_length]),
            Err(RelayError::InvalidHandshakeMessage)
        ));
    }
}
