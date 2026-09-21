# Group attachments

Group read responses advertise `attachmentsSupported: true`. Clients treat a
missing capability as false. Group message rows include `attachmentIds`, an
array of canonical file UUIDs; older rows default to an empty array.

Use the existing owner-authorized conversation file routes with the Group's
`conversationId`:

- `POST /api/v1/conversations/{conversationId}/files` accepts
  `{clientUploadId, name, mimeType, contentBase64}`.
- `GET /api/v1/conversations/{conversationId}/files` lists metadata.
- `GET /api/v1/conversations/{conversationId}/files/{fileId}` downloads a file.

Persist the upload UUID before sending. Retrying the same UUID and content
returns the same canonical file ID. Reusing it with changed content or metadata
returns a conflict. Retrying an upload verifies the saved bytes before returning
success. MIME, size, image validation, and download integrity checks are shared
with direct conversations.

Send to `POST /api/v1/group-chats/{groupId}/messages` (the existing
`/api/v1/channels/{groupId}/messages` alias uses the same handler):

```json
{
  "deviceId": "paired-device",
  "clientMessageId": "10c0c2b6-e912-43b6-9667-66d009aeb10d",
  "body": "",
  "attachmentIds": ["949c6d48-3245-43e4-a28a-6bd4d3cd4bd5"]
}
```

An empty body is accepted with at least one attachment. Keep the same message
UUID when reconciling or retrying; receipts and message idempotency are unchanged.
Only available attachment IDs belonging to that Group conversation are accepted.
Clients match previews by canonical ID, never by filename.

Originals belong to stable Group storage, independent of the current coordinator.
Each accepted worker or coordinator receives a verified copy in its own existing
Bot workspace. Authorization comes from the persisted Group node and immutable
membership snapshot. Existing Bot model, reasoning, service tier, working
directory, and permission settings remain in force, including read-only mode.

Assignments created through the registered coordinator tool inherit attachments
from its authenticated initiating Group message. The tool accepts no attachment
ID argument. Attachment links and assignment acceptance are committed together;
replayed calls preserve the same assignment and file identities.

Changed or missing source/copy bytes fail closed and require a new upload.
Complete bytes may remain after a metadata write failure so a retry can recover
the upload; this change does not introduce file garbage collection.
