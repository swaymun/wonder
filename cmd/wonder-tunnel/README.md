# wonder-tunnel

Wonder's private connection helper uses the owner's installed Tailscale client.
It inspects the existing connection and emits status as JSON. With `--configure`,
it configures one unused HTTPS Serve port to proxy to Wonder at
`http://127.0.0.1:3777`, then verifies the saved configuration. It rejects a port
already used by another service or enabled for public Funnel access.

The helper does not embed `tsnet`, create a VPN identity, or enable Funnel.
Tailscale must be installed and connected separately. See the
[installation guide](../../INSTALL.md) for setup and
[beta status](../../BETA_STATUS.md) for current verification limits.
