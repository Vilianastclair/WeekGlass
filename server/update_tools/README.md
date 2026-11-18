# Signed updates

The official update service uses a signed channel index, signed release manifests, and content-addressed objects. Clients can reuse unchanged files, resume downloads and verify reconstructed packages before installation.

- `build_publication.py --help`: build signed publication artifacts from release inputs.
- `verify_http.py --help`: verify a publication over HTTPS using its public key.
- `benchmark.py --help`: compare reconstructed download sizes.
- `publish_release.py --help`: publish and verify releases in an authorized deployment.

Cleanup keeps the two separately published corresponding source archives, `source/weekglass-cloud-20261117-admin.tar.gz` and `source/weekglass-cloud-20261118-schedule.tar.gz`. They are outside the update deletion inventory. Unrecognized files, including deployment archives, and symbolic links still block cleanup.

Use your own signing keys, separate from the server's account/sync secret, when testing a custom release stream. The included Ed25519 key is for **verification only**. Unmodified WeekGlass clients trust the official key and fixed update origin; self-hosting sync does not change either.
