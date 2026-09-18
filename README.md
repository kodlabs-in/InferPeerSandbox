# InferPeer Sandbox

This is a separate, non-shipping SwiftUI validation host for the sibling `inferpeer-swift`
package. It is intentionally not an executable product in that package.

Generate the Xcode project:

```sh
xcodegen generate
```

Use the `InferPeerSandbox-iOS` scheme on an iPhone or iPad and the
`InferPeerSandbox-macOS` scheme on a Mac. The app automatically exercises device-local identity,
Keychain, protected/excluded storage, telemetry status, and a deterministic inference stream.

Each target bundles the root-level `Models/Qwen3-0.6B-4bit` snapshot and automatically runs it
offline at launch. The snapshot is pinned to revision
`73e3e38d981303bc594367cd910ea6eb48349da8`; its `model.safetensors` SHA-256 is verified before
loading. The model remains outside this Git repository. Installing the app transfers the same
verified snapshot to each device. The optional folder picker can validate another local copy of the
same pinned snapshot; other model metadata or weight digests are rejected.

Runtime evidence is written under the app's Application Support `InferPeerSandbox` directory:

- `latest-validation.txt` contains package smoke-check results.
- `latest-model-validation.txt` contains the model revision, digest, and non-content timings.
- `latest-cluster-validation.txt` contains physical cluster outcomes and non-content metrics.
- `latest-lifecycle-validation.txt` contains foreground/background participation changes.
- `latest-failure-validation.txt` contains deterministic failure-policy outcomes.

The evidence deliberately excludes prompts and generated text.

## Physical cluster roles

The sandbox can run one role when launched with `INFERPEER_VALIDATION_ROLE` set to `coordinator`,
`worker`, or `caller`. A coordinator discovers the active Wi-Fi interface and its IPv4 address unless
`INFERPEER_COORDINATOR_HOST` supplies an explicit numeric Wi-Fi address. It writes separate caller
and worker invitation files to the evidence directory; copy the appropriate record to another
device as `cluster-invitation.json` before launching that role.

Optional caller scenarios are selected with `INFERPEER_VALIDATION_SCENARIO`: `retry`, `reconnect`,
`restart-seed`, `restart-resume`, or `acceptance`. Use `INFERPEER_ALLOWED_WORKER_ID` to constrain a
request to one worker. `INFERPEER_VALIDATION_RUN_ID` selects an isolated durable caller outbox;
reuse the same identifier only when a reconnect or restart scenario must recover prior state. These
launch variables are validation controls and are not a production pairing interface.

For deterministic physical retry measurement, launch the worker with
`INFERPEER_WORKER_INTERRUPT_ONCE=1`. Its first real MLX attempt emits output and then reports one
retryable execution interruption; the second attempt uses the same loaded model and completes.

Mobile coordinators update their in-process worker eligibility when the SwiftUI scene moves between
foreground and background. Device deployment over USB does not change the package's Wi-Fi-only
runtime policy.

## License

InferPeer Sandbox is available under the [Apache License 2.0](LICENSE). The bundled validation model
remains governed by its own Apache-2.0 licence and attribution.
