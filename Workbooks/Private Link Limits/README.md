# Private Endpoint Limit Helper — Azure Workbook

## Overview

This folder contains an Azure Monitor Workbook designed to help customers identify and manage **Private Endpoint (PE) limits** across their Azure tenant. It provides comprehensive visibility into PE consumption per VNET, hub-spoke peered groups, resource types, and subscriptions.

## Files

| File | Description |
|---|---|
| `Private-Endpoint-Limit-Helper.workbook` | Main workbook — **English** version |
| `Private-Endpoint-Limit-Helper-PTBR.workbook` | Main workbook — **Português do Brasil** version |

## Azure Limits Covered

| Scope | Standard | High Scale |
|---|---|---|
| Private Endpoints per VNET | **1,000** | **5,000** |
| Private Endpoints across peered VNETs (hub-spoke) | **4,000** | **20,000** |
| Private Endpoints per subscription | **64,000** | **64,000** |

The workbook is **High Scale Private Endpoint (HSP) aware**: VNETs with the property `privateEndpointVNetPolicies = Basic` are detected automatically and measured against the higher limits (5,000 / 20,000). The Overview and Hub-Spoke tabs show a **Scale** column (Standard / ⚡ High Scale). The per-subscription limit is unchanged by HSP.

> **References**: [Private Link limits](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits#private-link-limits) · [Increase Private Endpoint virtual network limits (High Scale)](https://learn.microsoft.com/en-us/azure/private-link/increase-private-endpoint-vnet-limits)

## Workbook Tabs

### 📊 Overview
- Summary tiles: Total PEs, VNETs with PEs, At-Risk VNETs, Max PEs in a single VNET
- Grid ranking all VNETs by PE count with color-coded status (OK / Warning / Critical) and a **Scale** column (Standard / ⚡ High Scale); % used and remaining are measured against each VNET's limit (1,000 or 5,000)
- Top 20 VNETs bar chart

### 🌐 Hub-Spoke Analysis
- Discovers VNET peering relationships automatically
- Shows **aggregated** PE count: Own PEs + Peer PEs = Group Total, compared against the 4,000 limit (or **20,000** for High Scale-enabled VNETs, shown in the **Scale** column)
- Hub VNETs with 0 own PEs appear correctly (query starts from VNETs, not PEs)
- Click "View VNETs" to see the list of peered VNET names
- Full peering relationship table with connection state

### 🔍 VNET Detail
- Dropdown to select a specific VNET
- 4 tiles: PE Count, % Used, Remaining Capacity, Status — all measured against the selected VNET's limit (1,000 standard or 5,000 High Scale)
- Pie charts for subnet and resource type distribution
- Full detail grid with connection status, target resources, and direct links

### 📦 By Resource Type
- Bar chart of PE count per resource type
- Summary grid with distinct VNET, subnet, and subscription counts per type
- **Drill-down**: Click a resource type row to load filtered detail grid (avoids ARG 1,000-row limit)

### 📋 By Subscription
- PE count per subscription with % of 64K limit
- Hierarchical grid by Subscription > VNET
- Pie chart of PE distribution across subscriptions

## Deployment

### Option 1 — Azure Portal (Import)
1. Open **Azure Monitor** > **Workbooks**
2. Click **+ New** > **Advanced Editor** (code icon `</>` in toolbar)
3. Paste the `.workbook` JSON content
4. Click **Apply** then **Save**

### Option 2 — ARM Template
Deploy as part of an ARM/Bicep template using `Microsoft.Insights/workbooks` resource type, referencing the JSON as the `serializedData` property.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| Subscriptions | All | Scope the workbook to specific subscriptions |
| Warning Threshold (%) | 70 | VNETs above this % are flagged as ⚠️ Warning |
| Critical Threshold (%) | 90 | VNETs above this % are flagged as 🔴 Critical |

## Technical Notes

- All queries use **Azure Resource Graph (ARG)** — no Log Analytics workspace required
- PE-to-VNET mapping is derived from `properties.subnet.id`
- Target resource type is extracted from `privateLinkServiceConnections[].privateLinkServiceId`
- The By Resource Type tab uses a **summary-first + drill-down** pattern to work around ARG's 1,000-row query limit
- Hub-Spoke analysis starts from VNETs (not PEs) to ensure hub VNETs with 0 own PEs appear, then aggregates Own + Peer PE counts against the 4,000 / 20,000 limit
- **High Scale Private Endpoint detection**: reads the VNET property `properties.privateEndpointVNetPolicies` (`Basic` = HSP enabled → 5,000 / 20,000 limits); Overview joins VNETs to PEs while the VNET Detail tiles and Hub-Spoke aggregation carry the flag per VNET
- Color palettes use `greenRed` (low=green, high=red) for all usage/percentage formatters

## Language Versions

- **English**: `Private-Endpoint-Limit-Helper.workbook`
- **Português do Brasil**: `Private-Endpoint-Limit-Helper-PTBR.workbook` — All UI text, labels, descriptions, and status messages translated to Brazilian Portuguese. KQL queries and Azure API field names remain unchanged.
