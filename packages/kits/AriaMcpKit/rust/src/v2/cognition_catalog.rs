//! Typed ARIA v2 cognition directory adapters.
//!
//! These adapters read the lower tool and CognitionKit registries directly.
//! They never call the v1 recipe runner or interpret its rendered response.

use std::collections::BTreeSet;

use serde::Serialize;
use serde_json::Value;
use uuid::Uuid;

use crate::jsonrpc::JsonValue;

use super::codec::{optional_uuid, strict_object, V2DecodeResult, V2InvalidArgument};

pub const LIST_LENSES_TOOL: &str = "moot_list_lenses";
pub const LIST_RECIPES_TOOL: &str = "moot_list_recipes";

/// The shared strict request shape for both cognition directories.
///
/// `verbose` remains accepted for source compatibility with the v1 listings.
/// The selected v2 response always returns the complete typed directory.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CognitionCatalogRequest {
    pub verbose: bool,
    pub estate_id: Option<Uuid>,
}

impl CognitionCatalogRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["verbose", "estate_id"])?;
        let verbose = match object.get("verbose") {
            None => false,
            Some(JsonValue::Bool(value)) => *value,
            Some(_) => return Err(V2InvalidArgument::new("$.verbose", "must be a boolean")),
        };
        Ok(Self {
            verbose,
            estate_id: optional_uuid(object, "estate_id")?,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CognitionCatalogOperation {
    Lenses,
    Recipes,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CognitionCatalogFailure {
    pub code: &'static str,
    pub message: &'static str,
    pub retryable: bool,
}

impl CognitionCatalogFailure {
    fn estate_unavailable() -> Self {
        Self {
            code: "estate_unavailable",
            message: "The requested estate is not available to this caller.",
            retryable: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CognitionToolDescriptor {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CognitionLensesData {
    pub tools: Vec<CognitionToolDescriptor>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CognitionRecipeDescriptor {
    pub name: String,
    pub version: String,
    pub description: String,
    pub required_capabilities: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CognitionRecipesData {
    pub recipes: Vec<CognitionRecipeDescriptor>,
}

/// A selected-surface view over direct lower registries.
pub struct CognitionCatalogService {
    selected_estate_id: Uuid,
    callable_tool_names: BTreeSet<String>,
}

impl CognitionCatalogService {
    pub fn new(
        selected_estate_id: Uuid,
        callable_tool_names: BTreeSet<String>,
    ) -> Self {
        Self { selected_estate_id, callable_tool_names }
    }

    pub fn lenses(
        &self,
        request: CognitionCatalogRequest,
    ) -> Result<CognitionLensesData, CognitionCatalogFailure> {
        self.validate(request)?;
        let _ = request.verbose;

        let tools = crate::tool_list::build_tool_list_with_flags(false, false)
            .as_array()
            .expect("the static lower tool registry must be an array")
            .iter()
            .filter_map(|tool| {
                let name = tool.get("name")?.as_str()?;
                if !(crate::recipe_tools::is_recipe_tool(name)
                    || crate::lens_tools::is_lens_tool(name))
                    || !self.callable_tool_names.contains(name)
                {
                    return None;
                }
                Some(CognitionToolDescriptor {
                    name: name.to_owned(),
                    description: tool["description"]
                        .as_str()
                        .expect("lower tool descriptors must have descriptions")
                        .to_owned(),
                    input_schema: tool["inputSchema"].clone(),
                })
            })
            .collect();
        Ok(CognitionLensesData { tools })
    }

    pub fn recipes(
        &self,
        request: CognitionCatalogRequest,
    ) -> Result<CognitionRecipesData, CognitionCatalogFailure> {
        self.validate(request)?;
        let _ = request.verbose;
        let recipes = cognition_kit::recipe_catalog()
            .into_iter()
            .map(|recipe| CognitionRecipeDescriptor {
                name: recipe.name,
                version: recipe.version,
                description: recipe.description,
                required_capabilities: recipe.required_capabilities
                    .into_iter()
                    .map(|capability| capability.raw_value().to_owned())
                    .collect(),
            })
            .collect();
        Ok(CognitionRecipesData { recipes })
    }

    fn validate(&self, request: CognitionCatalogRequest) -> Result<(), CognitionCatalogFailure> {
        if request.estate_id.is_some_and(|estate_id| estate_id != self.selected_estate_id) {
            return Err(CognitionCatalogFailure::estate_unavailable());
        }
        Ok(())
    }
}
