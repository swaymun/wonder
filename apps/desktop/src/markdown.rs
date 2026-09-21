use ::markdown::{mdast::Node, ParseOptions};

// Markdown is presentation only: media must use the authenticated file viewer.
pub fn safe_markdown(source: &str) -> String {
    let Ok(tree) = ::markdown::to_mdast(source, &ParseOptions::gfm()) else {
        return escape(source);
    };
    let mut edits = Vec::new();
    let mut code = Vec::new();
    fn walk(node: &Node, edits: &mut Vec<(usize, usize, String)>, code: &mut Vec<(usize, usize)>) {
        if let Some(p) = node.position() {
            let range = (p.start.offset, p.end.offset);
            match node {
                Node::Code(_) | Node::InlineCode(_) => code.push(range),
                Node::Image(_) | Node::ImageReference(_) => {
                    edits.push((range.0, range.1, "Image preview unavailable".into()));
                    return;
                }
                Node::Html(_) => {
                    edits.push((range.0, range.1, String::new()));
                    return;
                }
                _ => {}
            }
        }
        if let Some(children) = node.children() {
            for child in children {
                walk(child, edits, code);
            }
        }
    }
    walk(&tree, &mut edits, &mut code);
    let mut offset = 0;
    while let Some(start) = source[offset..].find("<oai-mem-citation>") {
        let start = offset + start;
        let end = source[start..]
            .find("</oai-mem-citation>")
            .map(|n| start + n + "</oai-mem-citation>".len())
            .unwrap_or(source.len());
        if !code.iter().any(|&(a, b)| a <= start && start < b) {
            edits.retain(|&(a, b, _)| b <= start || a >= end);
            edits.push((start, end, String::new()));
        }
        offset = end;
    }
    edits.sort_by_key(|e| e.0);
    let mut result = source.to_owned();
    for (start, end, replacement) in edits.into_iter().rev() {
        result.replace_range(start..end, &replacement);
    }
    result
}
pub fn accessible_text(source: &str) -> String {
    let safe = safe_markdown(source);
    match ::markdown::to_mdast(&safe, &ParseOptions::gfm()) {
        Ok(tree) => tree
            .children()
            .map(|children| {
                children
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join("\n\n")
            })
            .unwrap_or_else(|| tree.to_string()),
        Err(_) => safe,
    }
}

fn escape(source: &str) -> String {
    source
        .chars()
        .flat_map(|c| {
            if c.is_ascii_punctuation() {
                vec!['\\', c]
            } else {
                vec![c]
            }
        })
        .collect()
}
pub fn web_link(url: &str) -> bool {
    reqwest::Url::parse(url)
        .is_ok_and(|u| matches!(u.scheme(), "http" | "https") && u.host_str().is_some())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn inert_media_preserves_code_and_formatting() {
        let value = safe_markdown("**Bold**\n\n![x](https://private/image)\n\n<img src=\"file:///private\">\n\n```md\n![literal](url)\n```\n");
        assert!(value.contains("**Bold**"));
        assert!(!value.contains("https://private"));
        assert!(!value.contains("file:///private"));
        assert!(value.contains("![literal](url)"));
    }
    #[test]
    fn accessible_prose_keeps_text_and_removes_markup_and_private_metadata() {
        assert_eq!(
            accessible_text("**Hello** [there](https://example.com).\n\nNext paragraph."),
            "Hello there.\n\nNext paragraph."
        );
        assert!(
            !accessible_text("Answer\n<oai-mem-citation>private</oai-mem-citation>")
                .contains("private")
        );
    }
    #[test]
    fn citation_metadata_is_not_feed_text() {
        assert_eq!(
            safe_markdown("Answer\n\n<oai-mem-citation>\nsecret\n</oai-mem-citation>"),
            "Answer\n\n"
        );
        assert!(safe_markdown("`<oai-mem-citation>`").contains("<oai-mem-citation>"));
        assert!(!web_link("file:///tmp/test"));
        assert!(!web_link("codex://run"));
        assert!(web_link("https://example.com"));
    }
}
