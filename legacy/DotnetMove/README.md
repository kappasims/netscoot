# DotnetMove deprecation pointer

This is not part of the toolkit. It is the published artifact that deprecates the old
`DotnetMove` PowerShell Gallery package after the rename to **Netscoot**.

- `DotnetMove` on the Gallery was renamed to `Netscoot` (this repository is `netscoot`).
- The old `DotnetMove` versions are unlisted; this `1.3.3` is published as the only listed version,
  so anyone who finds `DotnetMove` is pointed at the replacement.
- It ships no functionality: the manifest description says to `Install-Module Netscoot`, and the
  module prints that notice on import. It keeps the original package GUID
  (`e5b2d8a3-7c41-49f6-bd0e-9a3c2f6b1e57`) so the Gallery accepts it as a newer version.

Published once with:

```powershell
Publish-Module -Path ./legacy/DotnetMove -NuGetApiKey $env:PSGALLERY_KEY
```

Kept here for the record; there is no reason to rebuild or republish it unless the pointer message
needs to change.
