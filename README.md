# Power BI Report Exporter (.pbip)

Export any Power BI report from the service as a **Power BI Project (.pbip)** — even when
the *Download this file* option is unavailable — using the Fabric REST API
[`Get Report Definition`](https://learn.microsoft.com/en-us/rest/api/fabric/report/items/get-report-definition).

## Why

- Download is often disabled for reports published to the service, or for thin
  (live-connected) reports.
- Git integration is frequently enabled only for the Development workspace, so the
  versions deployed to Test / Production are not in source control.
- Comparing environments (DEV vs UAT vs PROD) needs the actual deployed definitions.

This script pulls the deployed definition (pages, visuals, bookmarks, filters) straight
from any workspace you have write access to and saves it as a `.pbip` you can open in
Power BI Desktop, diff, or commit.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- **Contributor, Member or Admin** role on the workspace (the API requires write permission on the report)
- Fabric REST APIs allowed for users in your tenant
- Either the `Az.Accounts` module (installed automatically for the current user) or a browser session on app.powerbi.com

## Usage

Find the IDs in the report URL:
`https://app.powerbi.com/groups/<WorkspaceId>/reports/<ReportId>/...`

```powershell
# Sign in with Az.Accounts
powershell -ExecutionPolicy Bypass -File .\Export-PbiReport.ps1 -WorkspaceId "<workspace-guid>" -ReportId "<report-guid>" -Label PROD

# Or use a token from the browser (F12 > Console > copy(powerBIAccessToken))
powershell -ExecutionPolicy Bypass -File .\Export-PbiReport.ps1 -WorkspaceId "<workspace-guid>" -ReportId "<report-guid>" -UseBrowserToken
```

Output: `Documents\PowerBI_Export\<Report name>_<Label>\<Report name>_<Label>.pbip`

> Run the script as a **file**. Pasting it line by line into the console breaks the
> `if / else` blocks.

## Troubleshooting

| Error | Meaning |
|---|---|
| 401 Unauthorized | Token missing or expired — sign in again or use `-UseBrowserToken` |
| 403 Forbidden | No write access on the workspace, or Fabric APIs disabled by the tenant admin |
| 404 Not Found | Wrong workspace or report ID |
| Desktop cannot open the .pbip | Update Power BI Desktop / enable the PBIP and PBIR preview features |

## Notes

- Read-only: the script never changes anything in the workspace.
- The exported report stays live-connected to its semantic model. Be careful not to
  publish from the exported copy unless you intend to overwrite the original.
- Reports with an encryption sensitivity label require rights to remove that label.
- `-UseBrowserToken` relies on a value exposed by the Power BI web page; it is a
  convenience, not an official Microsoft API. Treat the token like a password.

## License

MIT
