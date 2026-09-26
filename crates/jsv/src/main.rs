use anyhow::{anyhow, bail, Context, Result};
use clap::Parser;
use jsonschema::{Retrieve, Uri, Validator};
use serde_json::Value;
use std::collections::hash_map::Entry;
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use url::Url;

#[derive(Parser)]
#[command(name = "jsv", about = "Validate JSON files against their $schema")]
struct Cli {
    /// JSON files to validate
    #[arg(required = true)]
    files: Vec<String>,
}

struct Retriever;

impl Retrieve for Retriever {
    fn retrieve(
        &self,
        uri: &Uri<String>,
    ) -> std::result::Result<Value, Box<dyn std::error::Error + Send + Sync>> {
        Ok(fetch(&Url::parse(uri.as_str())?)?)
    }
}

fn fetch(url: &Url) -> Result<Value> {
    match url.scheme() {
        "http" | "https" => {
            let response = reqwest::blocking::get(url.as_str())
                .with_context(|| format!("failed to fetch schema: {url}"))?;
            if !response.status().is_success() {
                bail!("schema fetch returned {}: {url}", response.status());
            }
            response
                .json::<Value>()
                .with_context(|| format!("failed to parse schema JSON from {url}"))
        }
        "file" => {
            let path = url
                .to_file_path()
                .map_err(|()| anyhow!("invalid file URL: {url}"))?;
            let content = fs::read_to_string(&path)
                .with_context(|| format!("failed to read schema: {}", path.display()))?;
            serde_json::from_str(&content)
                .with_context(|| format!("failed to parse schema JSON: {}", path.display()))
        }
        scheme => bail!("unsupported schema location {scheme}: {url}"),
    }
}

fn schema_location(schema_ref: &str, file: &Path) -> Result<Url> {
    if Path::new(schema_ref).is_absolute() {
        return Url::from_file_path(schema_ref)
            .map_err(|()| anyhow!("invalid $schema: {schema_ref}"));
    }
    let file = fs::canonicalize(file)?;
    let file_url =
        Url::from_file_path(&file).map_err(|()| anyhow!("invalid path: {}", file.display()))?;
    file_url
        .join(schema_ref)
        .with_context(|| format!("invalid $schema: {schema_ref}"))
}

fn compile(location: &Url) -> Result<Validator> {
    let schema = fetch(location)?;
    jsonschema::options()
        .with_base_uri(location.to_string())
        .with_retriever(Retriever)
        .build(&schema)
        .map_err(|e| anyhow!("failed to compile schema {location}: {e}"))
}

fn validate_file(path: &str, validators: &mut HashMap<Url, Validator>) -> Result<bool> {
    let content =
        fs::read_to_string(path).with_context(|| format!("failed to read file: {path}"))?;
    let instance: Value =
        serde_json::from_str(&content).with_context(|| format!("invalid JSON: {path}"))?;

    let schema_ref = instance
        .get("$schema")
        .and_then(|v| v.as_str())
        .with_context(|| format!("{path}: no $schema field"))?;

    let validator = match validators.entry(schema_location(schema_ref, Path::new(path))?) {
        Entry::Occupied(entry) => entry.into_mut(),
        Entry::Vacant(entry) => {
            let validator = compile(entry.key())?;
            entry.insert(validator)
        }
    };

    let errors: Vec<String> = validator
        .iter_errors(&instance)
        .map(|e| format!("{} (at {})", e, e.instance_path()))
        .collect();

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
    let mut validators: HashMap<Url, Validator> = HashMap::new();
    let mut all_valid = true;

    for file in &cli.files {
        match validate_file(file, &mut validators) {
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
