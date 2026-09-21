use super::*;
use std::sync::Arc;

pub(super) enum Content {
    Image(Arc<Image>),
    Text(String),
}
pub(super) struct Preview {
    name: String,
    content: Content,
}
pub(super) struct Loaded {
    chat: String,
    result: Result<Preview, String>,
}
fn decode(file: &PreviewFile, bytes: Vec<u8>) -> Result<Preview, String> {
    let content = match file.mime_type.as_deref() {
        Some("text/plain" | "text/markdown") => {
            if bytes.len() > 2 * 1024 * 1024 {
                return Err("This text file is too large to preview here.".into());
            }
            Content::Text(String::from_utf8(bytes).map_err(|_| "This file is not UTF-8 text")?)
        }
        Some(mime) if mime.starts_with("image/") => {
            let expected = match mime {
                "image/png" => ::image::ImageFormat::Png,
                "image/jpeg" => ::image::ImageFormat::Jpeg,
                "image/gif" => ::image::ImageFormat::Gif,
                "image/webp" => ::image::ImageFormat::WebP,
                _ => return Err("Preview unavailable".into()),
            };
            if ::image::guess_format(&bytes).ok() != Some(expected) {
                return Err("Image contents did not match its file type.".into());
            }
            let mut reader =
                ::image::ImageReader::with_format(std::io::Cursor::new(&bytes), expected);
            let mut limits = ::image::Limits::default();
            limits.max_image_width = Some(8192);
            limits.max_image_height = Some(8192);
            limits.max_alloc = Some(64 * 1024 * 1024);
            reader.limits(limits);
            let decoded = reader
                .decode()
                .map_err(|_| "Image could not be safely decoded")?;
            // Hand GPUI one validated frame, rather than an unbounded animation.
            let mut png = std::io::Cursor::new(Vec::new());
            decoded
                .write_to(&mut png, ::image::ImageFormat::Png)
                .map_err(|_| "Image preview could not be prepared")?;
            Content::Image(Arc::new(Image::from_bytes(
                ImageFormat::Png,
                png.into_inner(),
            )))
        }
        _ => return Err("Preview unavailable for this file type.".into()),
    };
    Ok(Preview {
        name: file.name.clone(),
        content,
    })
}
impl Chats {
    fn open_preview(&mut self, file: PreviewFile, cx: &mut Context<Self>) {
        if self.media_loading {
            return;
        }
        let (Some(connection), Some(chat), Some(host)) = (
            self.connection.clone(),
            self.selected.clone(),
            self.host.clone(),
        ) else {
            return;
        };
        self.media_loading = true;
        self.showing_media = true;
        self.media = None;
        self.files_error = None;
        let sender = self.media_sender.clone();
        std::thread::spawn(move || {
            let result = connection
                .download_file(&chat, &file, &host)
                .and_then(|bytes| decode(&file, bytes));
            let _ = sender.send(Loaded { chat, result });
        });
        cx.notify();
    }
    pub(super) fn tick_media(&mut self, cx: &mut Context<Self>) {
        while let Ok(loaded) = self.media_receiver.try_recv() {
            self.media_loading = false;
            if self.selected.as_ref() == Some(&loaded.chat) && self.showing_media {
                match loaded.result {
                    Ok(preview) => self.media = Some(preview),
                    Err(error) => self.files_error = Some(error),
                }
            }
            cx.notify();
        }
    }
    pub(super) fn files_view(&self, cx: &mut Context<Self>) -> Div {
        div()
            .px_6()
            .when(!self.files.is_empty(), |v| {
                v.child(
                    div()
                        .id("conversation-files")
                        .max_h(px(110.))
                        .overflow_y_scroll()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .children(self.files.iter().enumerate().map(|(index, file)| {
                            let file = file.clone();
                            let label = if file.supported() {
                                format!("Preview {}", file.name)
                            } else {
                                format!("{} — Preview unavailable", file.name)
                            };
                            Button::new(("preview-file", index))
                                .ghost()
                                .label(label)
                                .disabled(!file.supported() || self.media_loading)
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.open_preview(file.clone(), cx)
                                }))
                        })),
                )
            })
            .when_some(self.files_error.clone(), |v, error| {
                v.child(div().text_sm().text_color(cx.theme().danger).child(error))
            })
    }
    pub(super) fn media_view(&self, cx: &mut Context<Self>) -> Div {
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .child(
                div()
                    .p_4()
                    .flex()
                    .gap_4()
                    .items_center()
                    .child(Button::new("close-preview").label("Back to chat").on_click(
                        cx.listener(|this, _, _, cx| {
                            this.showing_media = false;
                            this.media = None;
                            cx.notify();
                        }),
                    ))
                    .child(
                        self.media
                            .as_ref()
                            .map(|p| p.name.clone())
                            .unwrap_or("Preview".into()),
                    ),
            )
            .when(self.media_loading, |v| {
                v.child(div().p_6().child("Loading preview…"))
            })
            .when_some(self.files_error.clone(), |v, error| {
                v.child(div().p_6().child(error))
            })
            .when_some(self.media.as_ref(), |v, preview| match &preview.content {
                Content::Image(image) => v.child(
                    div().relative().flex_1().min_h_0().overflow_hidden().child(
                        img(image.clone())
                            .absolute()
                            .top_0()
                            .left_0()
                            .size_full()
                            .object_fit(ObjectFit::Contain),
                    ),
                ),
                Content::Text(text) => v.child(
                    div()
                        .id("text-preview")
                        .flex_1()
                        .overflow_y_scroll()
                        .p_6()
                        .child(text.clone()),
                ),
            })
    }
}
#[cfg(test)]
mod tests {
    use super::{decode, Content};
    use crate::client::PreviewFile;
    #[test]
    fn malformed_image_and_invalid_utf8_are_rejected() {
        let mut file = PreviewFile {
            id: "file".into(),
            name: "file".into(),
            mime_type: Some("image/png".into()),
            byte_size: Some(1),
            sha256: None,
            state: "available".into(),
        };
        assert!(decode(&file, b"not an image".to_vec()).is_err());
        file.mime_type = Some("text/plain".into());
        assert!(decode(&file, vec![255]).is_err());
        assert!(matches!(
            decode(&file, b"Hello".to_vec()).unwrap().content,
            Content::Text(_)
        ));
    }
}
