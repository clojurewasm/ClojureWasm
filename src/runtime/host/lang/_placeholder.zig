// SPDX-License-Identifier: EPL-2.0
//! Placeholder marker for the cljw.host.java.lang package directory.
//!
//! Phase 4 lands the directory layout per ADR-0011; concrete host
//! classes (per compat_tiers.yaml host_classes entries) land in
//! their own files as the corresponding phase opens. Each real host
//! file replaces this placeholder and exports `___HOST_EXTENSION`
//! (Extension struct value defined in src/runtime/host/_host_api.zig).
