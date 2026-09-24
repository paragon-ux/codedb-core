//! Minimal agent-id type. The full agent registry lived in the MCP/edit
//! surface (removed in this fork); only the id type remains because Store's
//! version ledger records the editing agent per change.
pub const AgentId = u64;
