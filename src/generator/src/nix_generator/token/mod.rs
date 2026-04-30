pub mod nix_attr_set;
pub mod nix_list;
pub mod nix_value;

use std::fmt;

pub use nix_attr_set::NixAttrSet;
pub use nix_list::NixList;
pub use nix_value::NixValue;

/// Marker trait for all Nix token types.
pub trait NixItem: fmt::Display + fmt::Debug + Send + Sync {}

impl NixItem for NixValue {}
impl NixItem for NixList {}
impl NixItem for NixAttrSet {}
