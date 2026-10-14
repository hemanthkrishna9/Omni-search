//! The Windows side: decode the picture, shrink it if the engine can't take its size, recognize.

use std::io::Write;
use std::path::Path;

use windows::core::HSTRING;
use windows::Globalization::Language;
use windows::Graphics::Imaging::{
    BitmapAlphaMode, BitmapDecoder, BitmapInterpolationMode, BitmapPixelFormat, BitmapTransform, ColorManagementMode,
    ExifOrientationMode, SoftwareBitmap,
};
use windows::Media::Ocr::OcrEngine;
use windows::Storage::Streams::{Buffer, DataReader, DataWriter};
use windows::Storage::{FileAccessMode, StorageFile};
use windows::Win32::System::WinRT::{RoInitialize, RO_INIT_MULTITHREADED};

/// Exit code for a picture that can't be read.
const FAILED: i32 = 1;
/// Exit code for a PC with no OCR language.
const NO_LANGUAGE: i32 = 2;

pub fn run() -> i32 {
    let Some(arg) = std::env::args_os().nth(1) else {
        eprintln!("usage: digup-ocr <image-path> | digup-ocr --check");
        return FAILED;
    };
    let check = arg == "--check";
    // The multithreaded apartment: blocking on an async operation from a single-threaded one can deadlock. Already
    // initialized is fine too.
    let _ = unsafe { RoInitialize(RO_INIT_MULTITHREADED) };

    let Some(engine) = engine() else {
        eprintln!(
            "no OCR language is installed (Settings \u{2192} Time & language \u{2192} Language & region \u{2192} add a language with Optical character recognition)"
        );
        return NO_LANGUAGE;
    };
    if check {
        return 0;
    }
    match recognize(&engine, Path::new(&arg)) {
        Ok(text) => {
            let mut out = std::io::stdout().lock();
            if out.write_all(text.as_bytes()).and_then(|_| out.flush()).is_err() {
                return FAILED;
            }
            0
        }
        Err(message) => {
            eprintln!("{message}");
            FAILED
        }
    }
}

/// The engine for the languages the person has installed, else English, else the first language the OCR offers.
fn engine() -> Option<OcrEngine> {
    if let Ok(engine) = OcrEngine::TryCreateFromUserProfileLanguages() {
        return Some(engine);
    }
    if let Ok(engine) = Language::CreateLanguage(&HSTRING::from("en-US"))
        .and_then(|english| OcrEngine::TryCreateFromLanguage(&english))
    {
        return Some(engine);
    }
    let first = OcrEngine::AvailableRecognizerLanguages().ok()?.into_iter().next()?;
    OcrEngine::TryCreateFromLanguage(&first).ok()
}

fn recognize(engine: &OcrEngine, path: &Path) -> Result<String, String> {
    let full = std::path::absolute(path).map_err(|error| format!("can't open {}: {error}", path.display()))?;
    let bitmap = decode(&full).map_err(|error| format!("can't read the image: {error}"))?;
    let result = engine
        .RecognizeAsync(&bitmap)
        .and_then(|operation| operation.join())
        .map_err(|error| format!("OCR failed: {error}"))?;
    let lines = result.Lines().map_err(|error| format!("OCR failed: {error}"))?;
    let mut text = Vec::new();
    for line in lines {
        let line = line.Text().map_err(|error| format!("OCR failed: {error}"))?;
        text.push(line.to_string_lossy());
    }
    Ok(text.join("\n"))
}

fn decode(path: &Path) -> windows::core::Result<SoftwareBitmap> {
    let file = StorageFile::GetFileFromPathAsync(&HSTRING::from(path.as_os_str()))?.join()?;
    let stream = file.OpenAsync(FileAccessMode::Read)?.join()?;
    let decoder = BitmapDecoder::CreateAsync(&stream)?.join()?;

    let (width, height) = (decoder.PixelWidth()?, decoder.PixelHeight()?);
    let limit = OcrEngine::MaxImageDimension()?;
    // Bgra8 with premultiplied alpha either way, the same pixels whether or not it was shrunk.
    let transform = BitmapTransform::new()?;
    let longest = width.max(height);
    if longest > limit {
        let scale = limit as f64 / longest as f64;
        transform.SetScaledWidth(((width as f64 * scale) as u32).max(1))?;
        transform.SetScaledHeight(((height as f64 * scale) as u32).max(1))?;
        transform.SetInterpolationMode(BitmapInterpolationMode::Fant)?;
    }
    let bitmap = decoder
        .GetSoftwareBitmapTransformedAsync(
            BitmapPixelFormat::Bgra8,
            BitmapAlphaMode::Premultiplied,
            &transform,
            ExifOrientationMode::RespectExifOrientation,
            ColorManagementMode::DoNotColorManage,
        )?
        .join()?;
    on_white(&bitmap)
}

/// Flattens transparency onto white. Premultiplied pixels are colour * alpha, so a transparent area is black and dark
/// text on a transparent PNG would vanish into it. BitmapAlphaMode::Ignore isn't the fix: it would show whatever colour
/// the file stores under zero alpha (usually black), and the docs don't promise OcrEngine takes it. So: premultiplied
/// Bgra8 (which it takes), then colour + (255 - alpha) per channel, which is the colour over white.
fn on_white(bitmap: &SoftwareBitmap) -> windows::core::Result<SoftwareBitmap> {
    let size = (bitmap.PixelWidth()? as u32) * (bitmap.PixelHeight()? as u32) * 4;
    let buffer = Buffer::Create(size)?;
    bitmap.CopyToBuffer(&buffer)?;
    let mut pixels = vec![0u8; size as usize];
    DataReader::FromBuffer(&buffer)?.ReadBytes(&mut pixels)?;
    for pixel in pixels.chunks_exact_mut(4) {
        let behind = 255 - pixel[3];
        for channel in &mut pixel[..3] {
            *channel = channel.saturating_add(behind);
        }
        pixel[3] = 255;
    }
    let writer = DataWriter::new()?;
    writer.WriteBytes(&pixels)?;
    let flat = SoftwareBitmap::CreateWithAlpha(
        BitmapPixelFormat::Bgra8,
        bitmap.PixelWidth()?,
        bitmap.PixelHeight()?,
        BitmapAlphaMode::Ignore,
    )?;
    flat.CopyFromBuffer(&writer.DetachBuffer()?)?;
    Ok(flat)
}
