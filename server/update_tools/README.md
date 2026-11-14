# Signed updates

The official update service uses a signed channel index, signed release manifests, and content-addressed objects. Clients can reuse unchanged files, resume downloads and verify reconstructed packages before installation.

- `build_publication.py --help`: build signed publication artifacts from release inputs.
- `verify_http.py --help`: verify a publication over HTTPS using its public key.
- `benchmark.py --help`: compare reconstructed download sizes.
- `publish_release.py --help`: publish and verify releases in an authorized deployment.

Use your own signing keys, separate from the server's account/sync secret, when testing a custom release stream. The included Ed25519 key is for **verification only**. Unmodified WeekGlass clients trust the official key and fixed update origin; self-hosting sync does not change either.
