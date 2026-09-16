// sec(hwkey): P-256 ES256 verify + AES-GCM seal envelope + pinned roots.
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:proximity_protocol/protocol.dart';
import 'package:test/test.dart';

SecureRandom _testRandom([int salt = 3]) {
  final r = SecureRandom('Fortuna');
  r.seed(KeyParameter(Uint8List.fromList(
      List.generate(32, (i) => (i * 11 + salt) & 0xFF))));
  return r;
}

(Uint8List, Uint8List, Uint8List) _signFixture([int salt = 3]) {
  final domain = ECDomainParameters('prime256v1');
  final gen = ECKeyGenerator()
    ..init(ParametersWithRandom(
        ECKeyGeneratorParameters(domain), _testRandom(salt)));
  final pair = gen.generateKeyPair();
  final ECPublicKey pub = pair.publicKey;
  // Uncompressed point 0x04||x||y → raw x||y 64B (the pkD wire form).
  final uncompressed = pub.Q!.getEncoded(false);
  final pkD = Uint8List.fromList(uncompressed.sublist(1));
  final preimage = Uint8List.fromList(List.generate(48, (i) => i));
  final signer = ECDSASigner(SHA256Digest())
    ..init(
        true,
        ParametersWithRandom(
            PrivateKeyParameter<ECPrivateKey>(pair.privateKey),
            _testRandom(salt)));
  final ECSignature sig = signer.generateSignature(preimage) as ECSignature;
  Uint8List be(BigInt v) {
    final hex = v.toRadixString(16).padLeft(64, '0');
    return hexDecode(hex);
  }

  return (pkD, preimage, Uint8List.fromList([...be(sig.r), ...be(sig.s)]));
}

// Genuine Google fixtures (audit 2026-09-13 ground truth — public trust
// anchors and test vectors, not secrets):
// - _genuineLeafDerHex: TEE_EC_NONE.pem leaf from
//   android/keyattestation testdata/blueline/sdk28 (genuine Google-signed
//   Pixel attestation; attestationChallenge "challenge", 643B DER).
// - _googleRsaRootDerHex / _googleEcRootDerHex: the two current roots from
//   android/keyattestation roots.json (RSA serial f92009e853b6b045,
//   1312B; EC CN "Key Attestation CA1", 550B).
// These caught two live-path bugs the self-consistent fakes could not
// (wrong OID length byte, wrong RSA pin) — every genuine chain failed
// closed. Keep them byte-exact; any edit must re-verify against the
// upstream sources above.
const _genuineLeafDerHex =
    '3082027f30820226a003020102020101300a06082a8648ce3d04030230293119'
    '30170603550405131061306236336133353734333637336237310c300a060355'
    '040c0c035445453020170d3730303130313030303030305a180f323130363032'
    '30373036323831355a301f311d301b06035504030c14416e64726f6964204b65'
    '7973746f7265204b65793059301306072a8648ce3d020106082a8648ce3d0301'
    '07034200044387a332699ce4ef6f707a478dfa351272c8b86b1e6fd7d3336e85'
    '3c1401323500a34cf2558250a671319009c59e92a47d93c0ca4ee02dd1449e04'
    '9eb48934d6a382014530820141300e0603551d0f0101ff040403020780308201'
    '2d060a2b06010401d6790201110482011d308201190201030a01010201040a01'
    '0104096368616c6c656e67650400308183bf853d0802060166228e2d76bf8545'
    '730471306f314930470442636f6d2e676f6f676c652e776972656c6573732e61'
    '6e64726f69642e73656375726974792e6174746573746174696f6e7665726966'
    '6965722e636f6c6c6563746f7202010031220420103938ee4537e59e8ee792f6'
    '54504fb8346fc6b346d0bbc4415fc339fcfc8ec13078a1053103020102a20302'
    '0103a30402020100aa03020101bf8377020500bf853e03020100bf85402c302a'
    '04000101000a010204206e9d0c5bea2cda99f3e5c76fb2740cdf8793d1d36342'
    '2cd065d22bf0a2bb5badbf8541050203015f90bf85420502030314b4bf854e05'
    '0203031451bf854f0502030314b4300a06082a8648ce3d040302034700304402'
    '200db51c969f648ff01b2e655ee06d66de348da5eaeb395b5e6f643c99b70b31'
    '5002203cd6ecb34bc3d303f87d5b98428eb48672c8c78f7bd9d1f0c5c63abc24'
    '701c92';

const _googleRsaRootDerHex =
    '3082051c30820304a003020102020900f1c172a699eaf51d300d06092a864886'
    'f70d01010b0500301b3119301706035504051310663932303039653835336236'
    '62303435301e170d3232303332303138303734385a170d343230333135313830'
    '3734385a301b3119301706035504051310663932303039653835336236623034'
    '3530820222300d06092a864886f70d01010105000382020f003082020a028202'
    '0100afb6c7822bb1a701ec2bb42e8bcc541663abef982f32c77f7531030c9752'
    '4b1b5fe809fbc72aa9451f743cbd9a6f1335744aa55e77f6b6ac3535ee17c25e'
    '639517dd9c92e6374a53cbfe258f8ffbb6fd129378a22a4ca99c452d47a59f32'
    '01f44197ca1ccd7e762fb2f53151b6feb2fffd2b6fe4fe5bc6bd9ec34bfe0823'
    '9daafceb8eb5a8ed2b3acd9c5e3a7790e1b51442793159859811ad9eb2a96bbd'
    'd7a57c93a91c41fccd27d67fd6f671aa0b815261ad384fa37944864604ddb3d8'
    'c4f920a19b1656c2f14ad6d03c56ec060899041c1ed1a5fe6d3440b556bad1d0'
    'a152589c53e55d370762f0122eef91861b1b0e6c4c80927499c0e9bec0b83e3b'
    'c1f93c72c049604bbd2f1345e62c3f8e26dbec06c94766f3c128239d4f4312fa'
    'd8123887e06becf567583bf8355a81feeabaf99a83c8df3e2a322afc672bf120'
    'b135158b6821ceaf309b6eee77f98833b018daa10e451f06a374d50781f35908'
    '2966bb778b9308942698e74e0bcd24628a01c2cc03e51f0b3e5b4ac1e4df9eaf'
    '9ff6a492a77c1483882885015b422ce67b80b88c9b48e13b607ab545c723ff8c'
    '44f8f2d368b9f6520d31145ebf9e862ad71df6a3bfd2450959d653740d97a12f'
    '368b13ef66d5d0a54a6e2f5d9a6fef446832bc67844725861f093dd0e6f3405d'
    'a89643ef0f4d69b6420051fdb93049673e36950580d3cdf4fbd08bc584839526'
    '00630203010001a3633061301d0603551d0e041604143661e1007c880509518b'
    '446c47ff1a4cc9ea4f12301f0603551d230418301680143661e1007c88050951'
    '8b446c47ff1a4cc9ea4f12300f0603551d130101ff040530030101ff300e0603'
    '551d0f0101ff040403020204300d06092a864886f70d01010b05000382020100'
    '7c70ca939651dcf14faa0ab3a58371fbd7be2599a0ac6e8fdb2740b5ec912030'
    'b6f892faeab1766cd35537981fea00183fd6de4f77900e447011b35861a86202'
    '5bf9ca31abf9ef87fdad93783c2d9996e7c65dbeec21d2691a23bd72d46188bb'
    '98ba5cb5d0971c5191841e91d260cd86b648186d96daea5b023d80003fcddcc8'
    '357ed5a3a44dfd510a9fe53343cabe6c58375d1162c2badf58eb95e19d71d931'
    'a122bffe64906e07169e600466bcc7a05d7fd20b28d47660227d182f35612d20'
    '3f897097e104f6877279cf7ce796e286d67bfc3507717a2d832088404967eef3'
    '4e0203de9c40a4d395a69ed9fc1ea978dd375fefda7a8e86780dcb3d77eb5985'
    '9abe1799a287fc8b53c0e7bbd8d23d65cc12d6555a0afb089130c2117766f6b0'
    '8d3c0635d224ee9c81c55d187eeca3f394719ec02abff133a8841467d3f34d7e'
    '1eee46c94e499ff129b37db4c06dc37ed9f1ddafbe75eafd859db26d7e24b570'
    '9fac980ffc9a70d241970a5d7656bc79a54c8ec17a9c19c881039ff732927b4e'
    'a7493aaf830507a2c80e10264967512ecdb1f8cacc1bb74dad2ad284161c7ebf'
    'e39381eff4e95fa31aca9358bb1face08d2ee03c1fefb3fa9504366a6a9e71e8'
    'bda238ee00be4cda648181a49014fa07f9bf534d41b8e0414f384894c119abda'
    'a40d6b8cd9c039916e55dc525471f1e7c3521d6088365b183bc8771065e98542';

const _googleEcRootDerHex =
    '30820222308201a8a00302010202110084a9d0297b0eb58ae7ff0e80de760605'
    '300a06082a8648ce3d0403033052311c301a06035504030c134b657920417474'
    '6573746174696f6e204341313110300e060355040b0c07416e64726f69643113'
    '3011060355040a0c0a476f6f676c65204c4c43310b3009060355040613025553'
    '301e170d3235303731373232333231385a170d3335303731353232333231385a'
    '3052311c301a06035504030c134b6579204174746573746174696f6e20434131'
    '3110300e060355040b0c07416e64726f696431133011060355040a0c0a476f6f'
    '676c65204c4c43310b30090603550406130255533076301006072a8648ce3d02'
    '0106052b810400220362000423da23714edf3e5b050a3c72e8846ace078ea0ad'
    '1bf98b15f453d0cb08b2c3c110453909f6edeac1f9c8e031a848b941a829535c'
    '97e07c2719beceb416290d3079eee1f911cce6df803914d8a3577b34fdfd143e'
    '5ef36c9713c7ac70a8c211aba3423040300f0603551d130101ff040530030101'
    'ff300e0603551d0f0101ff040403020106301d0603551d0e041604145232bb2c'
    'fb46439bdcd681a90e6566e03441ea40300a06082a8648ce3d04030303680030'
    '65023044df8cf3bf1f0a91791d824bba74656a03fcb1ecea10e2e36da8a627c7'
    '1146982f1c06953f522dd8e4569cf4514391e70231008a06cb118a447553a6aa'
    '46445889b5010e393a7ffacd46731798b91db387ff34950caef6f0050a3e84e0'
    '05dcfa8b2646';

// Genuine Google RSA vintage roots (field 2026-09-14 ground truth — public
// trust anchors from developer.android.com root-certificates, not secrets):
// - _googleRsa2019RootDerHex: serial D50FF25BA3F2D6B3, 2019-11-22 →
//   2034-11-18. Chain root 1ef1a04b (Samsung A52s field report) IS this
//   cert — the previous e50511a9 pin (unverified gist) matched no Google
//   cert and is deleted.
// - _googleRsa2021RootDerHex: serial C36B7C44B9AE1831, 2021-11-17 →
//   2036-11-13. Same RSA key as the 2022 root (one key, renewed certs).
// Keep byte-exact; any edit must re-verify against the docs page above.
const _googleRsa2019RootDerHex =
    '3082051c30820304a003020102020900d50ff25ba3f2d6b3300d06092a864886'
    'f70d01010b0500301b3119301706035504051310663932303039653835336236'
    '62303435301e170d3139313132323230333735385a170d333431313138323033'
    '3735385a301b3119301706035504051310663932303039653835336236623034'
    '3530820222300d06092a864886f70d01010105000382020f003082020a028202'
    '0100afb6c7822bb1a701ec2bb42e8bcc541663abef982f32c77f7531030c9752'
    '4b1b5fe809fbc72aa9451f743cbd9a6f1335744aa55e77f6b6ac3535ee17c25e'
    '639517dd9c92e6374a53cbfe258f8ffbb6fd129378a22a4ca99c452d47a59f32'
    '01f44197ca1ccd7e762fb2f53151b6feb2fffd2b6fe4fe5bc6bd9ec34bfe0823'
    '9daafceb8eb5a8ed2b3acd9c5e3a7790e1b51442793159859811ad9eb2a96bbd'
    'd7a57c93a91c41fccd27d67fd6f671aa0b815261ad384fa37944864604ddb3d8'
    'c4f920a19b1656c2f14ad6d03c56ec060899041c1ed1a5fe6d3440b556bad1d0'
    'a152589c53e55d370762f0122eef91861b1b0e6c4c80927499c0e9bec0b83e3b'
    'c1f93c72c049604bbd2f1345e62c3f8e26dbec06c94766f3c128239d4f4312fa'
    'd8123887e06becf567583bf8355a81feeabaf99a83c8df3e2a322afc672bf120'
    'b135158b6821ceaf309b6eee77f98833b018daa10e451f06a374d50781f35908'
    '2966bb778b9308942698e74e0bcd24628a01c2cc03e51f0b3e5b4ac1e4df9eaf'
    '9ff6a492a77c1483882885015b422ce67b80b88c9b48e13b607ab545c723ff8c'
    '44f8f2d368b9f6520d31145ebf9e862ad71df6a3bfd2450959d653740d97a12f'
    '368b13ef66d5d0a54a6e2f5d9a6fef446832bc67844725861f093dd0e6f3405d'
    'a89643ef0f4d69b6420051fdb93049673e36950580d3cdf4fbd08bc584839526'
    '00630203010001a3633061301d0603551d0e041604143661e1007c880509518b'
    '446c47ff1a4cc9ea4f12301f0603551d230418301680143661e1007c88050951'
    '8b446c47ff1a4cc9ea4f12300f0603551d130101ff040530030101ff300e0603'
    '551d0f0101ff040403020204300d06092a864886f70d01010b05000382020100'
    '4e31a05cf28ba65dbdafa1ced70969ee5ca84104added8a306cf7f6dee50375'
    'd745ed992cb0242cce72dc9eed51191fe5ad52bad7dd3b25c099e13a491a3cdd'
    '487a5acce8766324c4ae46338246ae7b78a418acbb98a05c4c9d696eeaab609d'
    '0ba0ce1a31be98490df3f4c0ea9ddc9e82ffb0fcb3e9ebdd8cb952789f2b1411'
    'fac56c886426eb7296042735da50e11ac715f1818cf9fdc4e254a3763351b6a'
    '2440150861263a6e310be1a50de5c7e8ee880fdd4be5884a37128d18830bb347'
    '6bf4291e82d5c66a6494939e08480bfbc00f7d8a74d43e73737ebe5d8e4ec515'
    '302d4689692780dc7538ed7e9175be6139e74d43ad388b3050ffd5a9de526200'
    '0898c01f63c53dfe22209108fa4f65ba16c49ccbde0837d7c5844d54b7398ba0'
    '122e505b155c9313cfe26e72d87e22aa1616e6bdbf547ddff93df29e35a63b45'
    '5fe1fc0ec95581f3f4f7bbe3bb828396a37ae3157582bc3764b9780a239efc0f'
    '75a1e2e6d941ceabac27ddeb01e2bd8421029bea34d51aee6c60271d5a95ebd0'
    '0515a9c0013dd80bf87eea260b81c34f688e6eb1348af0d8ea1cac32acb9d93f'
    'a24aff030a84c8f2b0f569cc95080b20ac35ace0c6d8dbd4f6847719519d3245'
    '0166eb4bf15b859044501adeaf436382c34b15e3b54c92e61b69c2bfc7264589'
    '172b3c93dbe35ce06d08fd5c01322ca0877b1d12743af1fad5940ea1bc02dd891c';

const _googleRsa2021RootDerHex =
    '3082051c30820304a003020102020900c36b7c44b9ae1831300d06092a864886'
    'f70d01010b0500301b3119301706035504051310663932303039653835336236'
    '62303435301e170d3231313131373233313034325a170d333631313133323331'
    '3034325a301b3119301706035504051310663932303039653835336236623034'
    '3530820222300d06092a864886f70d01010105000382020f003082020a028202'
    '0100afb6c7822bb1a701ec2bb42e8bcc541663abef982f32c77f7531030c9752'
    '4b1b5fe809fbc72aa9451f743cbd9a6f1335744aa55e77f6b6ac3535ee17c25e'
    '639517dd9c92e6374a53cbfe258f8ffbb6fd129378a22a4ca99c452d47a59f32'
    '01f44197ca1ccd7e762fb2f53151b6feb2fffd2b6fe4fe5bc6bd9ec34bfe0823'
    '9daafceb8eb5a8ed2b3acd9c5e3a7790e1b51442793159859811ad9eb2a96bbd'
    'd7a57c93a91c41fccd27d67fd6f671aa0b815261ad384fa37944864604ddb3d8'
    'c4f920a19b1656c2f14ad6d03c56ec060899041c1ed1a5fe6d3440b556bad1d0'
    'a152589c53e55d370762f0122eef91861b1b0e6c4c80927499c0e9bec0b83e3b'
    'c1f93c72c049604bbd2f1345e62c3f8e26dbec06c94766f3c128239d4f4312fa'
    'd8123887e06becf567583bf8355a81feeabaf99a83c8df3e2a322afc672bf120'
    'b135158b6821ceaf309b6eee77f98833b018daa10e451f06a374d50781f35908'
    '2966bb778b9308942698e74e0bcd24628a01c2cc03e51f0b3e5b4ac1e4df9eaf'
    '9ff6a492a77c1483882885015b422ce67b80b88c9b48e13b607ab545c723ff8c'
    '44f8f2d368b9f6520d31145ebf9e862ad71df6a3bfd2450959d653740d97a12f'
    '368b13ef66d5d0a54a6e2f5d9a6fef446832bc67844725861f093dd0e6f3405d'
    'a89643ef0f4d69b6420051fdb93049673e36950580d3cdf4fbd08bc584839526'
    '00630203010001a3633061301d0603551d0e041604143661e1007c880509518b'
    '446c47ff1a4cc9ea4f12301f0603551d230418301680143661e1007c88050951'
    '8b446c47ff1a4cc9ea4f12300f0603551d130101ff040530030101ff300e0603'
    '551d0f0101ff040403020204300d06092a864886f70d01010b05000382020100'
    '5334d65ee5cb9ff288aafa35748ad4c6cd65614938ce044936150be1d75277a3'
    '79676b4a3baddf111479cdd34ab8862e936a9161878a9ac3f886e9783ec4e6a7'
    'eb79e22d6202e4638f1603de61733dfa705bdf36730bc001ca962e0aeb160a6b'
    '7a4e7dfe3e36f3dcc4d5851197b93fd3407e0a1856383e1bf30325f07634ce097'
    '203f9a1ee77844b712c92af416afcbf91f1359a96f335c0924f872463a910897'
    'ab1ad7c16a08802f3be19e663b535a85712d0d0a72a3a0eee815e74a756959cf4'
    '6007eedda18225de0a1d3d0cb0688b65ecfd58ff35c584ab28c344b032beccae5'
    'f573c3a8c0edcc66a577004539e602e194788ed5543843cca79539cb5fddad2a4'
    '0bc02f9dd3ec6b113678af67d118dc36604b365bc423ea80dc7cfbeaf49c927bb'
    'a49eb07079e5e44674970738c47ed8e03c7d440d4995fa282ccc37b4e749647d1'
    'e9f13d76b275f003dd889f799a45694ce270778bcd524bb7d76f181d1b1d02c4e'
    '3e12a28580e66fd84a0febce8342a6d54b5bbef64d29db16cc035d394c1224ee7'
    'a6b69af153347e7ad12a2ef09592b0747f9a340ca16d7456f71b2738327e83c78'
    '5e39db3bdb88a2a78042a2acae4b1a27a85c15fbb59f43d463411f639bddb28ec3'
    '02167441657bf605fe1eb35a075ea1a3460ea541acbaf6fb40ed5a8881d5a0c48c'
    'b5a5f459b2214c949bb983fef14393317ec26edcc96a50a4255';

void main() {
  group('verifyDeviceSignature (P-256 ES256)', () {
    test('genuine signature verifies', () {
      final (pkD, preimage, sig) = _signFixture();
      expect(pkD.length, 64);
      expect(sig.length, 64);
      expect(
          verifyDeviceSignature(
              pkDRaw64: pkD, preimage: preimage, sig64: sig),
          isTrue);
    });

    test('tampered sig / preimage / key fail closed (false, never throw)',
        () {
      final (pkD, preimage, sig) = _signFixture();
      final badSig = Uint8List.fromList(sig)..[0] ^= 0xFF;
      final badPre = Uint8List.fromList(preimage)..[0] ^= 0xFF;
      final (otherPkD, _, _) = _signFixture(99);
      expect(
          verifyDeviceSignature(
              pkDRaw64: pkD, preimage: preimage, sig64: badSig),
          isFalse);
      expect(
          verifyDeviceSignature(
              pkDRaw64: pkD, preimage: badPre, sig64: sig),
          isFalse);
      expect(
          verifyDeviceSignature(
              pkDRaw64: otherPkD, preimage: preimage, sig64: sig),
          isFalse);
    });

    test('malformed lengths fail closed', () {
      final (pkD, preimage, sig) = _signFixture();
      expect(
          verifyDeviceSignature(
              pkDRaw64: Uint8List(32),
              preimage: preimage,
              sig64: sig),
          isFalse);
      expect(
          verifyDeviceSignature(
              pkDRaw64: pkD, preimage: preimage, sig64: Uint8List(10)),
          isFalse);
    });
  });

  group('AES-GCM seal envelope (PXK2)', () {
    final dek = Uint8List.fromList(List.generate(32, (i) => (i * 7 + 1) & 0xFF));
    final seed = Uint8List.fromList(List.generate(32, (i) => i));

    test('roundtrip is 64B with fresh nonces', () {
      final a = sealWithDek(dek32: dek, seed32: seed);
      final b = sealWithDek(dek32: dek, seed32: seed);
      expect(a.length, kHwSealEnvelopeBytes);
      expect(a.sublist(0, 4), kHwSealMagic);
      // Fresh CSPRNG nonce per seal: same seed seals differently.
      expect(a, isNot(b));
      expect(unsealWithDek(dek32: dek, sealed: a), seed);
      expect(unsealWithDek(dek32: dek, sealed: b), seed);
    });

    test('tamper / wrong DEK / bad shape → restore detected', () {
      final sealed = sealWithDek(dek32: dek, seed32: seed);
      final badBody = Uint8List.fromList(sealed)..[20] ^= 0xFF;
      final badTag = Uint8List.fromList(sealed)..[60] ^= 0xFF;
      final badMagic = Uint8List.fromList(sealed)..[0] ^= 0xFF;
      final otherDek =
          Uint8List.fromList(List.generate(32, (i) => (i * 13 + 5) & 0xFF));
      for (final bad in [badBody, badTag, badMagic, Uint8List(10)]) {
        expect(
            () => unsealWithDek(dek32: dek, sealed: bad),
            throwsA(isStateError.having((e) => e.message, 'message',
                contains('restore detected — re-enroll'))));
      }
      // Clone: ciphertext under a different device DEK fails.
      expect(
          () => unsealWithDek(dek32: otherDek, sealed: sealed),
          throwsA(isStateError.having((e) => e.message, 'message',
              contains('restore detected — re-enroll'))));
    });
  });

  group('pinned Google roots', () {
    test('four 32B pins (RSA 2022 + RSA 2019 + RSA 2021 + EC)', () {
      final pins = defaultPinnedAttestationRoots();
      expect(pins, hasLength(4));
      for (final p in pins) {
        expect(p.length, 32);
      }
      expect(hexEncode(pins[0]), kGoogleHwAttestationRootRsaSha256Hex);
      expect(hexEncode(pins[1]), kGoogleHwAttestationRootRsa2019Sha256Hex);
      expect(hexEncode(pins[2]), kGoogleHwAttestationRootRsa2021Sha256Hex);
      expect(hexEncode(pins[3]), kGoogleHwAttestationRootEcSha256Hex);
    });

    test('2019 vintage fixture hashes to its pin (field root 1ef1a04b)', () {
      final root = hexDecode(_googleRsa2019RootDerHex);
      expect(root.length, 1312);
      expect(hexEncode(ProxCrypto.sha256Sync(root)),
          kGoogleHwAttestationRootRsa2019Sha256Hex);
      expect(hexEncode(ProxCrypto.sha256Sync(root)).substring(0, 8),
          '1ef1a04b');
    });

    test('2021 vintage fixture hashes to its pin', () {
      final root = hexDecode(_googleRsa2021RootDerHex);
      expect(root.length, 1312);
      expect(hexEncode(ProxCrypto.sha256Sync(root)),
          kGoogleHwAttestationRootRsa2021Sha256Hex);
    });

    test('2019 + 2021 vintages pin ok against the default pins', () {
      final challenge = deviceBindingChallengeV2(
          emailLower: 'a@x.in', installId: 'i1', pkS: randBytes(32));
      for (final fixture in [_googleRsa2019RootDerHex, _googleRsa2021RootDerHex]) {
        final root = hexDecode(fixture);
        final leaf = Uint8List.fromList(
            [...kKeyAttestationOidDer, ...challenge, ...List.filled(8, 0xAB)]);
        // Pin-pre-gate unit (synthetic leaf, not X.509): sig verification
        // is explicitly skipped via the test-only wrapper here; full-chain
        // sig coverage lives in test/chain_verify_test.dart.
        final r = verifyAttestationChainPinForTest(
          chain: AttestationChain([leaf, root]),
          pinnedRootHashes: defaultPinnedAttestationRoots(),
          expectedChallenge: challenge,
          level: AttestationLevel.full,
          verifySignatures: false,
        );
        expect(r.ok, isTrue, reason: r.reason);
      }
    });

    test('two 32B SPKI key pins (RSA f92009 key + EC CA1 key)', () {
      final pins = defaultPinnedAttestationSpki();
      expect(pins, hasLength(2));
      for (final p in pins) {
        expect(p.length, 32);
      }
      expect(hexEncode(pins[0]), kGoogleHwAttestationRsaSpkiSha256Hex);
      expect(hexEncode(pins[1]), kGoogleHwAttestationEcSpkiSha256Hex);
    });

    test('all RSA vintages share one SPKI == the RSA key pin', () {
      final want = kGoogleHwAttestationRsaSpkiSha256Hex;
      for (final fixture in [
        _googleRsaRootDerHex, // 2022
        _googleRsa2019RootDerHex, // 2019 (field root 1ef1a04b)
        _googleRsa2021RootDerHex, // 2021
      ]) {
        final spkiHash = spkiSha256OfCert(hexDecode(fixture));
        expect(spkiHash, isNotNull);
        expect(hexEncode(spkiHash!), want);
      }
      final ecSpki = spkiSha256OfCert(hexDecode(_googleEcRootDerHex));
      expect(ecSpki, isNotNull);
      expect(hexEncode(ecSpki!), kGoogleHwAttestationEcSpkiSha256Hex);
    });

    test('key pin alone trusts an unlisted same-key vintage', () {
      // A FUTURE same-key renewal has a cert hash nobody pinned yet: with
      // EMPTY cert pins the gate still passes via the key pin. Proves "all
      // true devices pass" does not depend on enumerating vintages.
      final challenge = deviceBindingChallengeV2(
          emailLower: 'a@x.in', installId: 'i1', pkS: randBytes(32));
      final root = hexDecode(_googleRsa2019RootDerHex);
      final leaf = Uint8List.fromList(
          [...kKeyAttestationOidDer, ...challenge, ...List.filled(8, 0xAB)]);
      final r = verifyAttestationChainPinForTest(
        chain: AttestationChain([leaf, root]),
        pinnedRootHashes: const [],
        expectedChallenge: challenge,
        level: AttestationLevel.full,
        verifySignatures: false,
      );
      expect(r.ok, isTrue, reason: r.reason);
    });

    test('unknown key still fails closed with empty cert pins', () {
      final challenge = Uint8List.fromList(List.filled(32, 7));
      final leaf = Uint8List.fromList(
          [...kKeyAttestationOidDer, ...challenge, 0xAA]);
      final root = Uint8List.fromList(List.filled(64, 0xBB));
      final r = verifyAttestationChainPinForTest(
        chain: AttestationChain([leaf, root]),
        pinnedRootHashes: const [],
        expectedChallenge: challenge,
        level: AttestationLevel.full,
        verifySignatures: false,
      );
      expect(r.ok, isFalse);
      expect(r.reason, 'unknown-root');
    });

    test('spkiSha256OfCert fails closed on malformed input', () {
      expect(spkiSha256OfCert(Uint8List.fromList([1, 2, 3])), isNull);
      expect(spkiSha256OfCert(Uint8List(0)), isNull);
    });

    test('unknown root still fails closed against the real pins', () {
      final challenge = Uint8List.fromList(List.filled(32, 1));
      final leaf = Uint8List.fromList(
          [...kKeyAttestationOidDer, ...challenge, 0xAA]);
      final root = Uint8List.fromList(List.filled(64, 0xBB));
      // Pin-pre-gate unit (synthetic leaf, not X.509): sigs explicitly
      // skipped via the test-only wrapper (M4 validate-then-trust runs
      // sigs before the pin, so a synthetic leaf would otherwise fail as
      // bad-chain-der instead of exercising the pin gate).
      final r = verifyAttestationChainPinForTest(
        chain: AttestationChain([leaf, root]),
        pinnedRootHashes: defaultPinnedAttestationRoots(),
        expectedChallenge: challenge,
        level: AttestationLevel.full,
        verifySignatures: false,
      );
      expect(r.ok, isFalse);
      expect(r.reason, 'unknown-root');
    });

    test('real RSA root pins ok against the default pins', () {
      final root = hexDecode(_googleRsaRootDerHex);
      expect(root.length, 1312);
      expect(hexEncode(ProxCrypto.sha256Sync(root)),
          kGoogleHwAttestationRootRsaSha256Hex);
      final challenge = deviceBindingChallengeV2(
          emailLower: 'a@x.in', installId: 'i1', pkS: randBytes(32));
      final leaf = Uint8List.fromList(
          [...kKeyAttestationOidDer, ...challenge, ...List.filled(8, 0xAB)]);
      // Pin-pre-gate unit (synthetic leaf, not X.509): sig verification is
      // explicitly skipped via the test-only wrapper here; full-chain sig
      // coverage lives in test/chain_verify_test.dart (genuine + forged
      // fixtures).
      final r = verifyAttestationChainPinForTest(
        chain: AttestationChain([leaf, root]),
        pinnedRootHashes: defaultPinnedAttestationRoots(),
        expectedChallenge: challenge,
        level: AttestationLevel.full,
        verifySignatures: false,
      );
      expect(r.ok, isTrue, reason: r.reason);
    });

    test('real EC root pins ok against the default pins', () {
      final root = hexDecode(_googleEcRootDerHex);
      expect(root.length, 550);
      expect(hexEncode(ProxCrypto.sha256Sync(root)),
          kGoogleHwAttestationRootEcSha256Hex);
      final challenge = deviceBindingChallengeV2(
          emailLower: 'a@x.in', installId: 'i1', pkS: randBytes(32));
      final leaf = Uint8List.fromList(
          [...kKeyAttestationOidDer, ...challenge, ...List.filled(8, 0xCD)]);
      // Pin-pre-gate unit (synthetic leaf): see above.
      final r = verifyAttestationChainPinForTest(
        chain: AttestationChain([leaf, root]),
        pinnedRootHashes: defaultPinnedAttestationRoots(),
        expectedChallenge: challenge,
        level: AttestationLevel.standard,
        verifySignatures: false,
      );
      expect(r.ok, isTrue, reason: r.reason);
    });
  });

  group('M4: canonical challenge + leaf-pkD bind', () {
    test('challenge is domain-separated + unambiguous', () {
      final pkS = randBytes(32);
      // Concat ambiguity is closed by length-prefixing: swapped splits differ.
      final v2a = deviceBindingChallengeV2(
          emailLower: 'ab', installId: 'c', pkS: pkS);
      final v2b = deviceBindingChallengeV2(
          emailLower: 'a', installId: 'bc', pkS: pkS);
      expect(v2a, isNot(v2b));
      expect(
          deviceBindingChallengeV2(
              emailLower: 'A@x.in', installId: 'i1', pkS: pkS),
          deviceBindingChallengeV2(
              emailLower: 'a@x.in', installId: 'i1', pkS: pkS));
    });

    test('wrong challenge fails closed (no alternates)', () {
      final pkS = randBytes(32);
      final expected = deviceBindingChallengeV2(
          emailLower: 'a@x.in', installId: 'i1', pkS: pkS);
      final other = deviceBindingChallengeV2(
          emailLower: 'b@x.in', installId: 'i1', pkS: pkS);
      final root = hexDecode(_googleRsaRootDerHex);
      final leaf = Uint8List.fromList(
          [...kKeyAttestationOidDer, ...other, ...List.filled(8, 0xAB)]);
      final bad = verifyAttestationChainPinForTest(
        chain: AttestationChain([leaf, root]),
        pinnedRootHashes: defaultPinnedAttestationRoots(),
        expectedChallenge: expected,
        level: AttestationLevel.full,
        verifySignatures: false,
      );
      expect(bad.ok, isFalse);
      expect(bad.reason, 'challenge-mismatch');
    });

    test('leaf SPKI extracts + binds pkD (structure-only)', () {
      final leaf = hexDecode(_genuineLeafDerHex);
      final raw = extractLeafEcPublicKeyRaw(leaf);
      expect(raw, isNotNull);
      expect(raw!.length, 64);
      expect(leafPkDEquals(leaf, raw), isTrue);
      final flipped = Uint8List.fromList(raw)..[0] ^= 0xFF;
      expect(leafPkDEquals(leaf, flipped), isFalse);
      expect(leafPkDEquals(leaf, Uint8List(32)), isFalse);
      expect(extractLeafEcPublicKeyRaw(Uint8List.fromList([1, 2, 3])),
          isNull);
    });
  });

  group('genuine Google leaf (OID + challenge ground truth)', () {
    // Regression for the audit find: the OID needle was `06 09` while
    // genuine certs carry `06 0A`, so EVERY real chain failed
    // `missing-attestation-oid`. This leaf is byte-exact Google testdata
    // (see fixtures above) — it must pass both helpers.
    test('genuine leaf carries the attestation OID', () {
      final leaf = hexDecode(_genuineLeafDerHex);
      expect(leaf.length, 643);
      expect(attestationLeafHasKeyOid(leaf), isTrue);
    });

    test('genuine leaf embeds its real challenge ("challenge")', () {
      final leaf = hexDecode(_genuineLeafDerHex);
      final challenge = Uint8List.fromList('challenge'.codeUnits);
      expect(attestationLeafContainsChallenge(leaf, challenge), isTrue);
      expect(
          attestationLeafContainsChallenge(
              leaf, Uint8List.fromList('challengf'.codeUnits)),
          isFalse);
    });
  });

  group('dSig P-256 contract over deviceProvePreimage', () {
    // Audit item (b): the exact bytes ProxCrypto.deviceProvePreimage emits
    // — extended 5-field ticket + pkS + integrity hash — must verify under
    // P-256 ES256, and every bound field must be load-bearing (no
    // transplant across tickets/keys/integrity verdicts).
    (ECPrivateKey, Uint8List) p256Key([int salt = 7]) {
      final domain = ECDomainParameters('prime256v1');
      final gen = ECKeyGenerator()
        ..init(ParametersWithRandom(
            ECKeyGeneratorParameters(domain), _testRandom(salt)));
      final pair = gen.generateKeyPair();
      final ECPublicKey pub = pair.publicKey;
      final ECPrivateKey priv = pair.privateKey;
      return (
        priv,
        Uint8List.fromList(pub.Q!.getEncoded(false).sublist(1))
      );
    }

    Uint8List p256Sign(
        ECPrivateKey priv, Uint8List preimage, SecureRandom rng) {
      final signer = ECDSASigner(SHA256Digest())
        ..init(true, ParametersWithRandom(PrivateKeyParameter(priv), rng));
      final s = signer.generateSignature(preimage) as ECSignature;
      Uint8List be(BigInt v) =>
          hexDecode(v.toRadixString(16).padLeft(64, '0'));
      return Uint8List.fromList([...be(s.r), ...be(s.s)]);
    }

    test('real preimage verifies; ticket/pkS/integrity tamper fails', () {
      final (priv, pkD) = p256Key();
      final sess = randBytes(16), wid = randBytes(6), cj = randBytes(8);
      final pkS = randBytes(32);
      const ver = 'face_verification/0.3.9+b45ab893';
      const livVer = 'liveness/minifasnet-v2+a1b2c3d4';
      const faceMs = 1725628800000;
      final ticket = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: faceMs,
        verifierVer: ver,
        livenessScore: 0.92,
        livenessVer: livVer,
      );
      final pre = ProxCrypto.deviceProvePreimage(
        sessionId: sess,
        windowId: wid,
        j: 1,
        challenge: cj,
        faceTicketHashBytes: ticket,
        pkS: pkS,
        integrityHash: '00000000',
      );
      final sig = p256Sign(priv, pre, _testRandom(21));
      expect(
          verifyDeviceSignature(
              pkDRaw64: pkD, preimage: pre, sig64: sig),
          isTrue);
      final weakTicket = ProxCrypto.faceTicketHash(
        faceScore: 0.85,
        faceValidAtMs: faceMs,
        verifierVer: ver,
        livenessScore: 0.31,
        livenessVer: livVer,
      );
      Uint8List preWith({Uint8List? t, Uint8List? s, String? h}) =>
          ProxCrypto.deviceProvePreimage(
            sessionId: sess,
            windowId: wid,
            j: 1,
            challenge: cj,
            faceTicketHashBytes: t ?? ticket,
            pkS: s ?? pkS,
            integrityHash: h ?? '00000000',
          );
      for (final bad in [
        preWith(t: weakTicket), // liveness downgrade transplant
        preWith(s: randBytes(32)), // key transplant
        preWith(h: 'deadbeef'), // tainted-verdict transplant
        preWith(h: ''), // pre-binding preimage
      ]) {
        expect(
            verifyDeviceSignature(
                pkDRaw64: pkD, preimage: bad, sig64: sig),
            isFalse);
      }
    });
  });
}
