#![no_main]

use libfuzzer_sys::fuzz_target;
use macos_auth_protocol::SignedAuthResponse;

fuzz_target!(|data: &[u8]| {
    if let Ok(response) = serde_json::from_slice::<SignedAuthResponse>(data) {
        let _ = response.body.canonical_bytes();
    }
});
