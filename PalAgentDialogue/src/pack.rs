use std::{collections::HashSet, fs, path::Path};

use crate::domain::{
    is_safe_id, is_safe_key, CharacterDefinition, CharacterPack, ContentOrigin, SCHEMA_VERSION,
};

#[derive(Debug, thiserror::Error)]
pub enum PackError {
    #[error("cannot read character pack: {0}")]
    Read(#[source] std::io::Error),
    #[error("character pack JSON is invalid: {0}")]
    Decode(#[source] serde_json::Error),
    #[error("invalid character pack: {0}")]
    Invalid(String),
}

pub fn load_character_pack(path: &Path) -> Result<CharacterPack, PackError> {
    let bytes = fs::read(path).map_err(PackError::Read)?;
    if bytes.len() > 2 * 1024 * 1024 {
        return Err(PackError::Invalid(
            "pack exceeds the 2 MiB public-runtime limit".to_string(),
        ));
    }
    let pack = serde_json::from_slice::<CharacterPack>(&bytes).map_err(PackError::Decode)?;
    validate_character_pack(&pack)?;
    Ok(pack)
}

pub fn validate_character_pack(pack: &CharacterPack) -> Result<(), PackError> {
    if pack.schema_version != SCHEMA_VERSION {
        return invalid("unsupported schemaVersion");
    }
    if !is_safe_id(&pack.pack_id) {
        return invalid("packId must be a portable identifier");
    }
    if pack.version.trim().is_empty() || pack.version.chars().count() > 64 {
        return invalid("version is missing or too long");
    }
    if pack.content_license.trim().is_empty() || pack.content_license.chars().count() > 128 {
        return invalid("contentLicense is missing or too long");
    }
    if pack.characters.is_empty() || pack.characters.len() > 256 {
        return invalid("characters must contain between 1 and 256 entries");
    }

    let mut ids = HashSet::new();
    for character in &pack.characters {
        validate_character(character)?;
        if !ids.insert(&character.character_id) {
            return invalid(format!("duplicate characterId: {}", character.character_id));
        }
    }
    Ok(())
}

fn validate_character(character: &CharacterDefinition) -> Result<(), PackError> {
    if !is_safe_id(&character.character_id) {
        return invalid("characterId must be a portable identifier");
    }
    for (label, key) in [
        ("displayNameKey", &character.display_name_key),
        ("personaKey", &character.persona_key),
    ] {
        if !is_safe_key(key) {
            return invalid(format!("{label} must be a localization/persona key"));
        }
    }

    match character.content_origin {
        ContentOrigin::LocalizationKeysOnly if character.persona_text.is_some() => {
            return invalid("localization_keys_only characters cannot embed personaText")
        }
        ContentOrigin::UserAuthored => {
            let text = character
                .persona_text
                .as_deref()
                .ok_or_else(|| PackError::Invalid("user_authored requires personaText".into()))?;
            if text.trim().is_empty() || text.chars().count() > 8_000 {
                return invalid("personaText is empty or exceeds 8000 characters");
            }
        }
        ContentOrigin::LocalizationKeysOnly => {}
    }

    validate_unique_keys("knowledgeKeys", &character.knowledge_keys, 256)?;
    validate_unique_keys("allowedResultTags", &character.allowed_result_tags, 128)?;

    let mut choice_ids = HashSet::new();
    for choice in &character.default_choices {
        if !is_safe_id(&choice.choice_id) || !is_safe_key(&choice.text_key) {
            return invalid("defaultChoices must contain portable IDs and text keys");
        }
        if !choice_ids.insert(&choice.choice_id) {
            return invalid(format!("duplicate default choice: {}", choice.choice_id));
        }
    }
    Ok(())
}

fn validate_unique_keys(label: &str, values: &[String], maximum: usize) -> Result<(), PackError> {
    if values.len() > maximum {
        return invalid(format!("{label} exceeds {maximum} entries"));
    }
    let mut unique = HashSet::new();
    for value in values {
        if !is_safe_key(value) {
            return invalid(format!("{label} contains an invalid key"));
        }
        if !unique.insert(value) {
            return invalid(format!("{label} contains a duplicate key"));
        }
    }
    Ok(())
}

fn invalid<T>(message: impl Into<String>) -> Result<T, PackError> {
    Err(PackError::Invalid(message.into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{CharacterDefinition, ContentOrigin};

    fn valid_pack() -> CharacterPack {
        CharacterPack {
            schema_version: SCHEMA_VERSION.to_string(),
            pack_id: "example.pack".to_string(),
            version: "1.0.0".to_string(),
            content_license: "CC-BY-4.0".to_string(),
            characters: vec![CharacterDefinition {
                character_id: "example_npc".to_string(),
                display_name_key: "example.name".to_string(),
                persona_key: "example.persona".to_string(),
                content_origin: ContentOrigin::LocalizationKeysOnly,
                persona_text: None,
                knowledge_keys: vec!["example.knowledge.greeting".to_string()],
                allowed_result_tags: vec!["heard_player".to_string()],
                default_choices: vec![],
            }],
        }
    }

    #[test]
    fn accepts_localization_key_only_pack() {
        validate_character_pack(&valid_pack()).expect("valid pack");
    }

    #[test]
    fn rejects_inline_persona_for_key_only_content() {
        let mut pack = valid_pack();
        pack.characters[0].persona_text = Some("forbidden inline persona".to_string());
        assert!(validate_character_pack(&pack).is_err());
    }

    #[test]
    fn accepts_explicit_user_authored_persona() {
        let mut pack = valid_pack();
        pack.characters[0].content_origin = ContentOrigin::UserAuthored;
        pack.characters[0].persona_text = Some("An original user-authored persona.".to_string());
        validate_character_pack(&pack).expect("user-authored pack");
    }
}
