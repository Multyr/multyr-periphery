import {
  hexToBytes,
  keccak256,
  recoverAddress,
  serializeTransaction,
  toHex,
  hashMessage,
  hashTypedData,
  serializeSignature,
  type Address,
  type Hex,
  type LocalAccount,
  type Signature,
} from "viem";
import { publicKeyToAddress, toAccount } from "viem/accounts";

// Shared plumbing for cloud-KMS secp256k1 keys. The private key never leaves the
// HSM; we hand it a 32-byte digest and get back a DER-encoded ECDSA signature.

const SECP256K1_N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;

/** Signs a 32-byte digest, returns DER `SEQUENCE { INTEGER r, INTEGER s }`. */
export type DigestSigner = (digest: Uint8Array) => Promise<Uint8Array>;

/** Extract the 65-byte uncompressed point from a DER SubjectPublicKeyInfo. */
export function spkiToUncompressedPoint(spki: Uint8Array): Hex {
  // secp256k1 SPKI ends with BIT STRING 0x00 || 0x04 || X(32) || Y(32).
  const point = spki.slice(spki.length - 65);
  if (point[0] !== 0x04) throw new Error("kms: public key is not an uncompressed secp256k1 point");
  return toHex(point);
}

export function parseDerSignature(der: Uint8Array): { r: bigint; s: bigint } {
  let i = 0;
  const expect = (b: number) => {
    if (der[i++] !== b) throw new Error("kms: malformed DER signature");
  };
  const readLen = () => {
    let len = der[i++];
    if (len & 0x80) {
      const n = len & 0x7f;
      len = 0;
      for (let k = 0; k < n; k++) len = (len << 8) | der[i++];
    }
    return len;
  };
  const readInt = () => {
    expect(0x02);
    const len = readLen();
    const bytes = der.slice(i, i + len);
    i += len;
    return BigInt(toHex(bytes));
  };
  expect(0x30);
  readLen();
  const r = readInt();
  const s = readInt();
  return { r, s };
}

/** Turn a KMS DER signature into an Ethereum signature (low-s, recovered yParity). */
export async function toEthSignature(hash: Hex, der: Uint8Array, address: Address): Promise<Signature> {
  let { r, s } = parseDerSignature(der);
  // EIP-2: KMS may return high-s; Ethereum requires s <= n/2.
  if (s > SECP256K1_N / 2n) s = SECP256K1_N - s;
  const rHex = toHex(r, { size: 32 });
  const sHex = toHex(s, { size: 32 });
  for (const yParity of [0, 1] as const) {
    const recovered = await recoverAddress({ hash, signature: { r: rHex, s: sHex, yParity } });
    if (recovered.toLowerCase() === address.toLowerCase()) return { r: rHex, s: sHex, yParity };
  }
  throw new Error("kms: signature does not recover to the key's address");
}

export function kmsAccount(publicKey: Hex, signDigest: DigestSigner): LocalAccount {
  const address = publicKeyToAddress(publicKey);
  const sign = async (hash: Hex) => toEthSignature(hash, await signDigest(hexToBytes(hash)), address);
  return toAccount({
    address,
    async signMessage({ message }) {
      return serializeSignature(await sign(hashMessage(message)));
    },
    async signTransaction(tx, opts) {
      const serializer = opts?.serializer ?? serializeTransaction;
      const signature = await sign(keccak256(await serializer(tx)));
      return serializer(tx, signature);
    },
    async signTypedData(typedData) {
      return serializeSignature(await sign(hashTypedData(typedData as any)));
    },
  });
}
