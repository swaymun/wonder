# Security reporting

Please use GitHub's **Report a vulnerability** / private advisory flow for this
repository when enabled. If it is unavailable, open an issue containing only a
request for a private reporting channel, without exploit details or private data.
Do not publish credentials, pairing links, APNs tokens, message bodies, screenshots
or user database files in issues.

Include affected versions, the trust boundary involved, a minimal reproduction
with synthetic data, and the impact. There is no promised response SLA during beta.

Tailnet membership is transport access, not Wonder authorization. Mac-confirmed
pairing, device signatures, session renewal, CSRF protection, approval policies and
revocation remain required. Screen control additionally requires native permissions.

The push Worker has only APNs authority. It cannot fetch a Mac's conversations or
files. APNs keys belong in Worker secrets, and phone-specific sender capabilities
stay on the paired Mac and in the phone Keychain. Revocation cancels local pending
deliveries and queues provider revocation. A notification already handed to APNs
cannot be recalled. Retire an independently deployed Worker/key if all of its
clients are removed.

Release builds exclude Wonder's diagnostics recorder, test fixtures and diagnostic
UI. Do not attach Diagnostics archives or private reference artifacts to a release.
