# Azure Workbook for Monitoring Windows Services

## Overview

This Azure Workbook is designed to monitor the state of Windows Services across multiple virtual machines. It provides insights into the startup type and current state of services, allowing for easy identification of issues and trends over time.

![Workbook screenshot](../../../.images/Windows%20Services%20Workbook.png)


## Parameters

- **Time Range**: Allows selection of the time range for the data displayed in the workbook.
- **Workspace**: Select the Log Analytics workspace(s) to query.
- **Virtual Machines**: Select the virtual machines to monitor.
- **Services Filter**: Filter the services to display based on their name.

## Visualizations

### Virtual Machines - Click a tile for details

Displays a summary of the services on each virtual machine, categorized by their startup type (Auto, Disabled, Manual) and their current state (Running, Stopped).

### Service State Over Time

A line chart showing the state of services over time, allowing for trend analysis.

### Services by Startup Type

A pie chart displaying the distribution of services by their startup type (Auto, Manual, Disabled).

### Services by State

A pie chart showing the distribution of services by their current state (Running, Stopped).

### Service Details

A table providing detailed information about each service, including its name, display name, startup type, state, and the time it was last generated.

## Queries

The workbook uses Kusto Query Language (KQL) to retrieve and process data from the Log Analytics workspace. Below are the main queries used:

### Base Query

```kql
let basequery = ConfigurationData
| where ConfigDataType == "WindowsServices"
| union withsource="Table" (ConfigurationChange
    | where ConfigChangeType == "WindowsServices")
| where _ResourceId in ({VirtualMachines})
| summarize arg_max(TimeGenerated, *) by _ResourceId, SvcName, SvcStartupType;
basequery
| project _ResourceId, SvcStartupType
| evaluate pivot(SvcStartupType)
| extend
    Auto = iif(isempty(Auto), 0, Auto),
    Disabled = iif(isempty(Disabled), 0, Disabled),
    Manual = iif(isempty(Manual), 0, Manual)
| extend Services = Auto + Disabled + Manual
| extend Total = Services
| extend Computer = extract(@"(?i).*/Microsoft.Compute/VirtualMachines/(.*)",1,_ResourceId)
| join kind=inner (basequery
| where SvcStartupType == "Auto"
| project _ResourceId, SvcState
| evaluate pivot(SvcState)) on _ResourceId
| project-away _ResourceId1
```

### Services by Startup Type

```kql
let basequery = ConfigurationData
| where ConfigDataType == "WindowsServices"
| union withsource="Table" (ConfigurationChange
    | where ConfigChangeType == "WindowsServices")
| where _ResourceId =~ "{VMDrillDown}"
| where {StartupType}
| where {ServiceState}
| where SvcName in ({ServiceFilter})
| summarize arg_max(TimeGenerated, *) by _ResourceId, SvcName, SvcStartupType;
basequery
| summarize count() by SvcStartupType
```

### Services by State

```kql
let basequery = ConfigurationData
| where ConfigDataType == "WindowsServices"
| union withsource="Table" (ConfigurationChange
    | where ConfigChangeType == "WindowsServices")
| where _ResourceId =~ "{VMDrillDown}"
| where {StartupType}
| where {ServiceState}
| where SvcName in ({ServiceFilter})
| summarize arg_max(TimeGenerated, *) by _ResourceId, SvcName, SvcStartupType;
basequery
| summarize count() by SvcState
```

### Service Details

```kql
let basequery = ConfigurationData
| where ConfigDataType == "WindowsServices"
| union withsource="Table" (ConfigurationChange
    | where ConfigChangeType == "WindowsServices")
| where _ResourceId =~ "{VMDrillDown}"
| where {StartupType}
| where {ServiceState}
| where SvcName in ({ServiceFilter})
| summarize arg_max(TimeGenerated, *) by _ResourceId, SvcName, SvcStartupType;
basequery
| project TimeGenerated, SvcName, SvcStartupType, SvcState
```

## How to Use

1. Open the Azure Portal and navigate to your Log Analytics workspace.
2. Create a new workbook and paste the provided JSON code.
3. Save the workbook and start monitoring your Windows Services.

## Contributing

If you have any suggestions or improvements, feel free to open an issue or submit a pull request.

## License

This project is licensed under the MIT License.
