import type { LocalAccount } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { RuntimeEnv } from "../config.ts";
import { kmsAccount, spkiToUncompressedPoint } from "./kms.ts";

// Cloud SDKs are optional dependencies and loaded lazily: the primary image
// only needs the AWS client, the secondary only the GCP client.

async function awsKms(keyId: string): Promise<LocalAccount> {
  const { KMSClient, GetPublicKeyCommand, SignCommand } = await import("@aws-sdk/client-kms");
  const client = new KMSClient({});
  const pub = await client.send(new GetPublicKeyCommand({ KeyId: keyId }));
  if (pub.KeySpec !== "ECC_SECG_P256K1") throw new Error(`aws-kms: key ${keyId} is ${pub.KeySpec}, need ECC_SECG_P256K1`);
  return kmsAccount(spkiToUncompressedPoint(pub.PublicKey!), async (digest) => {
    const out = await client.send(
      new SignCommand({ KeyId: keyId, Message: digest, MessageType: "DIGEST", SigningAlgorithm: "ECDSA_SHA_256" }),
    );
    return out.Signature!;
  });
}

async function gcpKms(keyVersionName: string): Promise<LocalAccount> {
  const { KeyManagementServiceClient } = await import("@google-cloud/kms");
  const client = new KeyManagementServiceClient();
  const [pub] = await client.getPublicKey({ name: keyVersionName });
  if (pub.algorithm !== "EC_SIGN_SECP256K1_SHA256") {
    throw new Error(`gcp-kms: key ${keyVersionName} is ${pub.algorithm}, need EC_SIGN_SECP256K1_SHA256`);
  }
  const der = Buffer.from(pub.pem!.replace(/-----[^-]+-----|\s/g, ""), "base64");
  return kmsAccount(spkiToUncompressedPoint(new Uint8Array(der)), async (digest) => {
    // GCP takes the 32-byte keccak hash in the sha256 slot; it signs the digest as given.
    const [res] = await client.asymmetricSign({ name: keyVersionName, digest: { sha256: digest } });
    return new Uint8Array(res.signature as Uint8Array);
  });
}

export async function loadSigner(env: RuntimeEnv): Promise<LocalAccount | undefined> {
  switch (env.signer) {
    case "local":
      return privateKeyToAccount(env.privateKey!);
    case "aws-kms":
      return awsKms(env.awsKmsKeyId!);
    case "gcp-kms":
      return gcpKms(env.gcpKmsKeyName!);
    case "none":
      return undefined;
  }
}
