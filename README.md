# InferPeer Sandbox

This repository contains the iPad-only reference business client for the sibling `inferpeer-swift`
package. It discovers resources, pairs by a single-use invitation, shows exact resource/model
choices, and invokes `InferPeer.run` locally or remotely.

The distributable Mac and iPhone/iPad resource apps live in the sibling `InferPeerResource`
repository. This sandbox intentionally contains no resource-host UI, model downloader, runtime
adapter, or server target.

Generate the Xcode project:

```sh
xcodegen generate
```

Install a signed text or vision model in InferPeer Resource before pairing it with the iPad. Copy
the short-lived invitation from the resource app into the Sandbox Pair sheet. The Sandbox can then
select that named resource and exact model for each chat request.

This 1.0 test surface intentionally excludes speech and audio. Public package types retained for
source compatibility are not advertised by these apps or by the signed starter catalog.

## License

The test app is available under the [Apache License 2.0](LICENSE).
