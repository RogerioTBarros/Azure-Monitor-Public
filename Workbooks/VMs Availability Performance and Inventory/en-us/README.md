# VMs - Availability, Performance and Inventory (en-us)

This workbook provides a comprehensive view of the availability, performance, and inventory of your Azure virtual machines (VMs) and hybrid servers (Azure Arc). It allows you to quickly monitor operational status, identify performance bottlenecks, and gain detailed insights into computational resource usage.

## Key Features

- **Status Overview**: Displays the current status of VMs, classifying them as healthy or unhealthy based on criteria such as connectivity and operational state.
- **Performance Monitoring**: Presents essential metrics such as CPU usage, memory, and disk space, allowing you to quickly identify resources with high or low utilization.
- **Complete Inventory**: Provides detailed listings of all VMs and hybrid servers, including information about operating system, resource group, and associated subscription.
- **Detailed Drill-down**: Ability to drill down into specific machines, viewing historical charts and detailed metrics.

## How to Use the Workbook

For data to be displayed correctly, machines must be configured with **VM Insights** (associated with a Data Collection Rule that populates the InsightsMetrics table). Otherwise, performance information will not be available.

## User-Configurable Parameters

The workbook offers various parameters that can be adjusted as needed:

| Parameter | Description |
|-----------|-------------|
| **Time Range** | Defines the time period for data analysis (last 24 hours, 7 days, etc.). |
| **Subscription (VMs)** | Allows you to select one or more subscriptions containing the VMs to be analyzed. |
| **Resource Group (VMs)** | Filters VMs by specific resource groups. |
| **Subscription (Workspace)** | Defines the subscription where Log Analytics workspaces are located. |
| **Resource Group (Workspace)** | Selects the resource groups of Log Analytics workspaces. |
| **Workspace** | Selects the specific workspaces that contain the collected VM data. |
| **Show Filters** | Enables or disables additional filters to refine data visualization. |
| **Show Help** | Displays or hides additional information about how to use the workbook. |
| **Show Summary** | Shows or hides summary charts about the overall VM status. |
| **Performance Thresholds** | Allows you to define custom limits for CPU, memory, disk space, and heartbeat alerts. |
| **Server Filter** | Uses regular expressions to filter specific servers by name. |
| **Aggregation Type** | Chooses the type of aggregation for displayed metrics (average, maximum, or minimum). |

## Use Cases

- **Continuous Monitoring**: Use the workbook to regularly monitor the status and performance of your VMs, ensuring healthy and efficient operation.
- **Quick Troubleshooting**: Quickly identify machines with performance or availability issues, facilitating immediate corrective actions.
- **Capacity Planning**: Analyze historical resource usage to plan infrastructure expansions or optimizations.

## Prerequisites

- Machines configured with VM Insights.
- Appropriate permissions to access Log Analytics workspace data and Azure resources.

## How to Deploy the Workbook

To properly deploy this workbook in Azure, follow the steps below:

1. **Required Files**: Make sure to deploy both files provided in the repository:
   - `VMs - Availability Performance and Inventory - en-us.workbook`
   - `VM Details.workbook`
- **VM Details**: Complementary workbook that provides additional details about each VM individually.

### Important:

- Both files must be deployed in Azure.
- After deployment, it is necessary to adjust the **Resource ID** reference in the main workbook to correctly point to the complementary workbook (**VM Details**). This ensures that detailed drill-down works correctly when clicking "Details".
- When deploying the 2 workbooks, collect the resource ID of the VM Details workbook, edit the main file (VMs - Availability Performance and Inventory - en-us.workbook) and search for the term `"ResourceIDWorkbookDetalhamentoVM"`. Replace this text with the resource ID of the details workbook deployed in your environment and then proceed with the deployment process of the main workbook. If you have any questions, please send a message.

---

This workbook is an essential tool for administrators and operations teams seeking a clear and detailed view of the virtual machine and hybrid server environment in Azure.