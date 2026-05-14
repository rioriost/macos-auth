use std::convert::TryInto;

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

pub const PROTOCOL_VERSION: u16 = 1;
pub const NONCE_LEN: usize = 32;
pub const ED25519_PUBLIC_KEY_LEN: usize = 32;
pub const ED25519_SIGNATURE_LEN: usize = 64;

const REQUEST_DOMAIN: &[u8] = b"macos-auth/auth-request/v1";
const RESPONSE_DOMAIN: &[u8] = b"macos-auth/auth-response/v1";

#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("unsupported protocol version: {0}")]
    UnsupportedVersion(u16),
    #[error("unsupported signature algorithm: {0:?}")]
    UnsupportedAlgorithm(SignatureAlgorithm),
    #[error("invalid nonce length: expected {expected}, got {actual}")]
    InvalidNonceLength { expected: usize, actual: usize },
    #[error("invalid request validity window")]
    InvalidValidityWindow,
    #[error("request or response is expired")]
    Expired,
    #[error("request or response was created too far in the future")]
    CreatedInFuture,
    #[error("invalid Ed25519 public key")]
    InvalidPublicKey,
    #[error("invalid Ed25519 signature length")]
    InvalidSignatureLength,
    #[error("signature verification failed")]
    SignatureVerificationFailed,
    #[error("response does not match request")]
    ResponseBindingMismatch,
    #[error("field is too large to encode canonically: {0}")]
    FieldTooLarge(&'static str),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SignatureAlgorithm {
    Ed25519,
}

impl SignatureAlgorithm {
    fn canonical_name(self) -> &'static str {
        match self {
            SignatureAlgorithm::Ed25519 => "Ed25519",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Decision {
    Approved,
    Denied,
    Unavailable,
    Cancelled,
    Failed,
}

impl Decision {
    fn canonical_name(self) -> &'static str {
        match self {
            Decision::Approved => "approved",
            Decision::Denied => "denied",
            Decision::Unavailable => "unavailable",
            Decision::Cancelled => "cancelled",
            Decision::Failed => "failed",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AuthMethod {
    Watch,
    TouchId,
    BiometricOrWatch,
    Unknown,
    None,
}

impl AuthMethod {
    fn canonical_name(self) -> &'static str {
        match self {
            AuthMethod::Watch => "watch",
            AuthMethod::TouchId => "touchid",
            AuthMethod::BiometricOrWatch => "biometric-or-watch",
            AuthMethod::Unknown => "unknown",
            AuthMethod::None => "none",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthRequestBody {
    pub protocol_version: u16,
    pub request_id: String,
    pub nonce: Vec<u8>,
    pub created_at_ms: u64,
    pub expires_at_ms: u64,
    pub linux_host_id: String,
    pub linux_hostname: String,
    pub pam_service: String,
    pub pam_user: String,
    pub pam_ruser: Option<String>,
    pub pam_rhost: Option<String>,
    pub pam_tty: Option<String>,
    pub sudo_command: Option<String>,
    pub client_pid: Option<u32>,
    pub key_id: String,
    pub alg: SignatureAlgorithm,
}

impl AuthRequestBody {
    pub fn validate(&self) -> Result<(), ProtocolError> {
        if self.protocol_version != PROTOCOL_VERSION {
            return Err(ProtocolError::UnsupportedVersion(self.protocol_version));
        }
        if self.alg != SignatureAlgorithm::Ed25519 {
            return Err(ProtocolError::UnsupportedAlgorithm(self.alg));
        }
        if self.nonce.len() != NONCE_LEN {
            return Err(ProtocolError::InvalidNonceLength {
                expected: NONCE_LEN,
                actual: self.nonce.len(),
            });
        }
        if self.created_at_ms >= self.expires_at_ms {
            return Err(ProtocolError::InvalidValidityWindow);
        }
        Ok(())
    }

    pub fn canonical_bytes(&self) -> Result<Vec<u8>, ProtocolError> {
        self.validate()?;

        let mut out = Vec::new();
        encode_bytes(&mut out, REQUEST_DOMAIN, "request_domain")?;
        encode_u16(&mut out, self.protocol_version);
        encode_str(&mut out, &self.request_id, "request_id")?;
        encode_bytes(&mut out, &self.nonce, "nonce")?;
        encode_u64(&mut out, self.created_at_ms);
        encode_u64(&mut out, self.expires_at_ms);
        encode_str(&mut out, &self.linux_host_id, "linux_host_id")?;
        encode_str(&mut out, &self.linux_hostname, "linux_hostname")?;
        encode_str(&mut out, &self.pam_service, "pam_service")?;
        encode_str(&mut out, &self.pam_user, "pam_user")?;
        encode_optional_str(&mut out, self.pam_ruser.as_deref(), "pam_ruser")?;
        encode_optional_str(&mut out, self.pam_rhost.as_deref(), "pam_rhost")?;
        encode_optional_str(&mut out, self.pam_tty.as_deref(), "pam_tty")?;
        encode_optional_str(&mut out, self.sudo_command.as_deref(), "sudo_command")?;
        encode_optional_u32(&mut out, self.client_pid);
        encode_str(&mut out, &self.key_id, "key_id")?;
        encode_str(&mut out, self.alg.canonical_name(), "alg")?;
        Ok(out)
    }

    pub fn sha256(&self) -> Result<[u8; 32], ProtocolError> {
        let bytes = self.canonical_bytes()?;
        Ok(Sha256::digest(bytes).into())
    }

    pub fn verify_freshness(
        &self,
        now_ms: u64,
        allowed_future_skew_ms: u64,
    ) -> Result<(), ProtocolError> {
        if now_ms > self.expires_at_ms {
            return Err(ProtocolError::Expired);
        }
        if self.created_at_ms > now_ms.saturating_add(allowed_future_skew_ms) {
            return Err(ProtocolError::CreatedInFuture);
        }
        Ok(())
    }

    pub fn sign(&self, signing_key: &SigningKey) -> Result<SignedAuthRequest, ProtocolError> {
        let bytes = self.canonical_bytes()?;
        let signature = signing_key.sign(&bytes).to_bytes().to_vec();
        Ok(SignedAuthRequest {
            body: self.clone(),
            signature,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignedAuthRequest {
    pub body: AuthRequestBody,
    pub signature: Vec<u8>,
}

impl SignedAuthRequest {
    pub fn verify(&self, public_key: &[u8]) -> Result<(), ProtocolError> {
        verify_ed25519(public_key, &self.body.canonical_bytes()?, &self.signature)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthResponseBody {
    pub protocol_version: u16,
    pub request_id: String,
    pub nonce: Vec<u8>,
    pub request_hash: Vec<u8>,
    pub linux_host_id: String,
    pub pam_service: String,
    pub pam_user: String,
    pub decision: Decision,
    pub auth_method: AuthMethod,
    pub created_at_ms: u64,
    pub expires_at_ms: u64,
    pub agent_key_id: String,
    pub alg: SignatureAlgorithm,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
}

impl AuthResponseBody {
    pub fn for_request(
        request: &AuthRequestBody,
        decision: Decision,
        auth_method: AuthMethod,
        created_at_ms: u64,
        expires_at_ms: u64,
        agent_key_id: impl Into<String>,
    ) -> Result<Self, ProtocolError> {
        Ok(Self {
            protocol_version: request.protocol_version,
            request_id: request.request_id.clone(),
            nonce: request.nonce.clone(),
            request_hash: request.sha256()?.to_vec(),
            linux_host_id: request.linux_host_id.clone(),
            pam_service: request.pam_service.clone(),
            pam_user: request.pam_user.clone(),
            decision,
            auth_method,
            created_at_ms,
            expires_at_ms,
            agent_key_id: agent_key_id.into(),
            alg: SignatureAlgorithm::Ed25519,
            error_code: None,
            error_message: None,
        })
    }

    pub fn validate(&self) -> Result<(), ProtocolError> {
        if self.protocol_version != PROTOCOL_VERSION {
            return Err(ProtocolError::UnsupportedVersion(self.protocol_version));
        }
        if self.alg != SignatureAlgorithm::Ed25519 {
            return Err(ProtocolError::UnsupportedAlgorithm(self.alg));
        }
        if self.nonce.len() != NONCE_LEN {
            return Err(ProtocolError::InvalidNonceLength {
                expected: NONCE_LEN,
                actual: self.nonce.len(),
            });
        }
        if self.created_at_ms >= self.expires_at_ms {
            return Err(ProtocolError::InvalidValidityWindow);
        }
        Ok(())
    }

    pub fn canonical_bytes(&self) -> Result<Vec<u8>, ProtocolError> {
        self.validate()?;

        let mut out = Vec::new();
        encode_bytes(&mut out, RESPONSE_DOMAIN, "response_domain")?;
        encode_u16(&mut out, self.protocol_version);
        encode_str(&mut out, &self.request_id, "request_id")?;
        encode_bytes(&mut out, &self.nonce, "nonce")?;
        encode_bytes(&mut out, &self.request_hash, "request_hash")?;
        encode_str(&mut out, &self.linux_host_id, "linux_host_id")?;
        encode_str(&mut out, &self.pam_service, "pam_service")?;
        encode_str(&mut out, &self.pam_user, "pam_user")?;
        encode_str(&mut out, self.decision.canonical_name(), "decision")?;
        encode_str(&mut out, self.auth_method.canonical_name(), "auth_method")?;
        encode_u64(&mut out, self.created_at_ms);
        encode_u64(&mut out, self.expires_at_ms);
        encode_str(&mut out, &self.agent_key_id, "agent_key_id")?;
        encode_str(&mut out, self.alg.canonical_name(), "alg")?;
        encode_optional_str(&mut out, self.error_code.as_deref(), "error_code")?;
        encode_optional_str(&mut out, self.error_message.as_deref(), "error_message")?;
        Ok(out)
    }

    pub fn verify_binding(&self, request: &AuthRequestBody) -> Result<(), ProtocolError> {
        let expected_hash = request.sha256()?;
        let matches = self.request_id == request.request_id
            && self.nonce == request.nonce
            && self.request_hash == expected_hash
            && self.linux_host_id == request.linux_host_id
            && self.pam_service == request.pam_service
            && self.pam_user == request.pam_user;

        if matches {
            Ok(())
        } else {
            Err(ProtocolError::ResponseBindingMismatch)
        }
    }

    pub fn verify_freshness(
        &self,
        now_ms: u64,
        allowed_future_skew_ms: u64,
    ) -> Result<(), ProtocolError> {
        if now_ms > self.expires_at_ms {
            return Err(ProtocolError::Expired);
        }
        if self.created_at_ms > now_ms.saturating_add(allowed_future_skew_ms) {
            return Err(ProtocolError::CreatedInFuture);
        }
        Ok(())
    }

    pub fn sign(&self, signing_key: &SigningKey) -> Result<SignedAuthResponse, ProtocolError> {
        let bytes = self.canonical_bytes()?;
        let signature = signing_key.sign(&bytes).to_bytes().to_vec();
        Ok(SignedAuthResponse {
            body: self.clone(),
            signature,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignedAuthResponse {
    pub body: AuthResponseBody,
    pub signature: Vec<u8>,
}

impl SignedAuthResponse {
    pub fn verify(&self, public_key: &[u8]) -> Result<(), ProtocolError> {
        verify_ed25519(public_key, &self.body.canonical_bytes()?, &self.signature)
    }

    pub fn verify_for_request(
        &self,
        request: &AuthRequestBody,
        public_key: &[u8],
    ) -> Result<(), ProtocolError> {
        self.verify(public_key)?;
        self.body.verify_binding(request)
    }
}

fn verify_ed25519(
    public_key: &[u8],
    message: &[u8],
    signature: &[u8],
) -> Result<(), ProtocolError> {
    let public_key_bytes: [u8; ED25519_PUBLIC_KEY_LEN] = public_key
        .try_into()
        .map_err(|_| ProtocolError::InvalidPublicKey)?;
    let verifying_key =
        VerifyingKey::from_bytes(&public_key_bytes).map_err(|_| ProtocolError::InvalidPublicKey)?;
    let signature =
        Signature::from_slice(signature).map_err(|_| ProtocolError::InvalidSignatureLength)?;

    verifying_key
        .verify(message, &signature)
        .map_err(|_| ProtocolError::SignatureVerificationFailed)
}

fn encode_u16(out: &mut Vec<u8>, value: u16) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn encode_u32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn encode_u64(out: &mut Vec<u8>, value: u64) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn encode_bytes(
    out: &mut Vec<u8>,
    value: &[u8],
    field_name: &'static str,
) -> Result<(), ProtocolError> {
    let len = u32::try_from(value.len()).map_err(|_| ProtocolError::FieldTooLarge(field_name))?;
    encode_u32(out, len);
    out.extend_from_slice(value);
    Ok(())
}

fn encode_str(
    out: &mut Vec<u8>,
    value: &str,
    field_name: &'static str,
) -> Result<(), ProtocolError> {
    encode_bytes(out, value.as_bytes(), field_name)
}

fn encode_optional_str(
    out: &mut Vec<u8>,
    value: Option<&str>,
    field_name: &'static str,
) -> Result<(), ProtocolError> {
    match value {
        Some(value) => {
            out.push(1);
            encode_str(out, value, field_name)?;
        }
        None => out.push(0),
    }
    Ok(())
}

fn encode_optional_u32(out: &mut Vec<u8>, value: Option<u32>) {
    match value {
        Some(value) => {
            out.push(1);
            encode_u32(out, value);
        }
        None => out.push(0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signing_key(byte: u8) -> SigningKey {
        SigningKey::from_bytes(&[byte; 32])
    }

    fn sample_request() -> AuthRequestBody {
        AuthRequestBody {
            protocol_version: PROTOCOL_VERSION,
            request_id: "req-123".to_string(),
            nonce: vec![0x42; NONCE_LEN],
            created_at_ms: 1_700_000_000_000,
            expires_at_ms: 1_700_000_030_000,
            linux_host_id: "host-abc".to_string(),
            linux_hostname: "linux.example.com".to_string(),
            pam_service: "sudo".to_string(),
            pam_user: "alice".to_string(),
            pam_ruser: Some("alice".to_string()),
            pam_rhost: None,
            pam_tty: Some("pts/3".to_string()),
            sudo_command: None,
            client_pid: Some(12345),
            key_id: "host-key-1".to_string(),
            alg: SignatureAlgorithm::Ed25519,
        }
    }

    #[test]
    fn request_canonical_bytes_are_deterministic() {
        let request = sample_request();
        let bytes_a = request.canonical_bytes().unwrap();
        let bytes_b = request.canonical_bytes().unwrap();
        assert_eq!(bytes_a, bytes_b);
        assert!(bytes_a.starts_with(&(REQUEST_DOMAIN.len() as u32).to_be_bytes()));
    }

    #[test]
    fn request_freshness_accepts_valid_time() {
        let request = sample_request();
        request.verify_freshness(1_700_000_001_000, 30_000).unwrap();
    }

    #[test]
    fn request_freshness_accepts_exact_expiry_boundary() {
        let request = sample_request();
        request
            .verify_freshness(request.expires_at_ms, 30_000)
            .unwrap();
    }

    #[test]
    fn request_freshness_rejects_expired() {
        let request = sample_request();
        assert!(matches!(
            request.verify_freshness(request.expires_at_ms + 1, 30_000),
            Err(ProtocolError::Expired)
        ));
    }

    #[test]
    fn request_freshness_accepts_future_within_skew() {
        let request = sample_request();
        request
            .verify_freshness(request.created_at_ms - 30_000, 30_000)
            .unwrap();
    }

    #[test]
    fn request_freshness_rejects_future_beyond_skew() {
        let request = sample_request();
        assert!(matches!(
            request.verify_freshness(request.created_at_ms - 30_001, 30_000),
            Err(ProtocolError::CreatedInFuture)
        ));
    }

    #[test]
    fn response_freshness_accepts_valid_time() {
        let request = sample_request();
        let response = AuthResponseBody::for_request(
            &request,
            Decision::Approved,
            AuthMethod::BiometricOrWatch,
            1_700_000_001_000,
            1_700_000_011_000,
            "agent-key-1",
        )
        .unwrap();
        response
            .verify_freshness(1_700_000_002_000, 30_000)
            .unwrap();
    }

    #[test]
    fn response_freshness_accepts_exact_expiry_boundary() {
        let request = sample_request();
        let response = AuthResponseBody::for_request(
            &request,
            Decision::Approved,
            AuthMethod::BiometricOrWatch,
            1_700_000_001_000,
            1_700_000_011_000,
            "agent-key-1",
        )
        .unwrap();
        response
            .verify_freshness(response.expires_at_ms, 30_000)
            .unwrap();
    }

    #[test]
    fn response_freshness_rejects_expired() {
        let request = sample_request();
        let response = AuthResponseBody::for_request(
            &request,
            Decision::Approved,
            AuthMethod::BiometricOrWatch,
            1_700_000_001_000,
            1_700_000_011_000,
            "agent-key-1",
        )
        .unwrap();
        assert!(matches!(
            response.verify_freshness(response.expires_at_ms + 1, 30_000),
            Err(ProtocolError::Expired)
        ));
    }

    #[test]
    fn response_freshness_rejects_future_beyond_skew() {
        let request = sample_request();
        let response = AuthResponseBody::for_request(
            &request,
            Decision::Approved,
            AuthMethod::BiometricOrWatch,
            1_700_000_001_000,
            1_700_000_011_000,
            "agent-key-1",
        )
        .unwrap();
        assert!(matches!(
            response.verify_freshness(response.created_at_ms - 30_001, 30_000),
            Err(ProtocolError::CreatedInFuture)
        ));
    }

    #[test]
    fn request_signature_verifies() {
        let key = signing_key(7);
        let request = sample_request().sign(&key).unwrap();
        request.verify(&key.verifying_key().to_bytes()).unwrap();
    }

    #[test]
    fn request_signature_rejects_tampering() {
        let key = signing_key(7);
        let mut request = sample_request().sign(&key).unwrap();
        request.body.pam_user = "mallory".to_string();
        assert!(matches!(
            request.verify(&key.verifying_key().to_bytes()),
            Err(ProtocolError::SignatureVerificationFailed)
        ));
    }

    #[test]
    fn response_binds_to_request() {
        let agent_key = signing_key(9);
        let request = sample_request();
        let response = AuthResponseBody::for_request(
            &request,
            Decision::Approved,
            AuthMethod::BiometricOrWatch,
            1_700_000_001_000,
            1_700_000_011_000,
            "agent-key-1",
        )
        .unwrap()
        .sign(&agent_key)
        .unwrap();

        response
            .verify_for_request(&request, &agent_key.verifying_key().to_bytes())
            .unwrap();
    }

    #[test]
    fn test_vector_v1_approval_verifies() {
        #[derive(serde::Deserialize)]
        struct Vector {
            host_public_key_hex: String,
            agent_public_key_hex: String,
            request_hash_hex: String,
            request: SignedAuthRequest,
            response: SignedAuthResponse,
        }

        let vector: Vector =
            serde_json::from_str(include_str!("../../../test-vectors/v1/approval.json")).unwrap();
        let host_public_key = hex::decode(vector.host_public_key_hex).unwrap();
        let agent_public_key = hex::decode(vector.agent_public_key_hex).unwrap();

        vector.request.verify(&host_public_key).unwrap();
        assert_eq!(
            hex::encode(vector.request.body.sha256().unwrap()),
            vector.request_hash_hex
        );
        vector
            .response
            .verify_for_request(&vector.request.body, &agent_public_key)
            .unwrap();
    }

    #[test]
    fn response_rejects_wrong_request() {
        let agent_key = signing_key(9);
        let request = sample_request();
        let mut other_request = sample_request();
        other_request.request_id = "req-other".to_string();

        let response = AuthResponseBody::for_request(
            &request,
            Decision::Approved,
            AuthMethod::BiometricOrWatch,
            1_700_000_001_000,
            1_700_000_011_000,
            "agent-key-1",
        )
        .unwrap()
        .sign(&agent_key)
        .unwrap();

        assert!(matches!(
            response.verify_for_request(&other_request, &agent_key.verifying_key().to_bytes()),
            Err(ProtocolError::ResponseBindingMismatch)
        ));
    }
}
