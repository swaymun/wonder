import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // All work is local and bounded. Never wait for a Mac/network connection.
        guard let payload = request.content.userInfo["wonderPush"] as? [String: String],
              let registration = payload["registrationId"],
              let key = try? PushPreviewKeys.read(registration),
              let preview = try? PushPreview.decrypt(payload, key: key),
              let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content); return
        }
        content.title = preview.title
        content.body = preview.body
        contentHandler(content)
    }
}
