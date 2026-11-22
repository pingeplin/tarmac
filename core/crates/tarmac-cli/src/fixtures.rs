//! Test helpers that the inline tests of more than one module share.

pub(crate) fn args(a: &[&str]) -> Vec<String> {
    a.iter().map(ToString::to_string).collect()
}
