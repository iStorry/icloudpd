# iCloud Photos Downloader for Mac

A native SwiftUI app that downloads your iCloud Photos library to a folder on your Mac. It's a Swift
reimplementation of the open-source [icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader)
(MIT): it doesn't need Python and doesn't bundle icloudpd.

## What works in this first version

- **Apple ID sign-in** using the same SRP-6a handshake icloudpd and icloud.com use. The password is only sent
  to Apple as an SRP proof. If you choose, it's kept in your login Keychain.
- **Two-factor codes**: a code pushed to your trusted devices, or a text message to a trusted number.
- **Remembered sessions**: after one 2FA, later launches sign in without a code until Apple expires the
  trust. Session tokens live in `~/Library/Application Support/ICloudPhotos/Sessions/` with `0600` permissions.
- **Download All Photos** from your primary library: originals and Live Photo videos, with an option to skip videos.
  - Folders: `2024/07/31/IMG_0001.HEIC` by default, or Year/Month, Year, or a single folder.
  - Files already on disk are skipped. A different file with the same name gets a `-<size>` suffix, like icloudpd does.
  - Each file is downloaded to a temporary file, size-checked, then moved into place, and its modification date
    is set to when the photo was taken.
- Live progress, a running log, and a Stop button.

## Not yet (planned, one at a time)

Albums and shared libraries, sizes other than original, RAW handling, sync mode (deleting local files removed from
iCloud), "recent only" and "until found" incremental runs, EXIF date fixes, XMP sidecars, scheduled runs or a
menu bar mode, security-key and legacy two-step accounts, and Advanced Data Protection.

## Requirements

- macOS 14 Sonoma or later, with Xcode 15+ (or the Command Line Tools).
- On your iPhone or iPad: **Settings > [your name] > iCloud > Access iCloud Data on the Web** turned on, and
  **Advanced Data Protection** turned off.

## Build and run

```sh
# Run straight from the package
swift run ICloudPhotos

# Or build a double-clickable app into ./build
./scripts/build-app.sh
open "build/iCloud Photos Downloader.app"
```

You can also open `Package.swift` in Xcode and run the **ICloudPhotos** scheme.

## Tests

```sh
swift test
```

The SRP tests check the Swift handshake byte for byte against vectors made with python `srp`, configured
exactly as icloudpd configures it. The core library (`ICloudKit`) and its tests also build on Linux.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/ICloudKit/Crypto` | BigUInt, SHA-256/PBKDF2 wrappers, SRP-6a client |
| `Sources/ICloudKit/Networking` | HTTP session with its own cookie jar and saved session tokens |
| `Sources/ICloudKit/Auth` | Apple ID sign-in, 2FA, session trust (port of `pyicloud_ipd/base.py`) |
| `Sources/ICloudKit/Photos` | Photos CloudKit queries and asset parsing (port of `services/photos.py`) |
| `Sources/ICloudKit/Download` | File naming, folder layout and the download loop |
| `Sources/ICloudPhotosApp` | The SwiftUI Mac app |

## Note

This app uses the same undocumented iCloud web endpoints as icloudpd, so it can break when Apple changes
them. Check icloudpd's changelog when something stops working.
