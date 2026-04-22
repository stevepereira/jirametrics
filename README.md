
> [!IMPORTANT]
> Documentation for the JiraMetrics tool has now moved to [JiraMetrics.org](https://jirametrics.org)

## Offline Mode (using PowerShell)

If you cannot connect JiraMetrics directly to your Jira instance (e.g., due to network restrictions or security policies), you can use the provided PowerShell script to download the data first, and then run JiraMetrics in "offline mode".

### 1. Download data using PowerShell

Use the `bin/Get-JiraData.ps1` script to fetch all necessary data from Jira. You will need a Personal Access Token (PAT).

```powershell
.\bin\Get-JiraData.ps1 `
  -JiraUrl "https://jira.yourcompany.com" `
  -Token "YOUR_PERSONAL_ACCESS_TOKEN" `
  -BoardId 123 `
  -ProjectPrefix "MYPROJ" `
  -TargetPath "./data"
```

### 2. Configure JiraMetrics for Offline Export

In your `config.rb`, you can now omit the `jira_config` and `download` blocks if you only intend to export. Ensure the `target_path` matches where the PowerShell script saved the data.

```ruby
Exporter.configure do
  target_path 'data' # Must match TargetPath from PowerShell script

  project name: 'MyOfflineProject' do
    file_prefix 'MYPROJ' # Must match ProjectPrefix from PowerShell script

    board id: 123 do
      cycletime do
        start_at first_time_in_status_category('To Do')
        stop_at still_in_status_category('Done')
      end
    end

    file do
      html_report do
        cycletime_scatterplot
        aging_work_table
      end
    end
  end
end
```

### 3. Run the export

Run the `export` command as usual. JiraMetrics will find the JSON files in the `target_path` and generate the reports.

```bash
jirametrics export --config=config.rb
```
