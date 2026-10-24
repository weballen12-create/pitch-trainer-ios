# Pitch trainer iPhone test

A small iPhone test of the cheek pitch trainer's idea in software: mic, pitch detection, snap to a key, sine tone to wired
headphones. It uses a COPY of the singing-tool library code (decimator, MPM pitch detector, target-note tracker, sine
generator) in `PitchTest/Native/`, so it does not touch the board project.

It starts muted and quiet (-50 dBFS, capped at -36 dBFS). Wired headphones only; keep them out of your ears until set.

## Build (GitHub Actions, free macOS runner)
Push to `main` or run the workflow by hand. The artifact `PitchTest-unsigned-ipa` is an unsigned `.ipa`.

## Install on the iPhone from Windows (free Apple ID, lasts 7 days)
1. Install iTunes and iCloud for Windows from Apple's website (not the Microsoft Store versions) and Sideloadly.
2. iPhone: Settings > Privacy & Security > Developer Mode > on (the phone restarts).
3. Plug the phone in with the USB cable, tap Trust.
4. In Sideloadly choose the `.ipa`, enter your Apple ID yourself, press Start.
5. On the phone: Settings > General > VPN & Device Management > trust your Apple ID.
6. Open the app, allow the microphone, press Start.
