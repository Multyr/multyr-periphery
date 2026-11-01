// Run inside the keeper image under the ECS task role. Signs a diagnostic
// message only: no transaction is constructed or broadcast.
import { KMSClient, GetPublicKeyCommand, SignCommand } from '@aws-sdk/client-kms';
import { keccak256, toBytes, hexToBytes } from 'viem';
import { publicKeyToAddress } from 'viem/accounts';
import { spkiToUncompressedPoint, toEthSignature } from '/app/src/signers/kms.ts';
const key = 'arn:aws:kms:eu-north-1:820140266807:key/0fe89976-e0f2-4ce0-831b-b7f72a2531d7';
const expected = '0x404da3b474b8b4c87d5e3c39230c71a7237630da';
const client = new KMSClient({ region: 'eu-north-1' });
try {
  const pub = await client.send(new GetPublicKeyCommand({ KeyId: key }));
  if (pub.KeySpec !== 'ECC_SECG_P256K1' || pub.KeyUsage !== 'SIGN_VERIFY') throw new Error('Unexpected key type or usage');
  const address = publicKeyToAddress(spkiToUncompressedPoint(pub.PublicKey));
  if (address.toLowerCase() !== expected) throw new Error('KMS signer address mismatch');
  const digest = keccak256(toBytes('Multyr ECS simulation setup: diagnostic message, not a transaction; ' + new Date().toISOString()));
  const signed = await client.send(new SignCommand({ KeyId: key, Message: hexToBytes(digest), MessageType: 'DIGEST', SigningAlgorithm: 'ECDSA_SHA_256' }));
  await toEthSignature(digest, signed.Signature, address);
  console.log(JSON.stringify({ check: 'ecs-task-role-kms', status: 'PASS', address, getPublicKey: true, signAndRecover: true, transactionsBroadcast: 0 }));
} catch (error) {
  console.error(JSON.stringify({ check: 'ecs-task-role-kms', status: 'FAIL', name: error.name, message: error.message, transactionsBroadcast: 0 }));
  process.exitCode = 1;
}
