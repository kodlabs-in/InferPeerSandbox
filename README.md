# InferPeer test apps

This repository contains three thin test consumers of the sibling `inferpeer-swift` package:

- `InferPeerSandbox-iOS` is an iPad-only text and image chat client. It discovers resources, pairs by a single-use code, shows exact resource/model choices, and invokes `InferPeer.run` locally or remotely.
- `InferPeerResourceHost-iOS` is an iPhone-only foreground resource host.
- `InferPeerResourceHost-macOS` is the equivalent foreground Mac resource host.

The host apps download, verify, register, load, and remove models only through
`InferPeerModelStore`. They expose inference only while visible in the foreground. The Sandbox does
not contain a parallel model downloader or runtime path.

Generate the Xcode project:

```sh
xcodegen generate
```

Install a signed text or vision model in each resource host before pairing it with the iPad. Copy
the short-lived invitation from the host into the Sandbox Pair sheet. The Sandbox can then select
that named resource and exact model for each chat request.

This 1.0 test surface intentionally excludes speech and audio. Public package types retained for
source compatibility are not advertised by these apps or by the signed starter catalog.

## License

The test apps are available under the [Apache License 2.0](LICENSE). Downloaded model artifacts
remain governed by their cataloged upstream licenses.
