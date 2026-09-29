// Checks an update archive's EdDSA signature against the public key a build carries (#92), the way
// Sparkle will on the user's Mac: `sign_update --verify` only proves the archive matches the
// private key it was signed with, not that the application will accept it.
//
//   xcrun swift Scripts/check-update-signature.swift <public key> <signature> <archive>
//
// Both keys are base64, as `generate_keys` prints them and `SUPublicEDKey` holds them.

import CryptoKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 3 else {
  FileHandle.standardError.write(
    Data("usage: check-update-signature.swift <public key> <signature> <archive>\n".utf8))
  exit(2)
}
let values = Array(arguments)
guard let key = Data(base64Encoded: values[0]),
  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key)
else {
  FileHandle.standardError.write(Data("not an Ed25519 public key: \(values[0])\n".utf8))
  exit(1)
}
guard let signature = Data(base64Encoded: values[1]) else {
  FileHandle.standardError.write(Data("not a base64 signature\n".utf8))
  exit(1)
}
guard let archive = FileManager.default.contents(atPath: values[2]) else {
  FileHandle.standardError.write(Data("cannot read \(values[2])\n".utf8))
  exit(1)
}
guard publicKey.isValidSignature(signature, for: archive) else {
  FileHandle.standardError.write(
    Data("the signature of \(values[2]) does not verify with the application's key\n".utf8))
  exit(1)
}
print("EdDSA signature verified with the application's key")
