use serde_json::{Map, Value, json};

const COMMAND: &str = "tarmac hooks run claude || true";
/// The design's unguarded form, which a user may write by hand.
const BARE_COMMAND: &str = "tarmac hooks run claude";
const EVENTS: [&str; 4] = ["Notification", "Stop", "UserPromptSubmit", "SessionStart"];

fn current_handler() -> Value {
    json!({"type": "command", "command": COMMAND, "timeout": 5})
}

/// The types that a merge relies on. A handler that is not an object is the
/// user's, and is left as it is.
pub(super) fn check_shape(root: &Value) -> Result<(), String> {
    let root = root.as_object().ok_or("the top level is not an object")?;
    let Some(hooks) = root.get("hooks") else { return Ok(()) };
    let hooks = hooks.as_object().ok_or("`hooks` is not an object")?;
    for (event, groups) in hooks {
        let groups = groups.as_array().ok_or_else(|| format!("`hooks.{event}` is not an array"))?;
        for group in groups {
            let group = group.as_object().ok_or_else(|| format!("a group in `hooks.{event}` is not an object"))?;
            if group.get("hooks").is_some_and(|h| !h.is_array()) {
                return Err(format!("the `hooks` of a group in `hooks.{event}` is not an array"));
            }
        }
    }
    Ok(())
}

/// Whether `handler` is one that `install` wrote, or the design's bare form.
/// Anything close to it is the user's: another path, other arguments, exec form.
fn is_ours(handler: &Value) -> bool {
    let Some(h) = handler.as_object() else { return false };
    h.get("type").and_then(Value::as_str) == Some("command")
        && !h.contains_key("args")
        && h.get("command").and_then(Value::as_str).is_some_and(|c| [COMMAND, BARE_COMMAND].contains(&c.trim()))
}

fn groups(root: &Value) -> impl Iterator<Item = (&String, &Value)> {
    root.get("hooks")
        .and_then(Value::as_object)
        .into_iter()
        .flatten()
        .flat_map(|(event, groups)| groups.as_array().into_iter().flatten().map(move |group| (event, group)))
}

pub(super) fn ours(root: &Value) -> impl Iterator<Item = &Value> {
    groups(root)
        .flat_map(|(_, group)| group.get("hooks").and_then(Value::as_array).into_iter().flatten())
        .filter(|h| is_ours(h))
}

/// Whether the handlers that are ours are exactly the current four: one alone
/// in a group with no other key under each event.
pub(super) fn is_current(root: &Value) -> bool {
    let current_group = json!({"hooks": [current_handler()]});
    ours(root).count() == EVENTS.len()
        && EVENTS
            .iter()
            .all(|event| groups(root).filter(|(e, group)| e == event && **group == current_group).count() == 1)
}

/// Removes every handler of ours, and prunes only what that emptied: a
/// container that was already empty stays. `retain` and `shift_remove` keep
/// the order of every key that stays. Whether any was removed.
pub(super) fn remove_ours(root: &mut Value) -> bool {
    let Some(root) = root.as_object_mut() else { return false };
    let Some(hooks) = root.get_mut("hooks").and_then(Value::as_object_mut) else { return false };
    let mut removed = false;
    hooks.retain(|_, groups| {
        let Some(groups) = groups.as_array_mut() else { return true };
        let had = groups.len();
        groups.retain_mut(|group| {
            let Some(handlers) = group.get_mut("hooks").and_then(Value::as_array_mut) else { return true };
            let before = handlers.len();
            handlers.retain(|h| !is_ours(h));
            removed |= handlers.len() < before;
            handlers.len() == before || !handlers.is_empty()
        });
        had == 0 || !groups.is_empty()
    });
    if removed && hooks.is_empty() {
        root.shift_remove("hooks");
    }
    removed
}

/// Appends one group with the current handler to each of the four events; a
/// missing key is added at the end of its object.
pub(super) fn add_current(root: &mut Value) {
    let Some(root) = root.as_object_mut() else { return };
    let hooks = root.entry("hooks").or_insert_with(|| Value::Object(Map::new()));
    let Some(hooks) = hooks.as_object_mut() else { return };
    for event in EVENTS {
        if let Some(groups) = hooks.entry(event).or_insert_with(|| json!([])).as_array_mut() {
            groups.push(json!({"hooks": [current_handler()]}));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings_file::render;

    fn ours_handlers() -> Vec<Value> {
        vec![
            current_handler(),
            json!({"type": "command", "command": BARE_COMMAND}),
            json!({"type": "command", "command": " tarmac hooks run claude "}),
        ]
    }

    fn foreign_handlers() -> Vec<Value> {
        vec![
            json!({"type": "command", "command": "/opt/homebrew/bin/tarmac hooks run claude"}),
            json!({"type": "command", "command": "tarmac hooks run claude --x"}),
            json!({"type": "command", "command": "tarmac", "args": ["hooks", "run", "claude"]}),
            json!({"type": "command", "command": BARE_COMMAND, "args": []}),
            json!({"type": "prompt", "command": BARE_COMMAND}),
            json!({"command": BARE_COMMAND}),
            json!(BARE_COMMAND),
        ]
    }

    fn installed() -> Value {
        let mut root = json!({});
        add_current(&mut root);
        root
    }
    /// "Only our handler forms count as ours".
    #[test]
    fn ours_is_an_exact_command_on_a_command_handler_with_no_args() {
        for h in &ours_handlers() {
            assert!(is_ours(h), "{h}");
        }
        for h in &foreign_handlers() {
            assert!(!is_ours(h), "{h}");
        }
    }

    /// "Only our handler forms count as ours".
    #[test]
    fn a_removal_keeps_every_foreign_handler_in_its_order() {
        let foreign = foreign_handlers();
        let mut all = ours_handlers();
        all.extend(foreign.iter().cloned());
        let mut root = json!({"hooks": {"Stop": [{"hooks": all}]}});

        assert!(remove_ours(&mut root));
        assert_eq!(root, json!({"hooks": {"Stop": [{"hooks": foreign}]}}));
    }

    #[test]
    fn the_installed_form_is_current() {
        let root = installed();
        assert!(is_current(&root));
        let hooks = root["hooks"].as_object().unwrap();
        let events = ["Notification", "Stop", "UserPromptSubmit", "SessionStart"];
        assert_eq!(hooks.keys().collect::<Vec<_>>(), events.iter().collect::<Vec<_>>());
        for event in events {
            assert_eq!(hooks[event], json!([{"hooks": [current_handler()]}]), "{event}");
        }
        let text = render(&root, None);
        assert!(
            text.contains(
                r#""type": "command",
            "command": "tarmac hooks run claude || true",
            "timeout": 5"#
            ),
            "{text}"
        );
    }

    fn old_forms() -> Vec<(&'static str, Value)> {
        let bare = json!({"type": "command", "command": BARE_COMMAND});
        let mut b = installed();
        b["hooks"].as_object_mut().unwrap().shift_remove("SessionStart");
        let mut c = installed();
        c["hooks"]["Stop"].as_array_mut().unwrap().push(json!({"hooks": [current_handler()]}));
        let mut d = installed();
        d["hooks"]["Stop"] = json!([{"hooks": [{"type": "command", "command": "say done"}, current_handler()]}]);
        let mut e = installed();
        e["hooks"]["Notification"][0]["matcher"] = json!("permission_prompt");
        let mut f = installed();
        f["hooks"]["PreToolUse"] = json!([{"hooks": [current_handler()]}]);
        let mut g = installed();
        g["hooks"]["Stop"][0]["hooks"][0]["timeout"] = json!(30);
        vec![
            (
                "a",
                json!({"hooks": {"Notification": [{"hooks": [bare.clone()]}], "Stop": [{"hooks": [bare.clone()]}], "UserPromptSubmit": [{"hooks": [bare.clone()]}], "SessionStart": [{"hooks": [bare]}]}}),
            ),
            ("b", b),
            ("c", c),
            ("d", d),
            ("e", e),
            ("f", f),
            ("a hand-edited timeout", g),
        ]
    }

    fn ours_count(root: &Value) -> usize {
        root["hooks"]
            .as_object()
            .into_iter()
            .flat_map(|h| h.values())
            .flat_map(|g| g.as_array().unwrap())
            .flat_map(|g| g["hooks"].as_array().unwrap())
            .filter(|h| is_ours(h))
            .count()
    }

    /// "Old forms are replaced by the current form".
    #[test]
    fn an_old_form_is_not_current_and_install_makes_it_current() {
        for (name, mut root) in old_forms() {
            assert!(!is_current(&root), "({name}) is current");
            remove_ours(&mut root);
            add_current(&mut root);
            assert!(is_current(&root), "({name}) after install: {root}");
            assert_eq!(ours_count(&root), 4, "({name})");
        }
    }

    /// "Old forms are replaced by the current form".
    #[test]
    fn ours_leaves_a_users_group_for_a_group_of_its_own() {
        let (_, mut root) = old_forms().into_iter().find(|(n, _)| *n == "d").unwrap();
        remove_ours(&mut root);
        add_current(&mut root);
        assert_eq!(
            root["hooks"]["Stop"],
            json!([{"hooks": [{"type": "command", "command": "say done"}]}, {"hooks": [current_handler()]}])
        );
    }

    /// "Prune removes only what uninstall emptied".
    #[test]
    fn a_container_that_was_already_empty_stays() {
        let mut root = json!({"hooks": {"Stop": []}});
        assert!(!remove_ours(&mut root));
        assert_eq!(root, json!({"hooks": {"Stop": []}}));

        let mut root = json!({"hooks": {"Stop": [], "PreToolUse": [{"hooks": [current_handler()]}]}});
        assert!(remove_ours(&mut root));
        assert_eq!(root, json!({"hooks": {"Stop": []}}));

        let mut root = json!({"hooks": {"Stop": [{"hooks": []}, {"hooks": [current_handler()]}]}});
        remove_ours(&mut root);
        assert_eq!(root, json!({"hooks": {"Stop": [{"hooks": []}]}}));
    }

    /// "Prune removes only what uninstall emptied".
    #[test]
    fn a_group_keeps_its_matcher_while_it_has_another_handler() {
        let foreign = json!({"type": "command", "command": "say x"});
        let mut root = json!({"hooks": {"Stop": [{"matcher": "x", "hooks": [current_handler(), foreign.clone()]}]}});
        remove_ours(&mut root);
        assert_eq!(root, json!({"hooks": {"Stop": [{"matcher": "x", "hooks": [foreign]}]}}));
    }

    /// "Prune removes only what uninstall emptied".
    #[test]
    fn a_group_and_the_hooks_key_go_when_the_removal_empties_them() {
        let mut root = json!({"model": "x", "hooks": {"Stop": [{"matcher": "x", "hooks": [current_handler()]}]}});
        remove_ours(&mut root);
        assert_eq!(root, json!({"model": "x"}));

        let mut root = installed();
        remove_ours(&mut root);
        assert_eq!(root, json!({}));
    }

    const F_ODD: &str = "{\n  \"u\": \"\\u00e9\",\n  \"d\": \"first\",\n  \"s\": \"a\\/b\",\n  \"n\": 1.50,\n  \"e\": 1e3,\n  \"arr\": [1, 2, 3],\n  \"o\": { },\n  \"d\": \"last\"\n}\n";

    // "Formatting outside the merge is preserved": the accepted changes of a parse and a re-write, predicted by hand.
    #[test]
    fn an_odd_file_changes_only_as_the_accepted_list_says() {
        let mut root: Value = serde_json::from_str(F_ODD).unwrap();
        add_current(&mut root);
        let installed_text = render(&root, Some(F_ODD));
        let mut root: Value = serde_json::from_str(&installed_text).unwrap();
        remove_ours(&mut root);

        assert_eq!(
            render(&root, Some(&installed_text)),
            "{\n  \"u\": \"é\",\n  \"d\": \"last\",\n  \"s\": \"a/b\",\n  \"n\": 1.5,\n  \"e\": 1000.0,\n  \"arr\": [\n    1,\n    2,\n    3\n  ],\n  \"o\": {}\n}\n"
        );
    }
}
