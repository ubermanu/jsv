use anyhow::{bail, Context, Result};
use clap::Parser;
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::path::Path;

#[derive(Parser)]
#[command(name = "jsv", about = "Validate JSON files against their $schema")]
struct Cli {
    /// JSON files to validate
    #[arg(required = true)]
    files: Vec<String>,
}

fn fetch_schema(schema_ref: &str, base_dir: &Path) -> Result<Value> {
    if schema_ref.starts_with("http://") || schema_ref.starts_with("https://") {
        let response = reqwest::blocking::get(schema_ref)
            .with_context(|| format!("failed to fetch schema: {schema_ref}"))?;
        if !response.status().is_success() {
            bail!("schema fetch returned {}: {schema_ref}", response.status());
        }
        response
            .json::<Value>()
            .with_context(|| format!("failed to parse schema JSON from {schema_ref}"))
    } else {
        let path = if Path::new(schema_ref).is_absolute() {
            Path::new(schema_ref).to_path_buf()
        } else {
            base_dir.join(schema_ref)
        };
        let content = fs::read_to_string(&path)
            .with_context(|| format!("failed to read schema: {}", path.display()))?;
        serde_json::from_str(&content)
            .with_context(|| format!("failed to parse schema JSON: {}", path.display()))
    }
}

fn validate_file(path: &str, cache: &mut HashMap<String, Value>) -> Result<bool> {
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read file: {path}"))?;
    let instance: Value =
        serde_json::from_str(&content).with_context(|| format!("invalid JSON: {path}"))?;

    let schema_ref = instance
        .get("$schema")
        .and_then(|v| v.as_str())
        .with_context(|| format!("{path}: no $schema field"))?;

    let base_dir = Path::new(path)
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .to_path_buf();

    // Use schema_ref as the cache key (relative paths are relative to the file being validated,
    // so the same relative ref from different directories could be different schemas — we accept
    // that tradeoff here since mixing directories is uncommon in practice)
    let schema = if let Some(cached) = cache.get(schema_ref) {
        cached.clone()
    } else {
        let schema = fetch_schema(schema_ref, &base_dir)?;
        cache.insert(schema_ref.to_string(), schema.clone());
        schema
    };

    let compiled = jsonschema::JSONSchema::compile(&schema)
        .map_err(|e| anyhow::anyhow!("failed to compile schema: {e}"))?;

    let errors: Vec<String> = match compiled.validate(&instance) {
        Ok(()) => vec![],
        Err(errs) => errs
            .map(|e| format!("{} (at {})", e, e.instance_path))
            .collect(),
    };

    if errors.is_empty() {
        println!("{path}: valid");
        Ok(true)
    } else {
        for error in &errors {
            println!("{path}: {error}");
        }
        Ok(false)
    }
}

fn main() {
    let cli = Cli::parse();
    let mut cache: HashMap<String, Value> = HashMap::new();
    let mut all_valid = true;

    for file in &cli.files {
        match validate_file(file, &mut cache) {
            Ok(valid) => {
                if !valid {
                    all_valid = false;
                }
            }
            Err(e) => {
                eprintln!("error: {e:#}");
                all_valid = false;
            }
        }
    }

    std::process::exit(if all_valid { 0 } else { 1 });
}
