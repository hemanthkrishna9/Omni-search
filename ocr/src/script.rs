//! Which writing system a language uses, and how much of a text is in it. Pure, so it is tested on any OS.
//!
//! With several OCR languages installed, each engine reads the same picture. The result whose letters best fit its own
//! language's script comes first, and the other engines' lines that it lacks follow: the words only feed exact-word
//! search, and a score can't always tell (an English engine reads Russian as Latin look-alikes, С as C and о as o), so
//! nothing an engine read is dropped. Windows OCR covers the Latin languages, Cyrillic, Greek, Arabic, Chinese, Japanese and
//! Korean, so those are the scripts here; any other tag counts as Latin.

#![cfg_attr(not(windows), allow(dead_code))]

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Script {
    Latin,
    Cyrillic,
    Greek,
    Arabic,
    /// Chinese (Han).
    Han,
    /// Han and kana.
    Japanese,
    Hangul,
}

/// The script a BCP-47 language tag is written in: an explicit script subtag (`sr-Latn`, `zh-Hant`) wins, else the
/// language's usual script (`sr` is Cyrillic, as it is for Windows).
pub fn script_of(tag: &str) -> Script {
    let lower = tag.to_ascii_lowercase();
    let mut parts = lower.split(['-', '_']);
    let language = parts.next().unwrap_or("");
    for part in parts {
        match part {
            "latn" => return Script::Latin,
            "cyrl" => return Script::Cyrillic,
            "grek" => return Script::Greek,
            "arab" => return Script::Arabic,
            "hans" | "hant" | "hani" => return Script::Han,
            "jpan" => return Script::Japanese,
            "kore" => return Script::Hangul,
            _ => {}
        }
    }
    match language {
        "ru" | "uk" | "bg" | "be" | "sr" | "mk" | "kk" | "ky" | "mn" | "tg" => Script::Cyrillic,
        "el" => Script::Greek,
        "ar" | "fa" | "ur" | "ps" => Script::Arabic,
        "zh" => Script::Han,
        "ja" => Script::Japanese,
        "ko" => Script::Hangul,
        _ => Script::Latin,
    }
}

/// How many of the text's letters belong to `script`. Digits, punctuation and spaces count for nothing.
pub fn score(text: &str, script: Script) -> usize {
    text.chars()
        .filter(|&c| c.is_alphabetic() && in_script(c, script))
        .count()
}

fn in_script(c: char, script: Script) -> bool {
    let n = c as u32;
    let han = matches!(n, 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0x20000..=0x2A6DF);
    match script {
        Script::Latin => {
            matches!(n, 0x41..=0x5A | 0x61..=0x7A | 0xAA | 0xBA | 0xC0..=0x24F | 0x1E00..=0x1EFF)
        }
        Script::Cyrillic => {
            matches!(n, 0x400..=0x52F | 0x1C80..=0x1C8F | 0x2DE0..=0x2DFF | 0xA640..=0xA69F)
        }
        Script::Greek => matches!(n, 0x370..=0x3FF | 0x1F00..=0x1FFF),
        Script::Arabic => {
            matches!(n, 0x600..=0x6FF | 0x750..=0x77F | 0x8A0..=0x8FF | 0xFB50..=0xFDFF | 0xFE70..=0xFEFF)
        }
        Script::Han => han,
        Script::Japanese => han || matches!(n, 0x3040..=0x30FF | 0x31F0..=0x31FF | 0xFF66..=0xFF9F),
        Script::Hangul => matches!(n, 0x1100..=0x11FF | 0x3130..=0x318F | 0xAC00..=0xD7AF),
    }
}

/// The index of the text that fits best. A non-Latin result at least half of whose letters are in its own script
/// beats any Latin one (an English engine's Latin look-alikes of Cyrillic can out-count the real reading); among
/// those the most own-script letters wins. Otherwise the most own-script letters; the earlier one on a tie (so the
/// person's first language wins when nothing reads well). `None` for no candidates.
pub fn best(candidates: &[(Script, String)]) -> Option<usize> {
    // (is a convincing non-Latin reading, own-script letters): compared in that order.
    let mut best: Option<(usize, (bool, usize))> = None;
    for (index, (script, text)) in candidates.iter().enumerate() {
        let own = score(text, *script);
        let letters = text.chars().filter(|c| c.is_alphabetic()).count();
        let convincing = *script != Script::Latin && own > 0 && own * 2 >= letters;
        let rank = (convincing, own);
        if best.is_none_or(|(_, top)| rank > top) {
            best = Some((index, rank));
        }
    }
    best.map(|(index, _)| index)
}

/// The best-fitting text (`best`), then every line of the others that it doesn't already have, in order.
pub fn merge(candidates: &[(Script, String)]) -> Option<String> {
    let first = best(candidates)?;
    let mut lines: Vec<&str> = Vec::new();
    let order = std::iter::once(first).chain((0..candidates.len()).filter(|&i| i != first));
    for index in order {
        for line in candidates[index].1.lines().map(str::trim).filter(|line| !line.is_empty()) {
            if !lines.contains(&line) {
                lines.push(line);
            }
        }
    }
    Some(lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scripts_of_tags() {
        assert_eq!(script_of("en-US"), Script::Latin);
        assert_eq!(script_of("de"), Script::Latin);
        assert_eq!(script_of("ru-RU"), Script::Cyrillic);
        assert_eq!(script_of("sr-Cyrl-RS"), Script::Cyrillic);
        assert_eq!(script_of("sr-Latn-RS"), Script::Latin);
        assert_eq!(script_of("sr"), Script::Cyrillic);
        assert_eq!(script_of("el-GR"), Script::Greek);
        assert_eq!(script_of("ar-SA"), Script::Arabic);
        assert_eq!(script_of("zh-Hans-CN"), Script::Han);
        assert_eq!(script_of("zh-TW"), Script::Han);
        assert_eq!(script_of("ja-JP"), Script::Japanese);
        assert_eq!(script_of("ko-KR"), Script::Hangul);
        assert_eq!(script_of("RU_ru"), Script::Cyrillic);
    }

    #[test]
    fn scores_count_letters_of_the_script() {
        assert_eq!(score("Invoice 48213", Script::Latin), 7);
        assert_eq!(score("Invoice 48213", Script::Cyrillic), 0);
        assert_eq!(score("Счёт 73591 оплачен", Script::Cyrillic), 11);
        assert_eq!(score("Счёт 73591 оплачен", Script::Latin), 0);
        assert_eq!(score("Café", Script::Latin), 4);
        assert_eq!(score("Γειά σου", Script::Greek), 7);
        assert_eq!(score("مرحبا", Script::Arabic), 5);
        assert_eq!(score("日本語のテキスト", Script::Japanese), 8);
        assert_eq!(score("日本語のテキスト", Script::Han), 3);
        assert_eq!(score("한국어", Script::Hangul), 3);
        assert_eq!(score("", Script::Latin), 0);
    }

    #[test]
    fn best_prefers_the_fitting_script_then_the_earlier() {
        let english = (Script::Latin, "Invoice 48213".to_string());
        let russian = (Script::Cyrillic, "Счёт 73591".to_string());
        assert_eq!(best(&[english.clone(), (Script::Cyrillic, "Invoice 48213".into())]), Some(0));
        assert_eq!(
            best(&[(Script::Latin, "".into()), russian.clone()]),
            Some(1)
        );
        assert_eq!(
            best(&[(Script::Latin, "".into()), (Script::Cyrillic, "".into())]),
            Some(0)
        );
        // 7 Latin letters against 4 Cyrillic: a convincing non-Latin reading still wins.
        assert_eq!(best(&[english.clone(), russian.clone()]), Some(1));
        // Mostly Latin look-alikes in a Cyrillic engine's text is not convincing: the count decides.
        let mixed = (Script::Cyrillic, "Invoice 48213 Сч".to_string());
        assert_eq!(best(&[english, mixed]), Some(0));
        assert_eq!(best(&[]), None);
    }

    #[test]
    fn merge_keeps_every_engines_lines_best_first() {
        // The English engine's reading is mostly Latin look-alikes, and more letters than the real Russian line.
        let english = (Script::Latin, "C4et 73591 onnaчeн Invoice 48213 invoice\nInvoice 48213".to_string());
        let russian = (Script::Cyrillic, "Счёт 73591 оплачен\nInvoice 48213".to_string());
        assert_eq!(
            merge(&[english, russian]).as_deref(),
            Some("Счёт 73591 оплачен\nInvoice 48213\nC4et 73591 onnaчeн Invoice 48213 invoice")
        );
        assert_eq!(merge(&[(Script::Latin, "".into())]).as_deref(), Some(""));
        assert_eq!(merge(&[]), None);
    }
}
