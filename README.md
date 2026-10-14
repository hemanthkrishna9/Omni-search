# Omni-search: DigUp for Windows

Search the files on your PC by what's in them (pictures, PDFs, documents, recordings, videos, code), with Google
DeepMind's EmbeddingGemma 2. **Everything runs on your computer.** The model runs through llama.cpp on your GPU (Vulkan)
or CPU, the index is one SQLite file on your disk, and nothing you index is uploaded.

This is [ARahim3/DigUp](https://github.com/ARahim3/DigUp) (MIT), imported at
[`f3decb0`](https://github.com/ARahim3/DigUp/commit/f3decb0a31225e63a263ee0443af05d682d201e1). Upstream already holds
a Windows port that isn't released yet: the Swift engine and CLI build on Windows, with a Tauri app (`shell/`) in place
of the Mac's SwiftUI app. This repo builds that port into an installer. Upstream's own README is in
[README.upstream.md](README.upstream.md).

## Get the installer

1. Open **Actions → Windows** in this repo (**Windows ARM64** for Snapdragon and other ARM PCs). They run on every
   push, or start one with **Run workflow**.
2. When the run is green, download the **DigUp-windows-x64** (or **DigUp-windows-arm64**) artifact and unzip it.
3. Run `DigUp_*-setup.exe`. It installs for your user only, with no admin prompt. The installer isn't code-signed, so
   SmartScreen may warn you first: pick *More info → Run anyway*.
4. On first launch DigUp downloads the model once (865 MB) from Hugging Face. After that it works offline. Pick the
   folders to search, then open the search panel with the shortcut and describe what you're looking for.

## What's local, and what goes online

- Local: reading your files, the embeddings, the index, search. The model is in your user folder.
- Online: the one-time model download, and nothing else. This build has no update check: new versions come from this
  repo's Actions runs.

## Windows, compared with the Mac app

- Text in screenshots (recognized by their file name, e.g. "Screenshot …") and in scanned PDF pages is read with Windows'
  built-in OCR, through `digup-ocr.exe` beside the helper; other pictures aren't OCR'd. It needs an OCR language
  installed: most display languages come with one. To add one, go to Settings → Time & language → Language & region →
  add a language with Optical character recognition. With several OCR languages in your language list (say English
  and Russian), each one reads the picture, so words in any of them are found.
- RAW camera photos (CR2, NEF, ARW, DNG, ORF, RW2, RAF) are read through the full-size JPEG preview the camera stores
  inside them. A RAW without one, like many phone DNGs, isn't read.
- OneDrive files that live only in the cloud are skipped, never downloaded.
- On x64, a GPU with Vulkan is used when it runs the model faster than the CPU; otherwise the CPU is used. The ARM64
  build runs the model on the CPU (ARMv8.2 or later: Snapdragon 8cx, 7c, X Elite and newer).

## Build it yourself on Windows

Follow `.github/workflows/windows.yml` (or `windows-arm64.yml`, with MSYS2's CLANGARM64 shell and no Vulkan SDK). You need Visual Studio's C++ tools, Swift 6.4, Rust, Node, Python, the Vulkan
SDK, Git for Windows and MSYS2. Then:

```sh
# in MSYS2's MINGW64 shell
scripts/build-ffmpeg.sh
# in Git Bash, inside a VS x64 developer environment
scripts/fetch-vendor.sh
scripts/build-llama.sh
scripts/package-windows.sh   # → shell/src-tauri/target/release/bundle/nsis/
```

## License

MIT, like upstream (see [LICENSE](LICENSE)). All credit for DigUp goes to its author.
