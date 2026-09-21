//! The OS status item is a small platform bridge; the app and windows live in GPUI.
#![allow(unexpected_cfgs)] // objc 0.2's macros probe their own legacy feature flags.
use objc::{
    class,
    declare::ClassDecl,
    msg_send,
    rc::StrongPtr,
    runtime::{Object, Sel},
    sel, sel_impl,
};
use std::sync::atomic::{AtomicU8, Ordering};
static ACTIONS: AtomicU8 = AtomicU8::new(0);
pub const OPEN: u8 = 1;
pub const SETTINGS: u8 = 2;
pub const QUIT: u8 = 4;
const STOP_CONTROL: u8 = 8;
pub fn pending() -> u8 {
    ACTIONS.swap(0, Ordering::Relaxed)
}
extern "C" fn selected(_: &Object, _: Sel, sender: *mut Object) {
    let tag: isize = unsafe { msg_send![sender, tag] };
    if tag as u8 == STOP_CONTROL {
        // Only revokes the helper's current lease; it never changes the saved
        // paired-device permission or starts another control session.
        unsafe {
            let center: *mut Object = msg_send![class!(NSDistributedNotificationCenter), defaultCenter];
            let _: () = msg_send![center,
                postNotificationName:*string("com.wonder.stop-control")
                object:std::ptr::null_mut::<Object>()
                userInfo:std::ptr::null_mut::<Object>()
                deliverImmediately:true];
        }
    } else {
        ACTIONS.fetch_or(tag as u8, Ordering::Relaxed);
    }
}
unsafe fn string(value: &str) -> StrongPtr {
    let raw: *mut Object = msg_send![class!(NSString), alloc];
    let raw: *mut Object =
        msg_send![raw, initWithBytes:value.as_ptr() length:value.len() encoding:4usize];
    StrongPtr::new(raw)
}
/// Apply the app-wide AppKit appearance on GPUI's main thread, including titlebars.
pub fn set_appearance(dark: Option<bool>) {
    unsafe {
        let app: *mut Object = msg_send![class!(NSApplication), sharedApplication];
        let appearance: *mut Object = match dark {
            Some(dark) => {
                let name = string(if dark {
                    "NSAppearanceNameDarkAqua"
                } else {
                    "NSAppearanceNameAqua"
                });
                msg_send![class!(NSAppearance), appearanceNamed: *name]
            }
            None => std::ptr::null_mut(),
        };
        let _: () = msg_send![app, setAppearance: appearance];
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
struct ImageSize {
    width: f64,
    height: f64,
}
unsafe impl objc::Encode for ImageSize {
    fn encode() -> objc::Encoding {
        unsafe { objc::Encoding::from_str("{CGSize=dd}") }
    }
}

pub struct MenuBar {
    item: StrongPtr,
    _target: StrongPtr,
}
impl MenuBar {
    /// Called and dropped only on GPUI's main thread.
    pub fn new() -> Self {
        unsafe {
            let action_class =
                objc::runtime::Class::get("WonderStatusActions").unwrap_or_else(|| {
                    let mut class = ClassDecl::new("WonderStatusActions", class!(NSObject))
                        .expect("unique status class");
                    class.add_method(
                        sel!(selected:),
                        selected as extern "C" fn(&Object, Sel, *mut Object),
                    );
                    class.register()
                });
            let target = StrongPtr::new(msg_send![action_class, new]);
            let bar: *mut Object = msg_send![class!(NSStatusBar), systemStatusBar];
            let item: *mut Object = msg_send![bar, statusItemWithLength:28.0f64];
            let item = StrongPtr::retain(item);
            let button: *mut Object = msg_send![*item, button];
            let title = string("Wonder");
            let icon = std::env::current_exe().ok().and_then(|exe| {
                exe.parent()?
                    .parent()
                    .map(|contents| contents.join("Resources/WonderMenuIcon.pdf"))
            });
            let raw: *mut Object = msg_send![class!(NSImage), alloc];
            let raw: *mut Object = msg_send![raw, initWithContentsOfFile:*string(&icon.map(|p| p.to_string_lossy().into_owned()).unwrap_or_default())];
            let owned_image = StrongPtr::new(raw);
            let image = *owned_image;
            if image.is_null() {
                let _: () = msg_send![button, setTitle:*title];
            } else {
                let _: () = msg_send![image, setSize:ImageSize { width: 24., height: 18. }];
                let _: () = msg_send![image, setTemplate:true];
                let _: () = msg_send![image, setAccessibilityDescription:*title];
                let _: () = msg_send![button, setImage:image];
            }
            let _: () = msg_send![button, setToolTip:*title];
            let _: () = msg_send![button, setAccessibilityLabel:*title];
            let _: () = msg_send![*item, setVisible:true];
            let menu = StrongPtr::new(msg_send![class!(NSMenu), new]);
            let _: () = msg_send![*menu, setAutoenablesItems:false];
            let mut entries = vec![];
            if crate::CHAT_CLIENT {
                entries.push(("Open Wonder", OPEN));
            }
            entries.push(("Settings…", SETTINGS));
            entries.push(("Stop Control", STOP_CONTROL));
            entries.push(("Quit Wonder", QUIT));
            for (label, tag) in entries {
                if tag == QUIT {
                    let separator: *mut Object = msg_send![class!(NSMenuItem), separatorItem];
                    let _: () = msg_send![*menu, addItem:separator];
                }
                let entry: *mut Object = msg_send![class!(NSMenuItem), alloc];
                let entry = StrongPtr::new(
                    msg_send![entry, initWithTitle:*string(label) action:sel!(selected:) keyEquivalent:*string("")],
                );
                let _: () = msg_send![*entry, setTag:tag as isize];
                let _: () = msg_send![*entry, setTarget:*target];
                let _: () = msg_send![*menu, addItem:*entry];
            }
            let _: () = msg_send![*item, setMenu:*menu];
            Self {
                item,
                _target: target,
            }
        }
    }
}
impl Drop for MenuBar {
    fn drop(&mut self) {
        unsafe {
            let bar: *mut Object = msg_send![class!(NSStatusBar), systemStatusBar];
            let _: () = msg_send![bar, removeStatusItem:*self.item];
        }
    }
}
pub fn show_error(message: &str) {
    unsafe {
        let alert = StrongPtr::new(msg_send![class!(NSAlert), new]);
        let _: () = msg_send![*alert, setMessageText:*string("Settings couldn’t open")];
        let _: () = msg_send![*alert, setInformativeText:*string(message)];
        let _: isize = msg_send![*alert, runModal];
    }
}
