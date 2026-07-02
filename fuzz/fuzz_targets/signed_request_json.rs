#![no_main]

use libfuzzer_sys::fuzz_target;
use macos_auth_protocol::SignedAuthRequest;

fuzz_target!(|data: &[u8]| {
    if let Ok(request) = serde_json::from_slice::<SignedAuthRequest>(data) {
        let _ = request.body.canonical_bytes();
    }
});
