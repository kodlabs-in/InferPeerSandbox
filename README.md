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

The **Choose local MLX model** action runs a real model directly from a host-provided folder. The
sandbox does not download model files. Before recording release evidence, replace the displayed
smoke-test metadata with the model's actual revision, quantization, tokenizer, chat template,
licence, context limit, and independently verified digest.

