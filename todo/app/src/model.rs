//! The part of the list the shell itself uses: the badge, notifications, and what a board request may refer to.
use crate::i18n::{t, Lang};
use serde::Deserialize;

#[derive(Clone, Default, Deserialize)]
pub struct Turn {
    pub actor: String,
    pub kind: String,
}

#[derive(Clone, Default, Deserialize)]
pub struct Item {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub done: bool,
    #[serde(default)]
    pub run: String,
    pub turn: Turn,
}

impl Item {
    pub fn needs_you(&self) -> bool { !self.done && matches!(self.turn.actor.as_str(), "you" | "blocked") }

    /// What the notification says of an item that needs the human.
    pub fn ask(&self, lang: Lang) -> &'static str {
        t(lang, match self.turn.kind.as_str() {
            "approve-intent" => "status.approve-intent",
            "approve-plan" => "status.approve-plan",
            "blocked" => "status.blocked",
            _ => "status.answer",
        })
    }
}

#[derive(Clone, Default, Deserialize)]
pub struct Model {
    pub items: Vec<Item>,
    #[serde(default)]
    pub lang: String,
}

impl Model {
    pub fn waiting(&self) -> usize { self.items.iter().filter(|item| item.needs_you()).count() }

    /// The items that need the human now and did not in `before`.
    pub fn newly_waiting<'a>(&'a self, before: &Model) -> Vec<&'a Item> {
        self.items.iter().filter(|item| item.needs_you() && !before.items.iter().any(|old| old.id == item.id && old.needs_you())).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, actor: &str, kind: &str) -> Item {
        Item { id: id.into(), title: id.into(), turn: Turn { actor: actor.into(), kind: kind.into() }, ..Default::default() }
    }

    #[test]
    fn only_items_that_newly_wait_for_you_are_announced() {
        let before = Model { items: vec![item("a", "you", "answer"), item("b", "agent", "working"), item("c", "agent", "agent")], ..Default::default() };
        let now = Model { items: vec![item("a", "you", "answer"), item("b", "blocked", "blocked"), item("c", "others", "others"),
            item("d", "you", "approve-plan"), Item { done: true, ..item("e", "you", "answer") }], ..Default::default() };
        assert_eq!(now.newly_waiting(&before).iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), ["b", "d"]);
        assert_eq!(now.waiting(), 3);
        assert_eq!(now.items[3].ask(Lang::Ko), "계획 승인 필요");
        assert_eq!(now.items[1].ask(Lang::En), "Blocked — needs action");
    }

    #[test]
    fn the_servers_payload_parses_with_fields_the_shell_does_not_use() {
        let model: Model = serde_json::from_str(r#"{"items":[{"id":"1","title":"t","version":"v","turn":{"actor":"you","kind":"answer","gate":""},"link":null}],"feed":null,"file":"/x"}"#).unwrap();
        assert!(model.items[0].needs_you() && model.lang.is_empty());
    }
}
