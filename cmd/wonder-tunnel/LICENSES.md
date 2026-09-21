# wonder-tunnel notices

`wonder-tunnel` uses the Go standard library and invokes a separately installed
Tailscale client. It does not embed or distribute Tailscale's `tsnet` package;
`go.mod` has no third-party module dependencies.

Wonder source is covered by the repository [MIT license](../../LICENSE).
The compiled helper includes the Go runtime; its notices are retained in
[licenses/Go-LICENSE.txt](../../licenses/Go-LICENSE.txt). Separately installed Tailscale
software retains its own license and notices.
