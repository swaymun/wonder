//! Pairing state and signature verification for the owner-only device protocol.

use std::collections::HashMap;

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use p256::ecdsa::{signature::Verifier, Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

use crate::pairing::{
    canonical_action_transcript, canonical_challenge_transcript, ActionTranscript,
    ChallengeTranscript,
};

pub const OFFER_LIFETIME_MS: u64 = 5 * 60 * 1000;
pub const CHALLENGE_LIFETIME_MS: u64 = 60 * 1000;
pub const SESSION_EXPIRATION_OPTIONS: [&str; 5] = ["1h", "1d", "7d", "30d", "never"];
pub const NEVER_EXPIRES_AT_MS: u64 = i64::MAX as u64;
const HUMAN_CODE_ATTEMPT_WINDOW_MS: u64 = 60 * 1000;
const HUMAN_CODE_ATTEMPT_LIMIT: usize = 20;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct DevicePublicKeyJwk {
    pub kty: String,
    pub crv: String,
    pub x: String,
    pub y: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingOffer {
    pub offer_id: String,
    pub url: String,
    pub expires_at_ms: u64,
    pub human_code: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Challenge {
    pub challenge_id: String,
    pub device_id: String,
    pub nonce: String,
    pub origin: String,
    pub host_installation_id: String,
    pub offer_id: String,
    pub issued_at_ms: u64,
    pub expires_at_ms: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaimedDevice {
    pub device_id: String,
    pub challenge: Challenge,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct VerifiedSession {
    pub device_id: String,
    pub session_token: String,
    pub csrf_token: String,
    pub host_installation_id: String,
    pub expires_at_ms: u64,
}

#[derive(Debug, Eq, PartialEq)]
pub enum PairingError {
    NotFound,
    Expired,
    AlreadyConsumed,
    InvalidSecret,
    InvalidPublicKey,
    InvalidSignature,
    InvalidSessionExpiration,
    ChallengeNotFound,
    ChallengeExpired,
    ChallengeReplayed,
    BindingMismatch,
    ConfirmationRequired,
    SessionNotFound,
    SessionExpired,
    CsrfMismatch,
}

struct OfferRecord {
    secret_hash: [u8; 32],
    human_code: String,
    origin: String,
    host_installation_id: String,
    expires_at_ms: u64,
    consumed: bool,
}

struct ChallengeRecord {
    challenge: Challenge,
    consumed: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingEnrollment {
    pub device_id: String,
    pub label: String,
    pub public_key: DevicePublicKeyJwk,
    pub challenge: Challenge,
    pub session_expires_at_ms: Option<u64>,
}

struct DeviceRecord {
    confirmed: bool,
    public_key: DevicePublicKeyJwk,
    revoked: bool,
    session_expires_at_ms: Option<u64>,
}

struct SessionRecord {
    device_id: String,
    csrf_hash: [u8; 32],
    expires_at_ms: u64,
}

#[derive(Default)]
pub struct PairingState {
    offers: HashMap<String, OfferRecord>,
    challenges: HashMap<String, ChallengeRecord>,
    devices: HashMap<String, DeviceRecord>,
    sessions: HashMap<String, SessionRecord>,
    human_code_attempts: Vec<u64>,
    pending: HashMap<String, PendingEnrollment>,
}

impl PairingState {
    pub fn restore_device(
        &mut self,
        device_id: String,
        public_key: DevicePublicKeyJwk,
        revoked: bool,
        session_expires_at_ms: Option<u64>,
    ) {
        self.devices.insert(
            device_id,
            DeviceRecord {
                confirmed: true,
                public_key,
                revoked,
                session_expires_at_ms,
            },
        );
    }

    pub fn restore_session(
        &mut self,
        token_hash: String,
        device_id: String,
        csrf_hash: [u8; 32],
        expires_at_ms: u64,
    ) {
        self.sessions.insert(
            token_hash,
            SessionRecord {
                device_id,
                csrf_hash,
                expires_at_ms,
            },
        );
    }

    pub fn create_offer(
        &mut self,
        origin: &str,
        host_installation_id: &str,
        now_ms: u64,
    ) -> PairingOffer {
        let offer_id = uuid::Uuid::new_v4().to_string();
        let secret = secret_bytes();
        let secret_encoded = URL_SAFE_NO_PAD.encode(secret);
        let expires_at_ms = now_ms.saturating_add(OFFER_LIFETIME_MS);
        self.offers.insert(
            offer_id.clone(),
            OfferRecord {
                secret_hash: digest(&secret),
                human_code: secret_encoded
                    .chars()
                    .take(10)
                    .collect::<String>()
                    .to_ascii_uppercase(),
                origin: origin.into(),
                host_installation_id: host_installation_id.into(),
                expires_at_ms,
                consumed: false,
            },
        );
        let human_code = secret_encoded.chars().take(10).collect();
        PairingOffer {
            url: format!("{origin}/pair#secret={secret_encoded}&offerId={offer_id}&hostInstallationId={host_installation_id}"),
            offer_id,
            expires_at_ms,
            human_code,
        }
    }

    pub fn claim_offer(
        &mut self,
        offer_id: &str,
        secret_encoded: &str,
        public_key: DevicePublicKeyJwk,
        label: &str,
        now_ms: u64,
    ) -> Result<ClaimedDevice, PairingError> {
        self.claim_offer_with_session_expiration(
            offer_id,
            secret_encoded,
            public_key,
            label,
            None,
            now_ms,
        )
    }

    pub fn claim_offer_with_session_expiration(
        &mut self,
        offer_id: &str,
        secret_encoded: &str,
        public_key: DevicePublicKeyJwk,
        label: &str,
        session_expires_at_ms: Option<u64>,
        now_ms: u64,
    ) -> Result<ClaimedDevice, PairingError> {
        let secret = URL_SAFE_NO_PAD
            .decode(secret_encoded)
            .map_err(|_| PairingError::InvalidSecret)?;
        if secret.len() != 32 {
            return Err(PairingError::InvalidSecret);
        }
        let offer = self.offers.get(offer_id).ok_or(PairingError::NotFound)?;
        if digest(&secret).ct_eq(&offer.secret_hash).unwrap_u8() != 1 {
            return Err(PairingError::InvalidSecret);
        }
        self.claim_offer_record(offer_id, public_key, label, session_expires_at_ms, now_ms)
    }

    pub fn claim_offer_by_human_code(
        &mut self,
        human_code: &str,
        public_key: DevicePublicKeyJwk,
        label: &str,
        session_expires_at_ms: Option<u64>,
        now_ms: u64,
    ) -> Result<ClaimedDevice, PairingError> {
        let normalized = human_code.trim().to_ascii_uppercase();
        let offer_id = self
            .offers
            .iter()
            .find(|(_, offer)| offer.human_code == normalized)
            .map(|(offer_id, _)| offer_id.clone())
            .ok_or(PairingError::NotFound)?;
        self.claim_offer_record(&offer_id, public_key, label, session_expires_at_ms, now_ms)
    }

    pub fn allow_human_code_attempt(&mut self, now_ms: u64) -> bool {
        self.human_code_attempts
            .retain(|attempt| now_ms.saturating_sub(*attempt) < HUMAN_CODE_ATTEMPT_WINDOW_MS);
        if self.human_code_attempts.len() >= HUMAN_CODE_ATTEMPT_LIMIT {
            return false;
        }
        self.human_code_attempts.push(now_ms);
        true
    }

    fn claim_offer_record(
        &mut self,
        offer_id: &str,
        public_key: DevicePublicKeyJwk,
        label: &str,
        session_expires_at_ms: Option<u64>,
        now_ms: u64,
    ) -> Result<ClaimedDevice, PairingError> {
        let offer = self
            .offers
            .get_mut(offer_id)
            .ok_or(PairingError::NotFound)?;
        if offer.consumed {
            return Err(PairingError::AlreadyConsumed);
        }
        if now_ms >= offer.expires_at_ms {
            return Err(PairingError::Expired);
        }
        validate_public_key(&public_key)?;
        if label.trim().is_empty() {
            return Err(PairingError::BindingMismatch);
        }
        offer.consumed = true;
        let device_id = uuid::Uuid::new_v4().to_string();
        let challenge = Challenge {
            challenge_id: uuid::Uuid::new_v4().to_string(),
            device_id: device_id.clone(),
            nonce: URL_SAFE_NO_PAD.encode(secret_bytes()),
            origin: offer.origin.clone(),
            host_installation_id: offer.host_installation_id.clone(),
            offer_id: offer_id.into(),
            issued_at_ms: now_ms,
            expires_at_ms: now_ms.saturating_add(OFFER_LIFETIME_MS),
        };
        self.devices.insert(
            device_id.clone(),
            DeviceRecord {
                confirmed: false,
                public_key: public_key.clone(),
                revoked: false,
                session_expires_at_ms,
            },
        );
        self.pending.insert(
            device_id.clone(),
            PendingEnrollment {
                device_id: device_id.clone(),
                label: label.trim().into(),
                public_key,
                challenge: challenge.clone(),
                session_expires_at_ms,
            },
        );
        self.challenges.insert(
            challenge.challenge_id.clone(),
            ChallengeRecord {
                challenge: challenge.clone(),
                consumed: false,
            },
        );
        Ok(ClaimedDevice {
            device_id,
            challenge,
        })
    }

    pub fn pending_enrollments(&self, now_ms: u64) -> Vec<PendingEnrollment> {
        self.pending
            .values()
            .filter(|pending| now_ms < pending.challenge.expires_at_ms)
            .cloned()
            .collect()
    }

    pub fn pending_enrollment(
        &self,
        device_id: &str,
        now_ms: u64,
    ) -> Result<PendingEnrollment, PairingError> {
        let pending = self.pending.get(device_id).ok_or(PairingError::NotFound)?;
        if now_ms >= pending.challenge.expires_at_ms {
            return Err(PairingError::ChallengeExpired);
        }
        Ok(pending.clone())
    }

    /// Call only after the local owner confirms and durable device storage succeeds.
    pub fn confirm_enrollment(&mut self, device_id: &str, now_ms: u64) -> Result<(), PairingError> {
        self.pending_enrollment(device_id, now_ms)?;
        self.devices
            .get_mut(device_id)
            .ok_or(PairingError::NotFound)?
            .confirmed = true;
        self.pending.remove(device_id);
        Ok(())
    }

    pub fn cancel_offer(&mut self, offer_id: &str) -> bool {
        let removed = self.offers.remove(offer_id).is_some();
        let pending: Vec<_> = self
            .pending
            .values()
            .filter(|p| p.challenge.offer_id == offer_id)
            .map(|p| p.device_id.clone())
            .collect();
        for device_id in pending {
            self.revoke_device(&device_id);
        }
        removed
    }

    /// Return an in-memory claim to its pre-claim state when durable device
    /// persistence fails. This keeps a transient SQLite error from burning a
    /// still-valid, single-use pairing offer.
    pub fn rollback_claim(&mut self, claimed: &ClaimedDevice) {
        if let Some(challenge) = self.challenges.remove(&claimed.challenge.challenge_id) {
            self.devices.remove(&claimed.device_id);
            self.pending.remove(&claimed.device_id);
            if let Some(offer) = self.offers.get_mut(&challenge.challenge.offer_id) {
                offer.consumed = false;
            }
        }
    }

    pub fn verify_challenge(
        &mut self,
        challenge_id: &str,
        signature_encoded: &str,
        now_ms: u64,
    ) -> Result<VerifiedSession, PairingError> {
        let challenge = self
            .challenges
            .get_mut(challenge_id)
            .ok_or(PairingError::ChallengeNotFound)?;
        if challenge.consumed {
            return Err(PairingError::ChallengeReplayed);
        }
        if now_ms >= challenge.challenge.expires_at_ms {
            return Err(PairingError::ChallengeExpired);
        }
        let device = self
            .devices
            .get(&challenge.challenge.device_id)
            .ok_or(PairingError::NotFound)?;
        if !device.confirmed {
            return Err(PairingError::ConfirmationRequired);
        }
        if device.revoked {
            return Err(PairingError::BindingMismatch);
        }
        if device
            .session_expires_at_ms
            .is_some_and(|expires_at_ms| now_ms >= expires_at_ms)
        {
            return Err(PairingError::SessionExpired);
        }
        let session_expires_at_ms = device
            .session_expires_at_ms
            .unwrap_or(NEVER_EXPIRES_AT_MS)
            .min(now_ms.saturating_add(60 * 60 * 1000));
        let transcript = ChallengeTranscript {
            device_id: &challenge.challenge.device_id,
            challenge_id: &challenge.challenge.challenge_id,
            nonce: &challenge.challenge.nonce,
            origin: &challenge.challenge.origin,
            host_installation_id: &challenge.challenge.host_installation_id,
            issued_at_ms: challenge.challenge.issued_at_ms,
            expires_at_ms: challenge.challenge.expires_at_ms,
        };
        verify_signature(
            &device.public_key,
            &canonical_challenge_transcript(&transcript),
            signature_encoded,
        )?;
        challenge.consumed = true;
        let token = URL_SAFE_NO_PAD.encode(secret_bytes());
        let csrf_token = URL_SAFE_NO_PAD.encode(secret_bytes());
        self.sessions.insert(
            token_hash(&token),
            SessionRecord {
                device_id: challenge.challenge.device_id.clone(),
                csrf_hash: digest(csrf_token.as_bytes()),
                expires_at_ms: session_expires_at_ms,
            },
        );
        Ok(VerifiedSession {
            device_id: challenge.challenge.device_id.clone(),
            session_token: token,
            csrf_token,
            host_installation_id: challenge.challenge.host_installation_id.clone(),
            expires_at_ms: session_expires_at_ms,
        })
    }

    pub fn issue_fresh_challenge(
        &mut self,
        device_id: &str,
        origin: &str,
        host_installation_id: &str,
        now_ms: u64,
    ) -> Result<Challenge, PairingError> {
        let device = self.devices.get(device_id).ok_or(PairingError::NotFound)?;
        if !device.confirmed {
            return Err(PairingError::ConfirmationRequired);
        }
        if device.revoked {
            return Err(PairingError::BindingMismatch);
        }
        if device
            .session_expires_at_ms
            .is_some_and(|expires_at_ms| now_ms >= expires_at_ms)
        {
            return Err(PairingError::SessionExpired);
        }
        let challenge = Challenge {
            challenge_id: uuid::Uuid::new_v4().to_string(),
            device_id: device_id.to_owned(),
            nonce: URL_SAFE_NO_PAD.encode(secret_bytes()),
            origin: origin.to_owned(),
            host_installation_id: host_installation_id.to_owned(),
            offer_id: "authenticated-session".into(),
            issued_at_ms: now_ms,
            expires_at_ms: now_ms.saturating_add(CHALLENGE_LIFETIME_MS),
        };
        self.challenges.insert(
            challenge.challenge_id.clone(),
            ChallengeRecord {
                challenge: challenge.clone(),
                consumed: false,
            },
        );
        Ok(challenge)
    }

    /// Return a newly-created session to its pre-verification state when the
    /// durable session insert fails.
    pub fn rollback_session(&mut self, challenge_id: &str, session: &VerifiedSession) {
        self.sessions.remove(&token_hash(&session.session_token));
        if let Some(challenge) = self.challenges.get_mut(challenge_id) {
            challenge.consumed = false;
        }
    }

    pub fn verify_fresh_challenge(
        &mut self,
        challenge_id: &str,
        expected_device_id: &str,
        signature_encoded: &str,
        now_ms: u64,
    ) -> Result<(), PairingError> {
        let challenge = self
            .challenges
            .get_mut(challenge_id)
            .ok_or(PairingError::ChallengeNotFound)?;
        if challenge.consumed {
            return Err(PairingError::ChallengeReplayed);
        }
        if now_ms >= challenge.challenge.expires_at_ms {
            return Err(PairingError::ChallengeExpired);
        }
        if challenge.challenge.device_id != expected_device_id {
            return Err(PairingError::BindingMismatch);
        }
        let device = self
            .devices
            .get(expected_device_id)
            .ok_or(PairingError::NotFound)?;
        if !device.confirmed {
            return Err(PairingError::ConfirmationRequired);
        }
        if device.revoked {
            return Err(PairingError::BindingMismatch);
        }
        let transcript = ChallengeTranscript {
            device_id: &challenge.challenge.device_id,
            challenge_id: &challenge.challenge.challenge_id,
            nonce: &challenge.challenge.nonce,
            origin: &challenge.challenge.origin,
            host_installation_id: &challenge.challenge.host_installation_id,
            issued_at_ms: challenge.challenge.issued_at_ms,
            expires_at_ms: challenge.challenge.expires_at_ms,
        };
        verify_signature(
            &device.public_key,
            &canonical_challenge_transcript(&transcript),
            signature_encoded,
        )?;
        challenge.consumed = true;
        Ok(())
    }

    pub fn verify_action_signature(
        &self,
        device_id: &str,
        transcript: &ActionTranscript<'_>,
        signature_encoded: &str,
    ) -> Result<(), PairingError> {
        if transcript.device_id != device_id {
            return Err(PairingError::BindingMismatch);
        }
        let device = self.devices.get(device_id).ok_or(PairingError::NotFound)?;
        if !device.confirmed {
            return Err(PairingError::ConfirmationRequired);
        }
        if device.revoked {
            return Err(PairingError::BindingMismatch);
        }
        verify_signature(
            &device.public_key,
            &canonical_action_transcript(transcript),
            signature_encoded,
        )
    }

    pub fn verify_session(
        &self,
        session_token: &str,
        csrf_token: Option<&str>,
        now_ms: u64,
    ) -> Result<String, PairingError> {
        let session = self
            .sessions
            .get(&token_hash(session_token))
            .ok_or(PairingError::SessionNotFound)?;
        let device = self
            .devices
            .get(&session.device_id)
            .ok_or(PairingError::SessionNotFound)?;
        if device.revoked || !device.confirmed {
            return Err(PairingError::SessionNotFound);
        }
        if now_ms >= session.expires_at_ms {
            return Err(PairingError::SessionExpired);
        }
        if let Some(csrf_token) = csrf_token {
            if digest(csrf_token.as_bytes())
                .ct_eq(&session.csrf_hash)
                .unwrap_u8()
                != 1
            {
                return Err(PairingError::CsrfMismatch);
            }
        }
        Ok(session.device_id.clone())
    }

    pub fn revoke_device(&mut self, device_id: &str) {
        self.pending.remove(device_id);
        if let Some(device) = self.devices.get_mut(device_id) {
            device.revoked = true;
        }
        self.challenges
            .retain(|_, challenge| challenge.challenge.device_id != device_id);
        self.sessions
            .retain(|_, session| session.device_id != device_id);
    }
}

pub fn session_expiration_deadline(option: &str, now_ms: u64) -> Result<Option<u64>, PairingError> {
    let lifetime_ms = match option {
        "1h" => Some(60 * 60 * 1000),
        "1d" => Some(24 * 60 * 60 * 1000),
        "7d" => Some(7 * 24 * 60 * 60 * 1000),
        "30d" => Some(30 * 24 * 60 * 60 * 1000),
        "never" => None,
        _ => return Err(PairingError::InvalidSessionExpiration),
    };
    Ok(lifetime_ms.map(|lifetime| now_ms.saturating_add(lifetime)))
}

fn validate_public_key(public_key: &DevicePublicKeyJwk) -> Result<(), PairingError> {
    if public_key.kty != "EC" || public_key.crv != "P-256" {
        return Err(PairingError::InvalidPublicKey);
    }
    let _ = verifying_key(public_key)?;
    Ok(())
}

fn verify_signature(
    public_key: &DevicePublicKeyJwk,
    message: &[u8],
    signature_encoded: &str,
) -> Result<(), PairingError> {
    let signature = URL_SAFE_NO_PAD
        .decode(signature_encoded)
        .map_err(|_| PairingError::InvalidSignature)?;
    let signature =
        Signature::from_slice(&signature).map_err(|_| PairingError::InvalidSignature)?;
    verifying_key(public_key)?
        .verify(message, &signature)
        .map_err(|_| PairingError::InvalidSignature)
}

fn verifying_key(public_key: &DevicePublicKeyJwk) -> Result<VerifyingKey, PairingError> {
    let x = URL_SAFE_NO_PAD
        .decode(&public_key.x)
        .map_err(|_| PairingError::InvalidPublicKey)?;
    let y = URL_SAFE_NO_PAD
        .decode(&public_key.y)
        .map_err(|_| PairingError::InvalidPublicKey)?;
    if x.len() != 32 || y.len() != 32 {
        return Err(PairingError::InvalidPublicKey);
    }
    let mut point = [0_u8; 65];
    point[0] = 4;
    point[1..33].copy_from_slice(&x);
    point[33..].copy_from_slice(&y);
    VerifyingKey::from_sec1_bytes(&point).map_err(|_| PairingError::InvalidPublicKey)
}

fn secret_bytes() -> [u8; 32] {
    let mut output = [0_u8; 32];
    getrandom::fill(&mut output).expect("operating system randomness unavailable");
    output
}

fn digest(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

fn token_hash(token: &str) -> String {
    hex::encode(digest(token.as_bytes()))
}

pub fn session_token_hash(token: &str) -> String {
    token_hash(token)
}

pub fn csrf_token_hash(token: &str) -> String {
    hex::encode(digest(token.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::ecdsa::{signature::Signer, SigningKey};

    fn public_key_fixture() -> DevicePublicKeyJwk {
        DevicePublicKeyJwk {
            kty: "EC".into(),
            crv: "P-256".into(),
            x: URL_SAFE_NO_PAD.encode(
                hex::decode("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296")
                    .expect("generator x"),
            ),
            y: URL_SAFE_NO_PAD.encode(
                hex::decode("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")
                    .expect("generator y"),
            ),
        }
    }

    #[test]
    fn offer_is_fragment_only_and_single_use() {
        let mut state = PairingState::default();
        let offer = state.create_offer("https://wonder.example.ts.net", "install-1", 1_000);
        assert!(offer.url.contains("#secret="));
        assert!(!offer.url.contains("?secret="));
        assert_eq!(
            state.claim_offer(
                &offer.offer_id,
                "not-the-secret",
                public_key_fixture(),
                "Chrome",
                1_001
            ),
            Err(PairingError::InvalidSecret)
        );
        let secret = offer
            .url
            .split("secret=")
            .nth(1)
            .and_then(|value| value.split('&').next())
            .expect("secret in fragment");
        let claimed = state.claim_offer(
            &offer.offer_id,
            secret,
            public_key_fixture(),
            "Chrome",
            1_001,
        );
        let claimed = claimed.expect("valid offer claim");
        assert_eq!(claimed.challenge.device_id, claimed.device_id);
        assert_eq!(
            state.claim_offer(
                &offer.offer_id,
                secret,
                public_key_fixture(),
                "Chrome",
                1_002
            ),
            Err(PairingError::AlreadyConsumed)
        );
    }

    #[test]
    fn expired_offer_cannot_be_claimed() {
        let mut state = PairingState::default();
        let offer = state.create_offer("https://wonder.example.ts.net", "install-1", 1_000);
        let secret = offer
            .url
            .split("secret=")
            .nth(1)
            .and_then(|value| value.split('&').next())
            .expect("secret in fragment");
        assert_eq!(
            state.claim_offer(
                &offer.offer_id,
                secret,
                public_key_fixture(),
                "Chrome",
                offer.expires_at_ms
            ),
            Err(PairingError::Expired)
        );
    }

    #[test]
    fn offer_cannot_be_claimed_after_daemon_restart() {
        let mut state_before_restart = PairingState::default();
        let offer =
            state_before_restart.create_offer("https://wonder.example.ts.net", "install-1", 1_000);
        let secret = offer
            .url
            .split("secret=")
            .nth(1)
            .and_then(|value| value.split('&').next())
            .expect("secret in fragment");

        // Pairing offers are intentionally held in memory, so a fresh state
        // created during daemon startup must not accept an old offer.
        let mut state_after_restart = PairingState::default();
        assert_eq!(
            state_after_restart.claim_offer(
                &offer.offer_id,
                secret,
                public_key_fixture(),
                "Chrome",
                1_001,
            ),
            Err(PairingError::NotFound)
        );
    }

    #[test]
    fn human_code_claim_is_case_insensitive_and_single_use() {
        let mut state = PairingState::default();
        let offer = state.create_offer("https://wonder.example.ts.net", "install-1", 1_000);
        let claimed = state
            .claim_offer_by_human_code(
                &offer.human_code.to_ascii_lowercase(),
                public_key_fixture(),
                "Native iPhone",
                None,
                1_001,
            )
            .expect("valid human code claim");
        assert_eq!(claimed.challenge.offer_id, offer.offer_id);
        assert_eq!(
            state.claim_offer_by_human_code(
                &offer.human_code,
                public_key_fixture(),
                "Native iPhone",
                None,
                1_002,
            ),
            Err(PairingError::AlreadyConsumed)
        );
    }

    #[test]
    fn human_code_attempts_are_bounded_per_window() {
        let mut state = PairingState::default();
        for _ in 0..20 {
            assert!(state.allow_human_code_attempt(1_000));
        }
        assert!(!state.allow_human_code_attempt(1_000));
        assert!(state.allow_human_code_attempt(61_001));
    }

    #[test]
    fn session_expiration_options_are_allowlisted() {
        assert_eq!(
            session_expiration_deadline("1h", 1_000),
            Ok(Some(3_601_000))
        );
        assert_eq!(session_expiration_deadline("never", 1_000), Ok(None));
        assert_eq!(
            session_expiration_deadline("90d", 1_000),
            Err(PairingError::InvalidSessionExpiration)
        );
    }

    #[test]
    fn signed_challenge_is_verified_and_session_replay_is_rejected() {
        let mut state = PairingState::default();
        let signing_key = SigningKey::from_slice(&[1_u8; 32]).expect("deterministic signing key");
        let point = signing_key.verifying_key().to_sec1_point(false);
        let public_key = DevicePublicKeyJwk {
            kty: "EC".into(),
            crv: "P-256".into(),
            x: URL_SAFE_NO_PAD.encode(point.x().expect("x coordinate")),
            y: URL_SAFE_NO_PAD.encode(point.y().expect("y coordinate")),
        };
        let offer = state.create_offer("https://wonder.example.ts.net", "install-1", 1_000);
        let secret = offer
            .url
            .split("secret=")
            .nth(1)
            .and_then(|value| value.split('&').next())
            .expect("secret in fragment");
        let claimed = state
            .claim_offer(&offer.offer_id, secret, public_key, "Chrome", 1_001)
            .expect("claim");
        assert_eq!(
            state.verify_challenge(&claimed.challenge.challenge_id, "invalid", 1_001),
            Err(PairingError::ConfirmationRequired)
        );
        assert_eq!(
            state.issue_fresh_challenge(
                &claimed.device_id,
                "https://wonder.example.ts.net",
                "install-1",
                1_001
            ),
            Err(PairingError::ConfirmationRequired)
        );
        state
            .confirm_enrollment(&claimed.device_id, 1_001)
            .expect("owner confirmation");
        let transcript = ChallengeTranscript {
            device_id: &claimed.device_id,
            challenge_id: &claimed.challenge.challenge_id,
            nonce: &claimed.challenge.nonce,
            origin: &claimed.challenge.origin,
            host_installation_id: &claimed.challenge.host_installation_id,
            issued_at_ms: claimed.challenge.issued_at_ms,
            expires_at_ms: claimed.challenge.expires_at_ms,
        };
        let signature: Signature = signing_key.sign(&transcript.to_bytes());
        let signature = URL_SAFE_NO_PAD.encode(signature.to_bytes());
        assert_eq!(
            state.verify_challenge(&claimed.challenge.challenge_id, "invalid", 1_002),
            Err(PairingError::InvalidSignature)
        );
        let session = state
            .verify_challenge(&claimed.challenge.challenge_id, &signature, 1_002)
            .expect("session");
        assert_eq!(
            state.verify_session(&session.session_token, Some(&session.csrf_token), 1_003),
            Ok(claimed.device_id)
        );
        assert_eq!(
            state.verify_challenge(&claimed.challenge.challenge_id, &signature, 1_004),
            Err(PairingError::ChallengeReplayed)
        );
    }

    #[test]
    fn an_existing_device_can_establish_a_fresh_session() {
        let mut state = PairingState::default();
        let signing_key = SigningKey::from_slice(&[2_u8; 32]).expect("deterministic signing key");
        let point = signing_key.verifying_key().to_sec1_point(false);
        let public_key = DevicePublicKeyJwk {
            kty: "EC".into(),
            crv: "P-256".into(),
            x: URL_SAFE_NO_PAD.encode(point.x().expect("x coordinate")),
            y: URL_SAFE_NO_PAD.encode(point.y().expect("y coordinate")),
        };
        let offer = state.create_offer("https://wonder.example.ts.net", "install-1", 1_000);
        let secret = offer
            .url
            .split("secret=")
            .nth(1)
            .and_then(|value| value.split('&').next())
            .expect("secret in fragment");
        let claimed = state
            .claim_offer(&offer.offer_id, secret, public_key, "Chrome", 1_001)
            .expect("claim");
        state
            .confirm_enrollment(&claimed.device_id, 1_001)
            .expect("owner confirmation");
        let sign_challenge = |challenge: &Challenge| {
            let transcript = ChallengeTranscript {
                device_id: &challenge.device_id,
                challenge_id: &challenge.challenge_id,
                nonce: &challenge.nonce,
                origin: &challenge.origin,
                host_installation_id: &challenge.host_installation_id,
                issued_at_ms: challenge.issued_at_ms,
                expires_at_ms: challenge.expires_at_ms,
            };
            let signature: Signature = signing_key.sign(&transcript.to_bytes());
            URL_SAFE_NO_PAD.encode(signature.to_bytes())
        };
        let session = state
            .verify_challenge(
                &claimed.challenge.challenge_id,
                &sign_challenge(&claimed.challenge),
                1_002,
            )
            .expect("initial session");
        let renewed_at = session.expires_at_ms + 1;
        assert_eq!(
            state.verify_session(&session.session_token, None, renewed_at),
            Err(PairingError::SessionExpired)
        );
        let fresh = state
            .issue_fresh_challenge(
                &claimed.device_id,
                "https://wonder.example.ts.net",
                "install-1",
                renewed_at,
            )
            .expect("fresh challenge");
        let refreshed = state
            .verify_challenge(&fresh.challenge_id, &sign_challenge(&fresh), renewed_at + 1)
            .expect("refreshed session");
        assert_ne!(session.session_token, refreshed.session_token);
        assert_eq!(refreshed.device_id, claimed.device_id);
        assert_eq!(
            state.verify_session(
                &refreshed.session_token,
                Some(&refreshed.csrf_token),
                renewed_at + 2
            ),
            Ok(claimed.device_id.clone())
        );
        state.revoke_device(&claimed.device_id);
        assert_eq!(
            state.verify_session(&session.session_token, None, renewed_at + 3),
            Err(PairingError::SessionNotFound)
        );
        assert_eq!(
            state.verify_session(&refreshed.session_token, None, renewed_at + 3),
            Err(PairingError::SessionNotFound)
        );
        assert_eq!(
            state.issue_fresh_challenge(
                &claimed.device_id,
                "https://wonder.example.ts.net",
                "install-1",
                renewed_at + 3
            ),
            Err(PairingError::BindingMismatch)
        );
    }
    #[test]
    fn rejected_expired_and_cancelled_enrollments_cannot_be_confirmed() {
        for mode in ["reject", "expire", "cancel"] {
            let mut state = PairingState::default();
            let offer = state.create_offer("https://wonder.example.ts.net", "install-1", 1_000);
            let claimed = state
                .claim_offer_by_human_code(
                    &offer.human_code,
                    public_key_fixture(),
                    "Phone",
                    None,
                    1_001,
                )
                .unwrap();
            assert_eq!(state.pending_enrollments(1_002).len(), 1);
            match mode {
                "reject" => state.revoke_device(&claimed.device_id),
                "cancel" => {
                    assert!(state.cancel_offer(&offer.offer_id));
                }
                _ => {}
            }
            let now = if mode == "expire" {
                claimed.challenge.expires_at_ms
            } else {
                1_003
            };
            assert!(state.confirm_enrollment(&claimed.device_id, now).is_err());
            assert!(state.pending_enrollments(now).is_empty());
            assert!(state
                .issue_fresh_challenge(
                    &claimed.device_id,
                    "https://wonder.example.ts.net",
                    "install-1",
                    now
                )
                .is_err());
        }
    }
}
