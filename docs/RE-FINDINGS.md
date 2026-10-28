# Reverse engineering Escargot WLM 8.1.0178

Target: `escargot-wlm-8.1.0178-en.msi` + `RUN_AFTER_INSTALL.exe`.
Tooling: [rea](https://github.com/morluto/rea) 6.8.0 (`decompile-all`, `inspect-pe-imports`) with
Ghidra 12.1.4 + JDK 21 and a locally built arm64 native decompiler; 7-Zip for unpacking.
Reproduce with `re/scripts/extract.sh` and `re/scripts/decompile.sh` (see `re/scripts/rea-env.sh.example`).

Coverage (rea manifests in `re/evidence/`):

| target | sha256 (prefix) | functions decompiled | failed |
|---|---|---|---|
| msnmsgr.exe | `0908b3eb…` | 45 099 (+1 555 external) | 0 |
| escargot.dll | `a7d7a510…` | 5 708 (+107 external) | 0 |
| RUN_AFTER_INSTALL.exe | — | 33 (+57 external, VB6) | 0 |

Function names below are Ghidra's (`FUN_<va>`); addresses are virtual (image base 0x400000 for
msnmsgr.exe, 0x10000000 for escargot.dll) unless marked as file offsets.

## 1. What Escargot changed

The MSI holds one cabinet, `MsgrCore.cab`. Everything in it is stock Microsoft (2006–2007 timestamps)
except three files dated 2020-10-21:

- **`msnmsgr.exe`** — stock WLM 8.1.0178 with an *appended import descriptor*: the import directory was
  relocated to RVA 0x56A000 (end of file) and gained `escargot.dll!ImportMe`
  (`rea inspect-pe-imports`). Loading the EXE therefore force-loads the hook DLL. No other code changes
  were needed.
- **`escargot.dll`** — Escargot's "Switcher" (PDB `C:\home\escargot\switcher\Debug\escargot.dll.pdb`), a
  Microsoft Detours-style inline hooker (`SuspendThread`/`GetThreadContext`/`FlushInstructionCache`).
- **`escargot.ini`** — `[options] type=msn`.

`RUN_AFTER_INSTALL.exe` is the VB6 "NINA & Escargot Patcher v1.3". It searches for installs
(`\Windows Live\Messenger`, Messenger Plus!, Yahoo!) and writes `msnmsgr.exe-escargot.ini` with
`server = msnmsgr.escargot.chat` (and a `configserver`), plus Messenger Plus! sound-server registry
values (hex-encoded `mpsounds.log1p.xyz`).

## 2. escargot.dll (Switcher) internals

`FUN_1005c7b0` (init): loads `<exe>-escargot.ini`, optionally logs to `<exe>-escargot.log`, then
detours:

| hook | trampoline slot | replacement | effect |
|---|---|---|---|
| `gethostbyname` (WS2_32 #52) | `DAT_10129ea0` | `FUN_1005ef50` | hostname rewrite |
| `getaddrinfo` | `DAT_10129e9c` | `FUN_1005ee60` | hostname rewrite |
| `InternetConnectA` | `DAT_10129ecc` | `FUN_1005e410` | hostname rewrite |
| `InternetConnectW` | `DAT_10129ea4` | `FUN_1005e510` | hostname rewrite (W→A→W) |
| `HttpQueryInfoA` (msn, optional) | `DAT_10129eac` | `FUN_1005e310` | rewrites `\nPassporturls:` → `\nPassportURLs:` (the TWN/nexus code matches the header case-sensitively; the server's stack lowercases it) |
| `RegQueryValueExA` | `DAT_10129ea8` | `FUN_1005e990` | answers the `Server` value with the INI server |
| `ShellExecuteExA`, `InternetSetCookieA` | — | — | Yahoo! mode only |

`FUN_1005d300` is the rewrite table. In `msn` mode these hosts become the INI `server`:

```
messenger.hotmail.com  muser.messenger.hotmail.com  gateway.messenger.hotmail.com
muser.gateway.messenger.hotmail.com  nexus.passport.com  login.live.com  msnia.login.live.com
loginnet.passport.com  g.msn.com  svcs.microsoft.com  rsi.hotmail.com  ows.messenger.msn.com
byrdr.omega.contacts.msn.com  omega.contacts.msn.com  tkrdr.storage.msn.com  sup.live.com
config.messenger.msn.com / muser.config.messenger.msn.com  → configserver (if set)
```

**Ports, paths and TLS are untouched.** WLM keeps talking to `:1863` and to Microsoft's original
HTTPS paths (`/RST.srf`, `/abservice/abservice.asmx`, …), only on Escargot's host. The live server
presents a valid certificate covering `msnmsgr.escargot.chat` and `m1.escargot.chat`. A native client
therefore needs no hooking at all: it targets the Escargot host with Microsoft's paths
(`MSNKit/Model/ServerConfig.swift`).

## 3. Protocol facts recovered from msnmsgr.exe

### Version negotiation and fallback
- Dialect strings `MSNP15`, `MSNP14`, `MSNP13`; `VER 1 MSNP14 MSNP13 CVR0` is a literal for the
  fallback path.
- `FUN_004a907c`: "MSNP15+(RPS Auth) is not available, will retry login with MSNP14-(TWN Auth)";
  the choice is persisted as the registry value `UseTWNAuth`. The port implements MSNP15/SSO only, which
  Escargot supports.
- `FUN_004a91a0`: CVR format `"%lu %s %s %lu.%lu %s %s%s%s %s %s %s"` →
  `CVR trid 0x0409 winnt 5.1 i386 MSNMSGR 8.1.0178 msmsgs <email>`.

### SSO (RPS) login
- Service-target table in .rdata (file offsets 0x16ed60–0x16efd4): `messengerclear.live.com` with policy
  `MBI_KEY_OLD`, `messenger.msn.com` with `?id=507`, `contacts.msn.com`, `storage.msn.com`,
  `spaces.live.com` (`MBI`), `messengersecure.live.com` (`MBI_SSL`). msnmsgr.exe hands these to
  msidcrl40.dll, which builds the WS-Trust `RequestMultipleSecurityTokens` envelope from fragments
  (`<wst:RequestSecurityToken Id="`, `</wsse:PolicyReference></wst:RequestSecurityToken>`, …).
- `ps:HostingApp` GUID `{7108E71A-9926-4FCB-BCC9-9A9D3F32E423}` is stored as a binary GUID at file
  offset 0x141968.
- NS flow: `USR trid SSO I email` → `GCF 0 <shields>` + `USR trid SSO S MBI_KEY_OLD <nonce>` →
  `USR trid SSO S <t=…&p=> <MBI blob>` → `USR trid OK email 1 0`.
- MBI blob = header `{28, 1, 0x6603 (3DES), 0x8004 (SHA1), 8, 20, 72}` + IV + HMAC-SHA1(key2, nonce) +
  3DES-CBC(key3, IV, nonce). The keys are derived from the BinarySecret with the WS-SecureConversation
  "SESSION KEY HASH/ENCRYPTION" P_SHA1 construction. Byte-for-byte equal to the Escargot verifier's own
  computation (`ProtocolTests.testSSOResponseMatchesServer`).

### Challenge (CHL/QRY)
- `FUN_0049fb3f` sends `QRY` with `"%u %s %d\r\n%s"`.
- `FUN_004a0018` builds `sprintf("%s%s", challenge, productID)`, pads with `'0'` **only if** the length
  is not a multiple of 8, MD5s challenge+key (`FUN_0049fed7`, CryptoAPI `CALG_MD5` 0x8003), and runs
  `FUN_0049fcb8`, the 31-bit modular hash with multiplier 0x0E79A9C1 (file offsets 0x9f101/0x9f188).
  The result is XORed into the **unmasked** MD5 words (`FUN_0049faea` is only a hex decoder).
- The product ID and key are XOR-0xB7 obfuscated (`FUN_0049f937`/`FUN_0049fe4b`), reached through
  pointers at 0x9229d4 and 0x9229d8:

  | VA | bytes | decoded |
  |---|---|---|
  | 0x4de32c | `e7e5f8f387868683f2e483ed92e682e0b7` | `PROD0114ES4Z%Q5W` |
  | 0x4de340 | `e7fccae8f6e887f9e8fc92f888f68ee4b7` | `PK}_A_0N_K%O?A9S` |

- `re/scripts/wlm_challenge.py` is a literal translation used as the test oracle. Escargot's
  `gen_chal_response` differs (it XORs the masked words and always pads), but its QRY check is
  commented out, so either form is accepted. The port follows the binary.

### Presence and capabilities
- `CMNSNet::SetLocalState` (`FUN_0052fe66`) maps internal states to `NLN BSY BRB AWY PHN LUN IDL HDN`
  and formats `CHG` as `"%lu %s %lu %s"` (trid, status, capabilities, URL-encoded MSN object), sent with
  tag `0x20474843` (`'CHG '`).
- `FUN_0052faa8` computes capabilities: base `0x7048C024` (`0x7049C024` in one environment branch)
  `| 0x06000000`, plus optional bits 0x2, 0x8, 0x10 (webcam), 0x40, 0x80, 0x1000, 0x40000, 0x100000,
  0x1000000. The high nibble 7 is the MSNC7 P2P version (WLM 8.1). The port advertises `0x70000020`
  (MSNC7 + multi-packet) because it has no P2P stack.

### Contacts (ABCH) — abssm.dll
SOAP request templates are format strings in abssm.dll .rdata (file offsets), e.g.

- `0x11520` `<ABFindAll …><abId>%s</abId><abView>Full</abView><deltasOnly>false</deltasOnly><dynamicItemView>Gleam</dynamicItemView></ABFindAll>`
- `0x12068` `<FindMembership …>` + `0x4cb5c` `<Types><ServiceType>Messenger</ServiceType>…`
- `0x3e908` `<ABContactAdd …>`, `0x3c548` `<ABContactDelete …>`, `0x3f1f8` `<AddMember …>`, `0x3e560` `<DeleteMember …>`
- headers `0xdf18` `<ABAuthHeader …><TicketToken>%s</TicketToken>` and `0xe058` `<ABApplicationHeader …>`
- endpoints `0x4dd8c` `/abservice/abservice.asmx` and `0x4ddbc` `/abservice/SharingService.asmx`

`ApplicationId` `996CDE1E-AA53-4477-B943-2BE802EA6166` is a UTF-16 string in msnmsgr.exe.

### Switchboard messages
MIME literals in msnmsgr.exe (file offsets): `0x12bf90` text/plain header block, `0xc346c`
`text/x-msmsgscontrol` (+ `TypingUser`), `0x17d144` `application/x-msnmsgrp2p`, and the
`text/x-msmsgs*notification` family for NS mail notifications.

## 4. Server-side behaviour that matters to clients

Determined against the Escargot server source, run locally in `devserver/`, and probed on the live service:

- ABCH calls are authorised by the compact ticket (`t=` + 20 chars) **only after** the NS session has
  completed `USR SSO S`. Order: RST → NS login → ABCH.
- An initial `ADL` (`<ml l="1">`) is acknowledged but ignored. The server syncs lists itself and sends
  `ILN`s after the first `CHG`.
- Presence (MSNP15): `ILN trid status email 1 name caps [msnobj]`, `NLN status email 1 name caps [msnobj]`,
  `FLN email 1 0`, `UBX email 1 <len>`.
- `XFR trid SB host:port CKI <cookie> U messenger.msn.com 1`;
  `RNG sessid host:port CKI <cookie> email name U messenger.msn.com 1`.
- Live service (2026-10-28): `msnmsgr.escargot.chat` → 143.198.4.104, NS 1863, HTTPS 443.
  The sign-in ID is `<username>@escargot.chat`, not the registration e-mail. A real account completed the
  whole flow against the live service: RST → `USR SSO S` (MBI accepted) → FindMembership/ABFindAll →
  `PRP`/`BLP`/`CHG`. The app showed the account's roaming name and its existing group.
- The roaming profile lives in the Storage service (`GetProfile`/`UpdateProfile`, abssm.dll 0x4d3c4/0x51f14).
  `UUX`/`PRP` only change the live session. The live server answers `GetProfile` with HTTP 404 for an
  account that has no Storage profile yet; WLM would then call `CreateProfile`. The port treats the 404 as
  "nothing roamed" and leaves the profile untouched.

## 5. The UI: DirectUI resources (msgsres.dll, msgslang.dll, msncore.dll)

WLM 8.1 draws every window with DirectUI (implemented in msncore.dll). The look is data, not code:

| type | content |
|---|---|
| 4004 | UIFILE layouts — element trees with layouts/paddings (947 sign-in, 923 main window, 1001/1009 contact list, 920 conversation, 921 toasts) |
| 4005 | stylesheets — CSS-like rules referencing resources by ID: `rcclr`, `rcbkd`, `rcimg`, `rcrect`, `rcint`, `rcstr` |
| 4000 | values: `R` RLE image, `C`/`D` colour (R,G,B,A), `V`/`H` two-stop gradient, `S` system colour, `J` alias, `N` none, `T` theme part, `F` frame control, or plain PNG/GIF/JPEG |
| 4002 / 4003 / 4006 | colours, rects (4×int32), alternate RLE images |
| RT_STRING (msgslang.dll) | `rcstr`/`rcint` — labels, font face ("MS Shell Dlg 2"), sizes (8pt) |

The resource-value parser is `FUN_5913b2f4` in msncore.dll (switch on the tag byte; `R` →
`DirectUI::Value::CreateRLE(data, 4006-alternate)`).

**RLE image codec** (ported from msncore.dll into `re/scripts/wlm_rle.py`):
- container `"RLE"`, byte 3 = frame count (+flag), byte 4 = length-field width and a nine-slice
  mode (bits for left/top/right/bottom pieces; `DAT_59124cf4` = pieces per frame);
- each piece: u32 header `w:12 palettized:1 8bit:1 b14:1 alpha:1 h:12 offsz-1:2`, a table of row
  offsets (each relative to its own slot), then LSB-first bit-packed rows;
- a row interleaves runs for three planes R,G,B (`FUN_59130375`, plane order from the 555 packer
  `FUN_591a3fc6`), each run = 2-bit type (fill / delta+ / delta− / literal), ⌈log₂w⌉-bit count, 5-bit
  (or, with bit 13, 8-bit — `FUN_591a4228`) samples;
- with alpha (`FUN_591b697c`/`FUN_5912aaf4`) an alpha segment precedes colour data: transparent spans
  carry no colour samples, opaque spans do, partial spans carry per-pixel alpha runs.
All 246 RLE images decode; `re/scripts/wlm_skin.py` resolves the stylesheets into `skin.json` +
PNGs (with nine-slice insets and every animation/state frame).

**Emoticons** (msnmsgr.exe `FUN_0046d3e1`; data in `re/data/emoticons.json`). The shortcut table at file
offset 0x530708 maps each code to an index. Indices below 95 are 19×19 cells of the 32-bit PNG 202
(type 4000). Only on displays of 8 bpp or less does the client use bitmap 124, an 8-bit, magenta-keyed copy
of the same strip. Cells 80–94 are unused placeholders. Indices 108–118 are animated: a table at VA
`0x9357b0` gives `{resource 257–267, playOnce, frames}`, the frame width is the strip width divided by the
frame count, and frames advance every 250 ms (`FUN_006dd2fc`). The timer callback (`FUN_006dd19a`) wraps
to frame 0 and, when playOnce is set (wink, "I don't know", eye-roll, sleepy), stops there. The others
loop. Tooltip names are msgslang.dll strings from a compacted table at VA `0x9323f0`. Its entries 92–102
name 108–118, and they share string IDs with the still cells 2, 10, 29, 42 and 71–77, which the ports
show where WLM doesn't animate (pickers, contact list).

**Reference.** WLM 8.1 runs under Wine 11 on macOS; its sign-in window was captured as the visual
reference. Signing in under Wine crashed (WLM's error reporter), and Wine does not mask WLM's
DirectUI password field — do not type real credentials into it.

## 6. WLM component → macOS and Linux ports

| WLM 8.1 (Windows) | Messenger (macOS) | MessengerGTK (Linux) |
|---|---|---|
| escargot.dll host rewrite | `ServerConfig` (direct targeting; no hooks) | same (shared MSNKit) |
| msidcrl40.dll RST + MBI | `PassportAuth`, `MBICrypto` (CommonCrypto 3DES) | same; pure-Swift `TripleDES`, swift-crypto HMAC |
| msnmsgr.exe NS/SB (MSNP15) | `MSNPConnection` over Network.framework, `MessengerClient`, `SwitchboardSession` | same over POSIX sockets (`SocketTransport`) |
| challenge code (FUN_004a0018) | `MSNPChallenge` | same |
| abssm.dll ABCH/Sharing/Storage | `ABService`, `StorageService` | same (FoundationNetworking) |
| DirectUI layouts/styles/images (msgsres.dll) | `Skin` + SwiftUI views keyed by the original resource IDs (§5) | `Skin` → GTK CSS (nine-slice `border-image`) + GTK 4 widgets |
| contact list, conversation windows, nudge shake | SwiftUI/AppKit in `Sources/Messenger` | GTK 4 in `Sources/MessengerGTK` (shake by margins: Wayland clients can't move windows) |
| toasts | skinned toast windows | GNotification with the Messenger icon |
| Credential Manager "remember password" | macOS Keychain | Secret Service (`secret-tool`) |
| .wma sound scheme | imported to AAC from your installer | imported to WAV, played with `pw-play`/`paplay`/`aplay` |

**Switchboard ordering.** When the client answers an invitation (`RNG` → `ANS`), the server can send the
inviter's first `MSG` in the same TCP read as the `IRO`/`ANS OK` lines. The app attaches its per-conversation
handler only after `ANS` succeeds, so `SwitchboardSession` buffers events emitted before a handler is set
and replays them when one is attached. Without that, the first message of a conversation the peer started
was lost (found while testing the GTK app).

**Linux verification (2026-10-28).** Unit tests and the 20-step e2e pass in the Ubuntu VM against the dev
server, and `msnctl --escargot check` completes the live RST (HTTPS via FoundationNetworking/libcurl) →
MBI → `USR SSO S` → ABCH sign-in from Linux.

Not ported (requires the MSNSLP/P2P stack or extra services): display pictures, custom emoticons,
winks, file transfer, ink, webcam/voice, offline messages (OIM via `rsi.asmx`/`oim.asmx`), Hotmail
inbox counts, MSN Spaces/Today, group editing, and multi-party invites from the UI (incoming multi-party
switchboards are handled).
