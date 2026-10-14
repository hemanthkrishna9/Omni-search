//! Reads the text in a picture with the OCR built into Windows (Windows.Media.Ocr), so DigUp can search what a screenshot
//! or a scan says without shipping an OCR engine of its own.
//!
//! - `digup-ocr <image-path>` prints the recognized text on stdout, one OCR line per line, and exits 0 (nothing printed
//!   when the picture has no text). Exit 1 is a failure (a picture that can't be read, bad usage), with the reason on
//!   stderr. Exit 2 is a PC with no OCR language installed.
//! - `digup-ocr --check` never reads a file: it exits 0 if an OCR engine can be created, 2 if not.

#[cfg(windows)]
mod ocr;

#[cfg(windows)]
fn main() {
    std::process::exit(ocr::run());
}

#[cfg(not(windows))]
fn main() {
    eprintln!("digup-ocr only runs on Windows");
    std::process::exit(1);
}
